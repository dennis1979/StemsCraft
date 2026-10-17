import Foundation
import StemsCore

// Usage:
//   StemsCLI <song.mp3|wav|...> <model.onnx> <outdir>   (AVFoundation decode)
//   StemsCLI --decode-only <song>                         (decode check)
//
// Writes <outdir>/{drums,bass,other,vocals}.wav (16-bit 44.1k stereo).
// Mirrors the reference Python pipeline's normalization: whole-song mean/std outside the model.

let args = CommandLine.arguments

var song: [[Float]]
var modelPath: String
var outDir: String
if args.count == 3, args[1] == "--decode-only" {
    let audio = try decodeAudio(path: args[2])
    print("decoded: channels=\(audio.count) frames=\(audio[0].count) "
        + "(\(String(format: "%.1f", Double(audio[0].count) / 44100))s)")
    exit(0)
} else if args.count == 4 {
    song = try decodeAudio(path: args[1])
    modelPath = args[2]
    outDir = args[3]
} else {
    fputs("usage: StemsCLI <song.audio> <model.onnx> <outdir> | StemsCLI --decode-only <song.audio>\n", stderr)
    exit(2)
}

let L = song[0].count
print("song: \(L) samples (\(String(format: "%.1f", Double(L) / 44100.0))s)")
let t0 = Date()
var sSum = 0.0, sSq = 0.0
for ch in 0 ..< 2 {
    for v in song[ch] { sSum += Double(v); sSq += Double(v) * Double(v) }
}
let n = Double(2 * L)
let sMean = sSum / n
let sStd = (sSq / n - sMean * sMean).squareRoot()
let norm = song.map { $0.map { Float((Double($0) - sMean) / (sStd + 1e-8)) } }

let sep = try Separator(modelPath: modelPath)
var lastPct = -1
let stems = try sep.separate(norm) { p in
    let pct = Int(p * 100)
    if pct != lastPct { lastPct = pct; print("progress \(pct)% (\(String(format: "%.0f", Date().timeIntervalSince(t0)))s)") }
    return true
}
let denorm = stems.map { stem in stem.map { ch in ch.map { $0 * Float(sStd) + Float(sMean) } } }
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (i, name) in SeparatedSong.names.enumerated() {
    try writeWAV(path: "\(outDir)/\(name).wav", stereo: denorm[i])
}
print("done in \(String(format: "%.0f", Date().timeIntervalSince(t0)))s -> \(outDir)")
