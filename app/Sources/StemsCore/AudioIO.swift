import AVFoundation
import Foundation

public enum AudioIOError: Error {
    case unreadable(String)
    case conversion(String)
}

/// Decode any audio file to stereo Float32 @44.1k. Returns [2][L].
/// Uses AVAssetReader (decodes mp3/m4a/aac/wav/flac, resamples, mixes down).
public func decodeAudio(path: String) throws -> [[Float]] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else {
        throw AudioIOError.unreadable("no audio track")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    let reader: AVAssetReader
    do {
        reader = try AVAssetReader(asset: asset)
    } catch {
        throw AudioIOError.unreadable("\(error)")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw AudioIOError.unreadable("\(reader.error?.localizedDescription ?? "reader failed")")
    }
    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(1 << 20)
    right.reserveCapacity(1 << 20)
    while let sample = output.copyNextSampleBuffer() {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
        var ptr: UnsafeMutablePointer<CChar>?
        var totalLen = 0
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &totalLen,
                                           dataPointerOut: &ptr) == noErr,
            let base = ptr else { continue }
        let frames = totalLen / 8 // interleaved stereo float32
        let f = base.withMemoryRebound(to: Float.self, capacity: frames * 2) { $0 }
        for i in 0 ..< frames {
            left.append(f[2 * i])
            right.append(f[2 * i + 1])
        }
    }
    if reader.status == .failed {
        throw AudioIOError.unreadable("\(reader.error?.localizedDescription ?? "read failed")")
    }
    if left.isEmpty { throw AudioIOError.unreadable("decoded 0 frames") }
    return [left, right]
}

/// Read a 16/24/32-bit stereo WAV written by writeWAV (or any PCM WAV readable
/// by AVAudioFile) into [[L],[R]] Float32 @44.1k. Used for cached stems.
public func readWAVFloats(path: String) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = file.processingFormat
    let n = Int(file.length)
    guard n > 0, fmt.channelCount >= 1 else { throw AudioIOError.unreadable("empty file") }
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else {
        throw AudioIOError.conversion("cannot make buffer")
    }
    try file.read(into: buf, frameCount: AVAudioFrameCount(n))
    let count = Int(buf.frameLength)
    guard let data = buf.floatChannelData else { throw AudioIOError.conversion("not float") }
    let ch1 = Array(UnsafeBufferPointer(start: data[0], count: count))
    let ch2 = fmt.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: count)) : ch1
    // Library stems are always written at 44.1k by writeWAV; anything else is unexpected.
    guard abs(fmt.sampleRate - 44100) < 1 else {
        throw AudioIOError.conversion("expected 44.1k, got \(fmt.sampleRate)")
    }
    return [ch1, ch2]
}

/// Write stereo 16-bit WAV.
public func writeWAV(path: String, stereo: [[Float]]) throws {
    let n = stereo[0].count
    var data = Data(capacity: 44 + n * 4)
    func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    func u32(_ v: UInt32) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8(v >> 24))
    }
    func str(_ s: String) { data.append(contentsOf: s.utf8) }
    str("RIFF"); u32(UInt32(36 + n * 4)); str("WAVE"); str("fmt "); u32(16)
    u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
    str("data"); u32(UInt32(n * 4))
    for i in 0 ..< n {
        for ch in 0 ..< 2 {
            let s = max(-1, min(1, stereo[ch][i]))
            let v = Int(s < 0 ? s * 32768 : s * 32767)
            u16(UInt16(bitPattern: Int16(v)))
        }
    }
    try data.write(to: URL(fileURLWithPath: path))
}
