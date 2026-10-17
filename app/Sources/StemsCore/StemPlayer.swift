import AVFoundation
import Combine
import Foundation

/// Multitrack player backed by temp WAV files (AVAudioFile + scheduleSegment
/// gives sample-accurate common start time and free seeking).
/// Player semantics: mute/solo/volume per track, original muted by default.
/// AVAudioEngine is thread-safe for start/stop. This holder lets engine.start()
/// run off the main thread: with a slow aggregate device (e.g. BlackHole +
/// multi-output) start() can block for seconds negotiating hardware, which
/// used to beachball the whole UI because play() ran on Main.
private final class EngineStarter: @unchecked Sendable {
    private let engine: AVAudioEngine
    init(_ engine: AVAudioEngine) { self.engine = engine }
    var isRunning: Bool { engine.isRunning }
    func start() throws { try engine.start() }
}

@MainActor
public final class StemPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var gains: [AVAudioMixerNode] = []
    private var master: AVAudioMixerNode?
    private var files: [AVAudioFile] = []
    private var anchorSample: AVAudioFramePosition = 0

    // Speed: one time-pitch unit after the main mixer, so every track (and the metronome)
    // is stretched together and stays in sync; pitch is preserved.
    private let timePitch = AVAudioUnitTimePitch()
    // Metronome: a click track (WAV, same length as the song) scheduled with the stems.
    private var clickNode: AVAudioPlayerNode?
    private var clickGain: AVAudioMixerNode?
    private var clickFile: AVAudioFile?

    @Published public private(set) var names: [String] = []
    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public var mute: [Bool] = []
    @Published public var volume: [Float] = []
    @Published public var masterVolume: Float = 1.0
    @Published public var trackCount = 0
    @Published public var engineNote = ""
    @Published public private(set) var rate: Double = 1.0
    @Published public private(set) var clickEnabled = false
    @Published public private(set) var clickVolume: Float = 1.0
    /// True while engine.start() runs off-main (slow aggregate devices).
    @Published public private(set) var starting = false
    /// User-facing playback failure (engine.start() threw). Shown in the UI;
    /// engineNote keeps the raw detail for the tooltip.
    @Published public private(set) var audioError: String?
    /// Invalidates an in-flight async start (pause/load/device change won).
    private var startSerial = 0

    private var timer: Timer?
    // Position source: frame counts from a tap on the main mixer (output
    // timeline). playerTime/lastRenderTime proved unreliable (frozen).
    private let posLock = NSLock()
    private var tapOutputFrames: UInt64 = 0
    private var tapRate: Double = 44100
    private var anchorSec: Double = 0

    public init() {
        engine.attach(timePitch)
        // NOTE: never pass the hardware output format here. With aggregate /
        // multi-output devices the HAL can report 0 output streams, and
        // connect(_:to:format:) then throws an ObjC exception
        // (IsFormatSampleRateAndChannelCountValid) which Swift cannot catch:
        // it unwinds through AppState.init and leaves the app with no window.
        // nil negotiates the format at engine start instead.
        engine.connect(engine.mainMixerNode, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.outputNode, format: nil)
        timePitch.bypass = true // rate 1.0
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDeviceChange() }
        }
    }

    public var hasClickTrack: Bool { clickFile != nil }

    public var hasTracks: Bool { !files.isEmpty }

    /// urls must be 44.1k stereo files, one per name.
    public func load(names: [String], urls: [URL]) {
        startSerial += 1 // drop an in-flight async start
        starting = false
        audioError = nil
        for n in nodes { n.stop() }
        engine.stop()
        for n in engine.attachedNodes where n !== engine.mainMixerNode && n !== engine.outputNode && n !== timePitch {
            engine.detach(n)
        }
        nodes = []
        gains = []
        files = []
        clickNode = nil
        clickGain = nil
        clickFile = nil
        let master = AVAudioMixerNode()
        engine.attach(master)
        engine.connect(master, to: engine.mainMixerNode, format: nil)
        master.outputVolume = masterVolume
        self.master = master
        for (i, url) in urls.enumerated() {
            guard let file = try? AVAudioFile(forReading: url) else {
                engineNote = "skip unreadable: \(url.lastPathComponent)"
                continue
            }
            let node = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            engine.attach(node)
            engine.attach(gain)
            engine.connect(node, to: gain, format: file.processingFormat)
            // Index 0 is Original: straight to the main mixer, bypassing the
            // stem master fader. Stems go through master.
            if i == 0 {
                engine.connect(gain, to: engine.mainMixerNode, format: file.processingFormat)
            } else {
                engine.connect(gain, to: master, format: file.processingFormat)
            }
            nodes.append(node)
            gains.append(gain)
            files.append(file)
        }
        self.names = names
        mute = names.map { $0 == "Original" }
        volume = [Float](repeating: 1, count: names.count)
        duration = files.map { Double($0.length) / 44100 }.max() ?? 0
        anchorSample = 0
        position = 0
        isPlaying = false
        trackCount = names.count
        applyGains()
        engineNote = "loaded \(files.count)/\(names.count) tracks"
    }

    private func applyGains() {
        for i in 0 ..< gains.count {
            gains[i].outputVolume = mute[i] ? 0 : volume[i]
        }
        clickGain?.outputVolume = clickEnabled ? clickVolume : 0
    }

    public func setMute(_ i: Int, _ on: Bool) {
        mute[i] = on
        applyGains()
    }

    public func setVolume(_ i: Int, _ v: Float) {
        volume[i] = v
        applyGains()
    }

    /// Master fader for the four stems (Original and metronome excluded).
    public func setMasterVolume(_ v: Float) {
        masterVolume = max(0, min(1.5, v))
        master?.outputVolume = masterVolume
    }

    /// Hear only this track; again on the lone track restores all stems (original muted).
    public func soloOnly(_ i: Int) {
        let alone = mute.enumerated().allSatisfy { $0.element == ($0.offset != i) }
        for j in 0 ..< mute.count {
            mute[j] = alone ? (names[j] == "Original") : (j != i)
        }
        applyGains()
    }

    /// Any stem audible (lights the master toggle); only all-muted shows off.
    public var anyStemAudible: Bool {
        guard mute.count > 1 else { return false }
        return (1 ..< mute.count).contains { !mute[$0] }
    }

    /// All stems on/off together; Original untouched.
    public func setAllStems(_ on: Bool) {
        for i in 1 ..< mute.count { mute[i] = !on }
        applyGains()
    }

    public func resetMix() {
        for j in 0 ..< mute.count {
            mute[j] = (names[j] == "Original")
            volume[j] = 1
        }
        applyGains()
    }

    public func audible(_ i: Int) -> Bool { !mute[i] }

    public func play() {
        guard !files.isEmpty else {
            engineNote = "play: no tracks loaded"
            return
        }
        guard !isPlaying else {
            engineNote = "play: already playing"
            return
        }
        guard !starting else { return }
        if anchorSample >= AVAudioFramePosition(duration * 44100) - 2205 { anchorSample = 0 }
        // engine.start() can block for seconds on aggregate / multi-output
        // devices (BlackHole): run it off-main so the UI never beachballs.
        startSerial += 1
        let serial = startSerial
        starting = true
        engineNote = "starting audio…"
        let starter = EngineStarter(engine)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if !starter.isRunning { try starter.start() }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, serial == self.startSerial else { return }
                    self.starting = false
                    self.engineNote = "engine start failed: \(error)"
                    // Multi-output devices can't host an IOProc at all
                    // (0 output streams at the HAL); aggregates need working
                    // output members. Tell the user instead of staying silent.
                    self.audioError = "這個輸出裝置無法直接播放（多重輸出裝置不支援）：請把系統輸出切到聚集裝置、BlackHole 或內建喇叭，再按一次播放"
                }
                return
            }
            await MainActor.run { [weak self] in self?.finishPlay(serial: serial) }
        }
    }

    /// Second half of play(), back on Main after the engine is running.
    private func finishPlay(serial: Int) {
        guard serial == startSerial else { return } // paused / reloaded meanwhile
        starting = false
        audioError = nil
        guard !isPlaying else { return }
        engineNote = "playing (engine running: \(engine.isRunning))"
        // Rate of the mixer's output bus (what the tap counts); the time-pitch unit sits after it.
        tapRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        anchorSec = Double(anchorSample) / 44100
        posLock.lock(); tapOutputFrames = 0; posLock.unlock()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.posLock.lock()
            self.tapOutputFrames += UInt64(buf.frameLength)
            self.posLock.unlock()
        }
        // Schedule ASAP (at:nil) and start nodes back-to-back: inter-track
        // offsets are microseconds (inaudible). An explicit hostTime start was
        // tried and left nodes stuck (frozen position, silence).
        for (i, node) in nodes.enumerated() {
            let file = files[i]
            let startAt = min(anchorSample, file.length)
            if startAt < file.length {
                node.scheduleSegment(file, startingFrame: startAt,
                                     frameCount: AVAudioFrameCount(file.length - startAt),
                                     at: nil)
            }
            node.play()
        }
        if let node = clickNode, let file = clickFile {
            let startAt = min(anchorSample, file.length)
            if startAt < file.length {
                node.scheduleSegment(file, startingFrame: startAt,
                                     frameCount: AVAudioFrameCount(file.length - startAt),
                                     at: nil)
            }
            node.play()
        }
        isPlaying = true
        startTimer()
    }

    public func pause() {
        if starting {
            // An async engine.start() is in flight: invalidate it. The engine
            // itself can stay running; nothing was scheduled yet.
            startSerial += 1
            starting = false
            engineNote = "paused"
            return
        }
        guard isPlaying else { return }
        anchorSample = currentSample()
        for n in nodes { n.stop() }
        clickNode?.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        isPlaying = false
        stopTimer()
        position = Double(anchorSample) / 44100
    }

    /// The output device changed (plug/unplug, sample-rate or aggregate edit):
    /// the engine has stopped underneath us. Drop any in-flight start, stop
    /// playback cleanly and let the user press play again.
    private func handleDeviceChange() {
        startSerial += 1
        starting = false
        audioError = nil
        if isPlaying {
            for n in nodes { n.stop() }
            clickNode?.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
            isPlaying = false
            stopTimer()
            position = Double(anchorSample) / 44100
        }
        engineNote = "audio device changed – press play"
    }

    public func toggle() { (isPlaying || starting) ? pause() : play() }

    /// Playback speed, 0.5x...2.0x (continuous, so a BPM target can be hit exactly). Pitch is preserved.
    public func setRate(_ r: Double) {
        var c = min(2.0, max(0.5, r))
        if abs(c - 1) < 1e-6 { c = 1 }
        if isPlaying {
            // Re-baseline: song position keeps continuous across the change.
            anchorSec = currentSeconds()
            posLock.lock(); tapOutputFrames = 0; posLock.unlock()
        }
        rate = c
        timePitch.bypass = (c == 1.0)
        timePitch.rate = Float(c)
    }

    /// Attach (or remove, with nil) the metronome click track.
    /// Gapless: only the click node is stopped/swapped; stem nodes keep
    /// playing from their current position (previously this paused everything
    /// and rescheduled all stems, which caused an audible stutter every time
    /// the metronome was toggled or its density changed).
    public func setClickTrack(url: URL?) {
        let playing = isPlaying
        let atSample: AVAudioFramePosition = playing ? currentSample() : anchorSample
        if let n = clickNode { n.stop(); engine.detach(n) }
        if let g = clickGain { engine.detach(g) }
        clickNode = nil
        clickGain = nil
        clickFile = nil
        if let url, let file = try? AVAudioFile(forReading: url) {
            let node = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            engine.attach(node)
            engine.attach(gain)
            engine.connect(node, to: gain, format: file.processingFormat)
            engine.connect(gain, to: engine.mainMixerNode, format: file.processingFormat)
            clickNode = node
            clickGain = gain
            clickFile = file
            if playing {
                let startAt = min(atSample, file.length)
                if startAt < file.length {
                    node.scheduleSegment(file, startingFrame: startAt,
                                         frameCount: AVAudioFrameCount(file.length - startAt),
                                         at: nil)
                }
                node.play()
            }
        }
        applyGains()
    }

    public func setClickEnabled(_ on: Bool) {
        clickEnabled = on
        applyGains()
    }

    public func setClickVolume(_ v: Float) {
        clickVolume = max(0, min(1.5, v))
        applyGains()
    }

    public func seek(_ seconds: Double) {
        let was = isPlaying
        if was { pause() }
        anchorSample = AVAudioFramePosition(max(0, min(seconds, duration)) * 44100)
        position = Double(anchorSample) / 44100
        if was { play() }
    }

    private func currentSeconds() -> Double {
        posLock.lock()
        let f = tapOutputFrames
        posLock.unlock()
        // The tap sits before the time-pitch unit, so it counts source-rate
        // frames in realtime; song time advances rate x faster/slower.
        return anchorSec + Double(f) / tapRate * rate
    }

    private func currentSample() -> AVAudioFramePosition {
        min(AVAudioFramePosition(currentSeconds() * 44100), AVAudioFramePosition(duration * 44100))
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                let s = self.currentSample()
                self.position = Double(s) / 44100
                if Double(s) / 44100 >= self.duration - 0.05 {
                    self.pause()
                    self.anchorSample = AVAudioFramePosition(self.duration * 44100)
                    self.position = self.duration
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
