import Foundation
import StemsCore

// Headless player harness: load WAVs, play, report state. No UI.
// Usage: StemsDebug <dir-with-drums,bass,other,vocals.wav>
//   --beats <audio-file> <out.json>: detect tempo, write beats + click-mixed preview.
//   --libtest <tmp-root> <audio-file> <stems-dir>: library round-trip test.
let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: StemsDebug <stems-dir> | StemsDebug --beats <audio> <out.json>\n", stderr)
    exit(2)
}

if args.count == 4, args[1] == "--beats" {    let audio = try decodeAudio(path: args[2])
    let t0 = Date()
    let r = BeatAnalyzer.detectTempo(stereo: audio)
    print("bpm=\(r.bpm) firstBeat=\(r.firstBeat) confidence=\(r.confidence) beats=\(r.beats.count) "
        + "in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    // Residual: fit a straight line, report RMS (grid quality).
    if r.beats.count >= 8 {
        let n = Double(r.beats.count)
        var sk = 0.0, st = 0.0, skk = 0.0, skt = 0.0
        for (k, t) in r.beats.enumerated() {
            let kd = Double(k)
            sk += kd; st += t; skk += kd * kd; skt += kd * t
        }
        let den = n * skk - sk * sk
        if den > 0 {
            let b = (n * skt - sk * st) / den
            let a = (st - b * sk) / n
            var se = 0.0, worst = 0.0
            for (k, t) in r.beats.enumerated() {
                let e = abs(t - (a + b * Double(k)))
                se += e * e; worst = max(worst, e)
            }
            print("grid fit: period=\(b)s rms=\((se / n).squareRoot() * 1000)ms worst=\(worst * 1000)ms")
        }
    }
    let beatsJSON = "[" + r.beats.map { String($0) }.joined(separator: ",") + "]"
    let doc = "{\"bpm\":\(r.bpm),\"firstBeat\":\(r.firstBeat),\"confidence\":\(r.confidence),\"beats\":\(beatsJSON)}"
    try doc.write(to: URL(fileURLWithPath: args[3]), atomically: true, encoding: .utf8)
    // Preview: original + clicks at 0.35 gain.
    var mixed = audio
    for b in r.beats {
        let s0 = Int((b * 44100).rounded())
        let len = Int(0.04 * 44100)
        for j in 0 ..< len {
            let i = s0 + j
            guard i >= 0, i < mixed[0].count else { continue }
            let t = Double(j) / 44100
            let v = Float(sin(2 * Double.pi * 1500 * t) * min(1, Double(j) / 44) * exp(-t / 0.007)) * 0.35
            mixed[0][i] += v; mixed[1][i] += v
        }
    }
    let preview = (args[3] as NSString).deletingPathExtension + "-clickmix.wav"
    try writeWAV(path: preview, stereo: mixed)
    print("wrote \(args[3]) + \(preview)")
    exit(0)
}

if args.count == 5, args[1] == "--libtest" {
    // Library roundtrip: fake a cached song from separated stems, then
    // match + stemsPresent + readWAVFloats + moveRoot.
    let fm = FileManager.default
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    try? fm.removeItem(at: root)
    let store = LibraryStore(root: root)
    let src = args[3]
    let srcName = (src as NSString).lastPathComponent
    guard let (size, mtime) = LibraryStore.fileIdentity(path: src) else { exit(3) }
    let rec = SongRecord(audioFile: "source.mp3", sourceName: srcName,
                         sourceSize: size, sourceMtime: mtime, sourcePath: src,
                         title: (srcName as NSString).deletingPathExtension, duration: 275.0,
                         bpm: 130.0, beats: [1.0, 1.46])
    let dir = store.songDir(id: rec.id)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for s in SeparatedSong.names {
        try fm.copyItem(at: URL(fileURLWithPath: "\(args[4])/\(s).wav"),
                        to: store.stemURL(id: rec.id, stem: s))
    }
    store.upsert(rec)
    let store2 = LibraryStore(root: root) // reload from disk
    guard let hit = store2.match(sourcePath: src) else { print("FAIL: no match"); exit(1) }
    print("match: \(hit.title) bpm=\(hit.bpm ?? -1) beats=\(hit.beats.count)")
    print("stemsPresent: \(store2.stemsPresent(hit))")
    let floats = try readWAVFloats(path: store2.stemURL(id: hit.id, stem: "vocals").path)
    print("readWAVFloats: \(floats.count)ch x \(floats[0].count), peak=\(floats.flatMap { $0 }.map(abs).max() ?? 0)")
    let root2 = URL(fileURLWithPath: args[2] + "-2", isDirectory: true)
    try? fm.removeItem(at: root2)
    store2.moveRoot(to: root2)
    print("moveRoot records: \(store2.records.count) (expect 0)")
    print("LIBTEST OK")
    exit(0)
}

@MainActor
func run() {
    let p = StemPlayer()
    let names = ["Original"] + SeparatedSong.names.map { $0.capitalized }
    // reuse vocals.wav as "original" stand-in + 4 stems
    let dir = args[1]
    let urls = (["vocals"] + SeparatedSong.names).map { URL(fileURLWithPath: "\(dir)/\($0).wav") }
    p.load(names: names, urls: urls)
    print("after load: tracks=\(p.trackCount) note=\(p.engineNote)")
    p.toggle()
    print("after toggle: isPlaying=\(p.isPlaying) note=\(p.engineNote)")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 3.0 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("t=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s "
            + "playing=\(p.isPlaying) pos=\(String(format: "%.2f", p.position)) note=\(p.engineNote)")
    }
    p.pause()
    print("after pause: playing=\(p.isPlaying) pos=\(p.position)")
    exit(0)
}

Task { @MainActor in run() }
dispatchMain()
