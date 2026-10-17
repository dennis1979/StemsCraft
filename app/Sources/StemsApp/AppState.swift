import Foundation
import StemsCore
import SwiftUI
import Combine

/// Thread-safe cooperative cancel flag for the background job.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); defer { lock.unlock() }; v = true }
    func reset() { lock.lock(); defer { lock.unlock() }; v = false }
}

/// App state: song, separation job, player data. Separation runs off-main.
@MainActor
public final class AppState: ObservableObject {
    @Published public var songName = "No song loaded"
    @Published public var songInfo = "Open an audio file or drop one here"
    @Published public var canSeparate = false
    @Published public var isSeparating = false
    @Published public var progress: Double = 0
    @Published public var status = ""
    @Published public var modelPath: String = AppState.defaultModelPath()
    @Published public var peaks: [[Float]] = []
    @Published public var trackNames: [String] = []
    /// Detected tempo of the loaded song (nil while analysing / nothing loaded).
    @Published public var bpm: Double?
    /// Metronome density: 0.5 = every other beat, 1 = every beat, 2 = twice per beat.
    /// Only changes the clicks; the BPM readout always shows the music's real tempo.
    @Published public var clickFactor: Double = 1
    /// false = clicks on the beat, true = halfway between beats (the "and").
    @Published public var clickOffbeat = false
    @Published public var metronomeOn = false

    public let player = StemPlayer()
    private var song: [[Float]] = []
    private var stems: [[[Float]]] = []
    private var previewDir: URL?
    private var cancellables = Set<AnyCancellable>()
    private var beatTimes: [Double] = []
    private var analysisSerial = 0
    private var clickKey: String?
    private var songSourcePath: String?

    // MARK: - Library

    public let library = LibraryStore()
    @Published public var records: [SongRecord] = []
    @Published public var importQueue: [URL] = []
    /// File currently being imported (still in importQueue) and its 0..1 progress.
    @Published public var importingPath: String?
    @Published public var importingPct: Double = 0
    /// Library record currently loading (spinner on its row; main view untouched).
    @Published public var loadingID: String?
    /// Fresh file being loaded without a record yet (transient row on top).
    @Published public var loadingName: String?
    @Published public var selectedID: String?
    /// True while a picked file is being decoded (before analysis/separation).
    @Published public var isLoading = false
    /// Drag-hover highlight for the drop overlay.
    @Published public var dropTargeted = false
    /// Sidebar highlight (single click); loading happens on double click.
    @Published public var highlightedID: String?

    public init() {
        // Forward player changes so views observing AppState refresh too.
        player.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        records = library.records
    }

    public var hasResult: Bool { !stems.isEmpty }

    static func defaultModelPath() -> String {
        // 1. Inside the .app bundle (M3 packaging puts it in Resources).
        if let url = Bundle.main.url(forResource: "spike2_split_middle", withExtension: "onnx"),
           FileManager.default.fileExists(atPath: url.path) { return url.path }
        // 2. Explicit override for dev.
        if let env = ProcessInfo.processInfo.environment["STEMS_MODEL"],
           FileManager.default.fileExists(atPath: env) { return env }
        if let saved = UserDefaults.standard.string(forKey: "modelPath"),
           FileManager.default.fileExists(atPath: saved) { return saved }
        return ""
    }

    /// Open / pick a song by file path: instant when cached, otherwise process now.
    /// Decode runs off-main so the loading spinner paints immediately.
    private var viewSerial = 0

