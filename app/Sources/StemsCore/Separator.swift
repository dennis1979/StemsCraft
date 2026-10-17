import Foundation
import OnnxRuntimeBindings

// Portions derived from facebookresearch/demucs (MIT License, Copyright (c) Meta Platforms,
// Inc. and affiliates). See THIRD_PARTY_NOTICES.md.

// HTDemucs separation pipeline (mirrors the reference Python pipeline + demucs/apply.py):
// whole-song norm -> split 7.8 s / overlap 0.25 triangle -> per-chunk
// (Swift STFT -> norm -> middle.onnx -> _mask -> Swift iSTFT + time branch)
// -> overlap-add -> denorm. shifts=0 (production uses shifts=1; see ab.py).

public let chunkSamples = Int(7.8 * Double(sampleRate)) // 343980
private let strideSamples = Int(0.75 * Double(chunkSamples))

public enum SeparatorError: Error {
    case badModel(String)
    case inference(String)
}

public struct SeparatedSong {
    /// [stem][channel][sample], stems order: drums, bass, other, vocals
    public var stems: [[[Float]]]
    public static let names = ["drums", "bass", "other", "vocals"]
}

public final class Separator {
    private let session: ORTSession

    public init(modelPath: String) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        do {
            session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        } catch {
            throw SeparatorError.badModel("\(error)")
        }
    }

    private func value(_ floats: [Float], shape: [NSNumber]) throws -> ORTValue {
        // NOTE: RawBufferPointer.count is already in bytes.
        let data = floats.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }

    /// Run the middle model on one padded chunk. Returns (spec, waveT):
    /// spec [4 stems][4 q][2048][Tc], waveT [4][2][SEG].
    private func runMiddle(x: [Float], xt: [Float], mean: Float, std: Float,
                           meant: Float, stdt: Float, tc: Int) throws -> (spec: [Float], waveT: [Float]) {
        let inputs: [String: ORTValue] = try [
            "x": value(x, shape: [1, 4, 2048, tc] as [NSNumber]),
            "xt": value(xt, shape: [1, 2, chunkSamples] as [NSNumber]),
            "mean": value([mean], shape: [1, 1, 1, 1] as [NSNumber]),
            "std": value([std], shape: [1, 1, 1, 1] as [NSNumber]),
            "meant": value([meant], shape: [1, 1, 1] as [NSNumber]),
            "stdt": value([stdt], shape: [1, 1, 1] as [NSNumber]),
        ]
        let out: [String: ORTValue]
        do {
            out = try session.run(withInputs: inputs, outputNames: ["spec", "wave"], runOptions: nil)
        } catch {
            throw SeparatorError.inference("\(error)")
        }
        guard let s = out["spec"], let w = out["wave"] else {
            throw SeparatorError.inference("missing outputs")
        }
        let sd = try s.tensorData() as Data, wd = try w.tensorData() as Data
        let spec = sd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let waveT = wd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (spec, waveT)
    }

    /// Separate normalized stereo song ([2][L] @44.1k). progress: 0..1, return false to cancel.
    public func separate(_ song: [[Float]], progress: (Double) -> Bool = { _ in true }) throws -> [[[Float]]] {
        let L = song[0].count
        var acc = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: L), count: 2), count: 4)
        var sumw = [Float](repeating: 0, count: L)
        var tri = [Float](repeating: 0, count: chunkSamples)
        for i in 0 ..< chunkSamples / 2 { tri[i] = Float(i + 1) / Float(chunkSamples / 2) }
        for i in chunkSamples / 2 ..< chunkSamples { tri[i] = Float(chunkSamples - i) / Float(chunkSamples / 2) }

        var offsets: [Int] = []
        var off = 0
        while off < L { offsets.append(off); off += strideSamples }

        for (n, o) in offsets.enumerated() {
            if !progress(Double(n) / Double(offsets.count)) {
                throw CancellationError()
            }
            let ln = min(chunkSamples, L - o)
            // zero-pad tail to SEG first (torch forward pads short inputs the same way,
            // so inner norm stats match exactly)
            var chunk = [[Float]](repeating: [Float](repeating: 0, count: chunkSamples), count: 2)
            for ch in 0 ..< 2 {
                chunk[ch].replaceSubrange(0 ..< ln, with: song[ch][o ..< o + ln])
            }
            // STFT both channels
            let (tc, lre, lim) = stftForward(chunk[0])
            let (_, rre, rim) = stftForward(chunk[1])
            // mag complex-as-channels [4][2048][tc]: L.re L.im R.re R.im
            let F = 2048
            var mag = [Float](repeating: 0, count: 4 * F * tc)
            for f in 0 ..< F {
                for t in 0 ..< tc {
                    mag[(0 * F + f) * tc + t] = lre[f * tc + t]
                    mag[(1 * F + f) * tc + t] = lim[f * tc + t]
                    mag[(2 * F + f) * tc + t] = rre[f * tc + t]
                    mag[(3 * F + f) * tc + t] = rim[f * tc + t]
                }
            }
            var mSum = 0.0, mSq = 0.0
            for v in mag { mSum += Double(v); mSq += Double(v) * Double(v) }
            let mN = Double(mag.count)
            let mean = Float(mSum / mN)
            let std = Float((mSq / mN - (mSum / mN) * (mSum / mN)).squareRoot())
            let xn = mag.map { ($0 - mean) / (std + 1e-5) }
            // wave branch norm (over padded chunk, like torch)
            var wSum = 0.0, wSq = 0.0
            for ch in 0 ..< 2 {
                for v in chunk[ch] { wSum += Double(v); wSq += Double(v) * Double(v) }
            }
            let wN = Double(2 * chunkSamples)
            let meant = Float(wSum / wN)
            let stdt = Float((wSq / wN - (wSum / wN) * (wSum / wN)).squareRoot())
            var xtn = [Float](repeating: 0, count: 2 * chunkSamples)
            for ch in 0 ..< 2 {
                for i in 0 ..< chunkSamples {
                    xtn[ch * chunkSamples + i] = (chunk[ch][i] - meant) / (stdt + 1e-5)
                }
            }
            let (spec, waveT) = try runMiddle(x: xn, xt: xtn, mean: mean, std: std,
                                              meant: meant, stdt: stdt, tc: tc)
            if n == 0, ProcessInfo.processInfo.environment["STEMS_DEBUG"] != nil {
                print("dbg mean=\(mean) std=\(std) meant=\(meant) stdt=\(stdt)")
                print("dbg xn[0..<4]=\(Array(xn[0 ..< 4])) xtn[0..<4]=\(Array(xtn[0 ..< 4]))")
                print("dbg spec[0..<4]=\(Array(spec[0 ..< 4])) waveT[0..<4]=\(Array(waveT[0 ..< 4]))")
            }
            // _mask (cac) is reshape-only; iSTFT per (stem, ch); add time branch.
            // spec layout [s][q][f][t], q = ch*2+ri.
            for s in 0 ..< 4 {
                for ch in 0 ..< 2 {
                    var zre = [Float](repeating: 0, count: F * tc)
                    var zim = [Float](repeating: 0, count: F * tc)
                    for f in 0 ..< F {
                        for t in 0 ..< tc {
                            zre[f * tc + t] = spec[((s * 4 + ch * 2 + 0) * F + f) * tc + t]
                            zim[f * tc + t] = spec[((s * 4 + ch * 2 + 1) * F + f) * tc + t]
                        }
                    }
                    let wf = stftInverse(re: zre, im: zim, le: tc, length: chunkSamples)
                    for i in 0 ..< ln {
                        let v = (waveT[(s * 2 + ch) * chunkSamples + i] + wf[i]) * tri[i]
                        acc[s][ch][o + i] += v
                    }
                }
            }
            for i in 0 ..< ln { sumw[o + i] += tri[i] }
        }
        for s in 0 ..< 4 {
            for ch in 0 ..< 2 {
                for i in 0 ..< L { acc[s][ch][i] /= sumw[i] }
            }
        }
        return acc
    }
}