    public func selectURL(_ path: String, titleHint: String? = nil) {
        importQueue.removeAll { $0.path == path }
        // Already imported before? Open that record instead of reprocessing.
        if let iden = LibraryStore.fileIdentity(path: path),
           let hit = library.matchImport(name: URL(fileURLWithPath: path).lastPathComponent,
                                         size: iden.size, mtime: iden.modDate),
           library.stemsPresent(hit) {
            selectRecord(hit)
            return
        }
        viewSerial += 1
        let view = viewSerial
        loadingName = titleHint ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        songInfo = ""
        status = "Loading…"
        isLoading = true
        Task.detached(priority: .userInitiated) {
            guard let audio = try? decodeAudio(path: path) else {
                await MainActor.run { [weak self] in
                    guard let self, view == self.viewSerial else { return }
                    self.isLoading = false
                    self.loadingName = nil
                    self.songInfo = "Couldn't read that file."
                    self.status = ""
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, view == self.viewSerial else { return }
                self.isLoading = false
                let title = titleHint ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                self.setupSong(audio: audio, source: path, title: title, updateUI: false)
                self.selectedID = nil
                self.kickSeparate()
            }
        }
    }

    public func openAudio(url: URL) {
        selectURL(url.path)
    }

    /// Everything the Main thread needs to present a finished song.
    private struct LibraryWrite: Sendable {
        var dir: URL
        var audioFileURL: URL
        var originalURL: URL
        var stemURLs: [URL]
        var record: SongRecord
        var copyFrom: URL?
    }

    /// Build the library write plan on Main (fast: one stat + index read).
    private func buildLibraryWrite(copyFrom: String?, recordID: String?,
                                   title: String, duration: Double,
                                   tempo: (bpm: Double?, beats: [Double])) -> LibraryWrite? {
        guard let copyFrom, !copyFrom.isEmpty else { return nil }
        let src = URL(fileURLWithPath: copyFrom)
        guard let attr = try? FileManager.default.attributesOfItem(atPath: copyFrom),
              let size = attr[.size] as? Int,
              let date = attr[.modificationDate] as? Date else { return nil }
        let id = recordID ?? UUID().uuidString
        let dir = library.songDir(id: id)
        let audioFileURL = dir.appendingPathComponent("source." + (src.pathExtension.isEmpty ? "bin" : src.pathExtension))
        let record = SongRecord(
            id: id, audioFile: audioFileURL.lastPathComponent,
            sourceName: src.lastPathComponent, sourceSize: size,
            sourceMtime: date.timeIntervalSince1970, sourcePath: copyFrom,
            title: title.isEmpty ? src.deletingPathExtension().lastPathComponent : title,
            duration: duration, bpm: tempo.bpm, beats: tempo.beats)
        return LibraryWrite(dir: dir, audioFileURL: audioFileURL,
                            originalURL: library.originalURL(id: id),
                            stemURLs: SeparatedSong.names.map { library.stemURL(id: id, stem: $0) },
                            record: record, copyFrom: src)
    }

    /// Write library files off-main. Each file goes through a `.part` file first,
    /// so a cancelled job never leaves a half-written stem that looks complete.
    private static nonisolated func writeLibraryFiles(_ lw: LibraryWrite, audio: [[Float]], denorm: [[[Float]]]) {
        try? FileManager.default.createDirectory(at: lw.dir, withIntermediateDirectories: true)
        func commit(_ dst: URL, _ write: () throws -> Void) {
            let part = URL(fileURLWithPath: dst.path + ".part")
            try? FileManager.default.removeItem(at: part)
            try? write()
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: part, to: dst)
        }
        if let cf = lw.copyFrom {
            commit(lw.audioFileURL) {
                try FileManager.default.copyItem(at: cf, to: URL(fileURLWithPath: lw.audioFileURL.path + ".part"))
            }
        }
        commit(lw.originalURL) { [audio] in
            // writeWAV takes a path; stage through the .part path instead.
            try writeWAV(path: lw.originalURL.path + ".part", stereo: audio)
        }
        for (i, u) in lw.stemURLs.enumerated() {
            let stem = denorm[i]
            commit(u) { try writeWAV(path: u.path + ".part", stereo: stem) }
        }
    }

    /// Common finish: temp preview WAVs, peaks and optional library files are
    /// written off-main; presentation + record commit happen on Main.
    /// The spinner stays up the whole time, so there is no dead-air hitch.
    /// view/job/serials: stale completions (a newer select or job arrived while
    /// the background work ran) are dropped; a dropped job hands back to startNext.
    private func finishSong(title: String, audio: [[Float]],
                            loadDenorm: @Sendable @escaping () throws -> [[[Float]]],
                            beatsInfo: (bpm: Double?, beats: [Double]),
                            libraryWrite: LibraryWrite?,
                            view: Int, job: Int?, selectID: String?,
                            status text: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // 1. temp preview WAVs for the player + peaks.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("StemsApp-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard let denorm = try? loadDenorm() else {
                await MainActor.run { [weak self] in
                    guard let self, view == self.viewSerial else { return }
                    if job != nil { self.workerBusy = false }
                    self.isLoading = false
                    self.isSeparating = false
                    self.loadingID = nil
                    self.loadingName = nil
                    self.status = "Couldn't read stems."
                    if job == nil { self.kickSeparate() } else { self.startNext() }
                }
                return
            }
            let tracks = [audio] + denorm
            var urls: [URL] = []
            for (i, track) in tracks.enumerated() {
                let u = tmp.appendingPathComponent("track\(i).wav")
                try? writeWAV(path: u.path, stereo: track)
                urls.append(u)
            }
            let trackURLs = urls
            let peaks = tracks.map { AppState.peaks(of: $0) }
            // 2. library files (song folder copy, original + stems).
            if let lw = libraryWrite {
                AppState.writeLibraryFiles(lw, audio: audio, denorm: denorm)
            }
            await MainActor.run { [weak self] in
                guard let self, view == self.viewSerial else { return }
                if let job, job != self.jobSerial {
                    self.workerBusy = false
                    self.startNext()
                    return
                }
                if job != nil { self.workerBusy = false }
                if let lw = libraryWrite {
                    self.library.upsert(lw.record)
                    self.records = self.library.records
                }
                if let selectID {
                    self.selectedID = selectID
                    self.highlightedID = selectID
                }
                self.previewDir = tmp
                self.stems = denorm
                self.song = audio
                self.isSeparating = false
                self.isLoading = false
                self.loadingID = nil
                self.loadingName = nil
                self.progress = 1
                self.status = text
                self.songName = title
                self.songInfo = String(format: "%.1fs.", Double(audio[0].count) / 44100)
                let names = ["Original"] + SeparatedSong.names.map { $0.capitalized }
                self.trackNames = names
                self.peaks = peaks
                self.player.load(names: names, urls: trackURLs)
                self.clickKey = nil
                self.bpm = beatsInfo.bpm
                self.beatTimes = beatsInfo.beats
                self.applyMetronome()
                self.startNext()
            }
        }
    }

    public func setModel(url: URL) {
        modelPath = url.path
        UserDefaults.standard.set(url.path, forKey: "modelPath")
        canSeparate = !song.isEmpty
    }

    // Newest request always wins: opening a file while a job runs cancels
    // the old job and starts the new one (cooperative, ~1 chunk granularity).
    private var jobSerial = 0
    private var workerBusy = false
    /// copyFrom: file to duplicate into the song folder (external drop or internal copy).
    /// recordID: rebuild into this existing record instead of minting a new one.
    private var pending: (audio: [[Float]], name: String, copyFrom: String?, recordID: String?, serial: Int)?

    public func separate() {
        kickSeparate()
    }

    private func kickSeparate(recordID: String? = nil) {
        kickSeparateWithCopy(copyFrom: songSourcePath, recordID: recordID)
    }

    private func kickSeparateWithCopy(copyFrom: String?, recordID: String?) {
        guard !song.isEmpty, !modelPath.isEmpty else { return }
        jobSerial += 1
        pending = (song, songName, copyFrom, recordID, jobSerial)
        cancelFlag.set() // preempts a running interactive job or import
        if workerBusy {
            status = "Switching songs…"
        }
        startNext()
    }

    /// Scheduler: an interactive pending job first, imports when idle.
    private func startNext() {
        if workerBusy { return }
        guard pending != nil else {
            isSeparating = false
            pumpImports()
            return
        }
        // NOTE: pending is consumed inside runInteractive's launch below.
        runPending()
    }

    private func runPending() {
        guard let job = pending else {
            isSeparating = false
            pumpImports()
            return
        }
        pending = nil
        workerBusy = true
        isSeparating = true
        cancelFlag.reset()
        progress = 0
        status = "Separating…"
        let audio = job.audio
        let name = job.name
        let serial = job.serial
        let model = modelPath
        let copyFrom = job.copyFrom
        let recordID = job.recordID
        let flag = cancelFlag
        Task.detached(priority: .userInitiated) {
            let L = audio[0].count
            var sSum = 0.0, sSq = 0.0
            for ch in 0 ..< 2 {
                for v in audio[ch] { sSum += Double(v); sSq += Double(v) * Double(v) }
            }
            let n = Double(2 * L)
            let sMean = sSum / n
            let sStd = (sSq / n - sMean * sMean).squareRoot()
            let norm = audio.map { $0.map { Float((Double($0) - sMean) / (sStd + 1e-8)) } }
            do {
                await MainActor.run { [weak self] in self?.status = "Loading model…" }
                let sep = try Separator(modelPath: model)
                let out = try sep.separate(norm) { p in
                    Task { @MainActor [weak self] in
                        self?.progress = p
                        self?.status = "Separating… \(Int(p * 100))%"
                    }
                    return !flag.get()
                }
                let denorm = out.map { stem in stem.map { ch in ch.map { $0 * Float(sStd) + Float(sMean) } } }
                // Beat analysis, synchronously with the job so the saved record
                // always matches the separated audio (no cross-song race).
                let tempo = BeatAnalyzer.detectTempo(stereo: audio)
                // Everything below is Main-thread fast (plan) or off-main (finish).
                let lw: LibraryWrite? = await MainActor.run { [weak self] in
                    guard let self, serial == self.jobSerial else { return nil }
                    return self.buildLibraryWrite(copyFrom: copyFrom, recordID: recordID,
                                                  title: self.songName,
                                                  duration: Double(audio[0].count) / 44100,
                                                  tempo: (bpm: tempo.bpm, beats: tempo.beats))
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // NOTE: workerBusy stays true until finishSong presents.
                    self.finishSong(title: name, audio: audio,
                                    loadDenorm: { denorm },
                                    beatsInfo: (bpm: tempo.bpm, beats: tempo.beats),
                                    libraryWrite: lw,
                                    view: self.viewSerial, job: serial,
                                    selectID: lw?.record.id, status: "Done")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.workerBusy = false
                    // Cancelled by a newer job (or Cancel button): hand over.
                    if serial == self.jobSerial {
                        self.isSeparating = false
                        self.status = "Cancelled"
                        self.loadingID = nil
                        self.loadingName = nil
                    }
                    self.startNext()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.workerBusy = false
                    if serial == self.jobSerial {
                        self.isSeparating = false
                        self.status = "Failed: \(error)"
                        self.loadingID = nil
                        self.loadingName = nil
                    }
                    self.startNext()
                }
            }
        }
    }

    private let cancelFlag = CancelFlag()

    public func cancel() {
        cancelFlag.set()
    }

    // MARK: - Library persistence + import queue

    /// Drop files onto the library: queued FIFO, processed when idle.
    public func enqueueImport(_ urls: [URL]) {
        for u in urls where !importQueue.contains(u) {
            importQueue.append(u)
        }
        startNext()
    }

    private func pumpImports() {
        guard !workerBusy, pending == nil, !importQueue.isEmpty else { return }
        let url = importQueue.first!
        workerBusy = true
        cancelFlag.reset()
        importingPath = url.path
        importingPct = 0
        let model = modelPath
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Returns after removing the URL from the queue (done or not).
            func finish() async {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.importQueue.removeAll { $0.path == url.path }
                    if self.importingPath == url.path {
                        self.importingPath = nil
                        self.importingPct = 0
                    }
                    self.workerBusy = false
                    self.startNext()
                }
            }
            do {
                let audio = try decodeAudio(path: url.path)
                // Already imported before (checked in by another pass): skip.
                let dup: Bool = await MainActor.run {
                    guard let iden = LibraryStore.fileIdentity(path: url.path),
                          let hit = self.library.matchImport(name: url.lastPathComponent,
                                                             size: iden.size, mtime: iden.modDate) else { return false }
                    return self.library.stemsPresent(hit)
                }
                if dup { throw ImportSkip.cached }
                let L = audio[0].count
                var sSum = 0.0, sSq = 0.0
                for ch in 0 ..< 2 {
                    for v in audio[ch] { sSum += Double(v); sSq += Double(v) * Double(v) }
                }
                let n = Double(2 * L)
                let sMean = sSum / n
                let sStd = (sSq / n - sMean * sMean).squareRoot()
                let norm = audio.map { $0.map { Float((Double($0) - sMean) / (sStd + 1e-8)) } }
                let sep = try Separator(modelPath: model)
                let flag = self.cancelFlag
                let out = try sep.separate(norm) { p in
                    Task { @MainActor [weak self] in
                        if self?.importingPath == url.path { self?.importingPct = p }
                    }
                    return !flag.get()
                }
                let denorm = out.map { stem in stem.map { ch in ch.map { $0 * Float(sStd) + Float(sMean) } } }
                let tempo = BeatAnalyzer.detectTempo(stereo: audio)
                let title = url.deletingPathExtension().lastPathComponent
                let lw: LibraryWrite? = await MainActor.run { [weak self] in
                    guard let self else { return nil }
                    return self.buildLibraryWrite(
                        copyFrom: url.path, recordID: nil, title: title,
                        duration: Double(audio[0].count) / 44100,
                        tempo: (bpm: tempo.bpm, beats: tempo.beats))
                }
                if let lw {
                    AppState.writeLibraryFiles(lw, audio: audio, denorm: denorm)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.library.upsert(lw.record)
                        self.records = self.library.records
                    }
                }
                await finish()
            } catch is CancellationError {
                await finish() // preempted by an interactive open; it owns the worker now
            } catch ImportSkip.cached {
                await finish()
            } catch {
                await finish()
            }
        }
    }

    private enum ImportSkip: Error { case cached }

    /// Tap counting for the library list: two taps within 0.35 s count as a
    /// double click. (Two stacked SwiftUI tap gestures never fire the double.)
    /// Returns true on double click.
    private var tapTask: Task<Void, Never>?
    private var tapID: String?

    // MARK: - Library list tap counting

    public func registerTap(id: String) -> Bool {
        if tapID == id {
            tapTask?.cancel()
            tapTask = nil
            tapID = nil
            return true
        }
        tapID = id
        highlightedID = id
        tapTask?.cancel()
        tapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.tapID = nil
        }
        return false
    }
    /// Pick a song from the library. Spinner first, every file read off-main;
    /// instant when cached, otherwise rebuild into the same folder.
    public func selectRecord(_ r: SongRecord) {
        highlightedID = r.id
        loadingID = r.id
        viewSerial += 1
        let view = viewSerial
        loadingName = r.title
        songInfo = ""
        status = "Loading…"
        isLoading = true
        // Snapshot (Main, fast stats only); all file IO happens off-main.
        let id = r.id
        let hasStems = library.stemsPresent(r)
        let ourl = library.originalURL(id: id).path
        let stemPaths = SeparatedSong.names.map { library.stemURL(id: id, stem: $0).path }
        let internalSrc = internalAudioPath(r)
        let legacySrc = r.sourcePath
        let info = (bpm: r.bpm, beats: r.beats)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var audio: [[Float]]? = nil
            var healed = false
            var adoptFrom: String? = nil
            if hasStems {
                if let a = try? readWAVFloats(path: ourl) {
                    audio = a
                    healed = true
                } else if let src = internalSrc, let a = try? decodeAudio(path: src) {
                    try? writeWAV(path: ourl, stereo: a)
                    audio = a
                    healed = true
                } else if !legacySrc.isEmpty, let a = try? decodeAudio(path: legacySrc) {
                    try? writeWAV(path: ourl, stereo: a)
                    adoptFrom = legacySrc
                    audio = a
                    healed = true
                }
            }
            if audio == nil {
                let src = internalSrc ?? (legacySrc.isEmpty ? nil : legacySrc)
                if let src, let a = try? decodeAudio(path: src) { audio = a }
            }
            guard let audio else {
                await MainActor.run { [weak self] in
                    guard let self, view == self.viewSerial else { return }
                    self.isLoading = false
                    self.loadingID = nil
                    self.songInfo = "Original file missing."
                    self.status = ""
                }
                return
            }
            let healedNow = healed
            let adoptNow = adoptFrom
            await MainActor.run { [weak self] in
                guard let self, view == self.viewSerial else { return }
                self.isLoading = false
                self.setupSong(audio: audio, source: legacySrc, title: r.title, updateUI: false)
                if healedNow {
                    if let adoptNow { self.adoptCopy(recordID: id, from: adoptNow) }
                    self.finishSong(title: r.title, audio: audio,
                                    loadDenorm: { try stemPaths.map { try readWAVFloats(path: $0) } },
                                    beatsInfo: info, libraryWrite: nil,
                                    view: view, job: nil, selectID: id, status: "")
                } else {
                    // Rebuild into the same folder.
                    self.selectedID = nil
                    self.song = audio
                    self.jobSerial += 1
                    let copySrc = internalSrc ?? (legacySrc.isEmpty ? nil : legacySrc)
                    self.pending = (audio, r.title, copySrc, id, self.jobSerial)
                    self.cancelFlag.set()
                    self.startNext()
                }
            }
        }
    }

    /// Inside copy of the song's audio, if present.
    private func internalAudioPath(_ r: SongRecord) -> String? {
        guard !r.audioFile.isEmpty else { return nil }
        let p = library.songDir(id: r.id).appendingPathComponent(r.audioFile).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Adopt the legacy outside file into the song folder (one-time migration).
    private func adoptCopy(recordID: String, from path: String) {
        guard let r = records.first(where: { $0.id == recordID }),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        let src = URL(fileURLWithPath: path)
        let audioFile = "source." + (src.pathExtension.isEmpty ? "bin" : src.pathExtension)
        let dst = library.songDir(id: recordID).appendingPathComponent(audioFile)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil,
              let (size, mtime) = LibraryStore.fileIdentity(path: dst.path) else { return }
        var nr = r
        nr.audioFile = audioFile
        nr.sourceName = src.lastPathComponent
        nr.sourceSize = size
        nr.sourceMtime = mtime
        library.upsert(nr)
        records = library.records
    }

    private func setupSong(audio: [[Float]], source: String, title: String, updateUI: Bool = true) {
        song = audio
        songSourcePath = source
        if updateUI {
            songName = title
            let secs = Double(audio[0].count) / 44100
            songInfo = String(format: "%.1fs.", secs)
            status = ""
            analyzeBeats(audio)
        }
        canSeparate = !modelPath.isEmpty
    }

    public func deleteRecord(_ r: SongRecord) {
        library.remove(id: r.id)
        records = library.records
        if selectedID == r.id { selectedID = nil }
        if highlightedID == r.id { highlightedID = nil }
    }

    public func moveLibraryRoot(to url: URL) {
        library.moveRoot(to: url)
        records = library.records
        selectedID = nil
        highlightedID = nil
    }

    public static nonisolated func peaks(of stereo: [[Float]], columns: Int = 800) -> [Float] {
        let L = stereo[0].count
        var out = [Float](repeating: 0, count: columns)
        for c in 0 ..< columns {
            let a = c * L / columns, b = min(L, (c + 1) * L / columns)
            var p: Float = 0
            var i = a
            while i < b {
                let v = max(abs(stereo[0][i]), stereo.count > 1 ? abs(stereo[1][i]) : 0)
                if v > p { p = v }
                i += 4
            }
            out[c] = p
        }
        return out
    }

    // MARK: - Tempo, speed, metronome

    /// Tempo shown to the user: detected BPM x half/double fix x playback speed.
    /// Starts at the song's own tempo; changing the speed moves this number.
    public var displayBPM: Double? {
        guard let bpm else { return nil }
        return bpm * player.rate
    }

    /// The song's own tempo.
    public var originalBPM: Double? { bpm }

    private func analyzeBeats(_ audio: [[Float]]) {
        analysisSerial += 1
        let serial = analysisSerial
        bpm = nil
        clickFactor = 1
        beatTimes = []
        clickKey = nil
        Task.detached(priority: .utility) { [weak self] in
            let r = BeatAnalyzer.detectTempo(stereo: audio)
            await self?.finishAnalysis(serial: serial, result: r)
        }
    }

    private func finishAnalysis(serial: Int, result r: TempoResult) {
        guard serial == analysisSerial else { return }
        bpm = r.bpm
        beatTimes = r.beats
        if metronomeOn { applyMetronome() }
    }

    /// Raise / lower the tempo by one BPM (`fine`: 0.1). Lands on whole multiples of the step,
    /// so from an odd start such as 120.4 the first click goes to 121 / 120.
    public func nudgeBPM(_ direction: Double, fine: Bool) {
        guard let base = originalBPM, let cur = displayBPM else { return }
        let step = fine ? 0.1 : 1.0
        let q = cur / step
        let nearest = q.rounded()
        let target: Double
        if abs(q - nearest) < 0.02 {
            target = (nearest + direction) * step
        } else {
            target = (direction > 0 ? q.rounded(.up) : q.rounded(.down)) * step
        }
        player.setRate(target / base)
    }

    public func resetSpeed() {
        player.setRate(1.0)
    }

    public func toggleMetronome() {
        metronomeOn.toggle()
        applyMetronome()
    }

    /// Type a tempo: sets the playback speed so the music runs at `value` BPM (clamped to 50%...200%).
    public func setBPM(_ value: Double) {
        guard let base = originalBPM, value.isFinite, value > 0 else { return }
        player.setRate(value / base)
    }

    /// Half / double density of the clicks; choosing the active one again goes back to every beat.
    public func setClickFactor(_ f: Double) {
        clickFactor = (clickFactor == f) ? 1 : f
        rebuildClickIfNeeded()
    }

    /// Switch the clicks between the beat and the off-beat.
    public func toggleOffbeat() {
        clickOffbeat.toggle()
        rebuildClickIfNeeded()
    }

    private func rebuildClickIfNeeded() {
        clickKey = nil
        if metronomeOn { applyMetronome() }
    }

    private func applyMetronome() {
        if !metronomeOn {
            player.setClickEnabled(false)
            return
        }
        ensureClickTrack()
    }

    /// Beat times for the click: density (½ / 1 / 2) first, then the optional off-beat shift.
    private func clickBeats() -> [Double] {
        var b = beatTimes
        if clickFactor == 0.5 {
            b = b.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        } else if clickFactor == 2 {
            var out: [Double] = []
            for i in 0 ..< b.count {
                out.append(b[i])
                if i + 1 < b.count { out.append((b[i] + b[i + 1]) / 2) }
            }
            b = out
        }
        if clickOffbeat {
            // Halfway between neighbouring clicks. With ½ this lands on the skipped beats.
            b = (0 ..< max(0, b.count - 1)).map { (b[$0] + b[$0 + 1]) / 2 }
        }
        return b
    }

    /// Build the click WAV from the song's detected beats (off the main thread) and hand it to the player.
    private func ensureClickTrack() {
        guard !beatTimes.isEmpty, let dir = previewDir, player.duration > 0 else { return }
        let beats = clickBeats()
        let key = "\(clickFactor)|\(clickOffbeat)|\(beatTimes.count)|\(beatTimes.first ?? 0)|\(beatTimes.last ?? 0)"
        if key == clickKey && player.hasClickTrack {
            player.setClickEnabled(true)
            return
        }
        let frames = Int(player.duration * 44100)
        let url = dir.appendingPathComponent("click-\(UUID().uuidString).wav")
        let serial = jobSerial
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ClickTrack.writeWAV(path: url.path, frames: frames, beats: beats)
            } catch {
                return
            }
            await self?.attachClick(url: url, key: key, serial: serial)
        }
    }

    private func attachClick(url: URL, key: String, serial: Int) {
        guard metronomeOn, serial == jobSerial else { return }
        player.setClickTrack(url: url)
        player.setClickEnabled(true)
        clickKey = key
    }

    public func exportAll(to dir: URL) throws {
        for (i, name) in SeparatedSong.names.enumerated() {
            try writeWAV(path: dir.appendingPathComponent("\(songName) - \(name).wav").path,
                         stereo: stems[i])
        }
    }

    public func exportStem(_ i: Int, to dir: URL) throws {
        // i indexes SeparatedSong.names (stems excludes Original at player index 0)
        try writeWAV(path: dir.appendingPathComponent("\(songName) - \(SeparatedSong.names[i]).wav").path,
                     stereo: stems[i])
    }
}
