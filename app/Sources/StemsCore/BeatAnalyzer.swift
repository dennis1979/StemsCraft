import Foundation

public struct TempoResult: Sendable {
    public let bpm: Double
    /// Time (seconds) of the first beat, in [0, 60/bpm).
    public let firstBeat: Double
    /// Sharpness of the beat-phase histogram; ~0 means "no clear beat".
    public let confidence: Double
    /// Beat times in seconds across the whole song, aligned to the actual attacks in the audio
    /// (a constant grid for steady songs, tracked beats for songs whose tempo moves).
    public let beats: [Double]
}

/// Tempo + beat grid detection (ported from the author's earlier JavaScript implementation).
///
/// 1. Onset strength: positive change of log-compressed energy per 256-sample hop,
///    full band + low band (kick), low band weighted higher.
/// 2. Coarse tempo: autocorrelation over 60-200 BPM with a mild prior around 120.
/// 3. Fine tempo + phase: fold the envelope onto one beat period (phase histogram);
///    the right tempo gives the sharpest peak and the peak gives the phase.
public enum BeatAnalyzer {
    /// `mono` is a mono signal at `sampleRate`.
    public static func detectTempo(mono x: [Float], sampleRate: Double = 44100) -> TempoResult {
        let hop = 256
        let win = 512
        let fps = sampleRate / Double(hop)
        let frames = (x.count - win) / hop
        if frames <= 0 || Double(frames) < fps * 4 {
            return TempoResult(bpm: 120, firstBeat: 0, confidence: 0, beats: [])
        }

        // Low band: two cascaded one-pole low-passes at 150 Hz.
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        var lowSig = [Float](repeating: 0, count: x.count)
        var s1: Float = 0, s2: Float = 0
        for i in 0 ..< x.count {
            s1 += a * (x[i] - s1)
            s2 += a * (s1 - s2)
            lowSig[i] = s2
        }

        var eFull = [Float](repeating: 0, count: frames)
        var eLow = [Float](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var sf: Float = 0, sl: Float = 0
            let o = f * hop
            for j in 0 ..< win {
                let v = x[o + j], w = lowSig[o + j]
                sf += v * v
                sl += w * w
            }
            eFull[f] = log1p(1000 * sf / Float(win))
            eLow[f] = log1p(1000 * sl / Float(win))
        }

        var onset = [Float](repeating: 0, count: frames)
        for f in 1 ..< frames {
            onset[f] = max(0, eFull[f] - eFull[f - 1]) + 2 * max(0, eLow[f] - eLow[f - 1])
        }
        onset = subtractLocalMean(onset, radius: 16)
        onset = smooth(onset)

        // --- coarse tempo by autocorrelation ---
        let minLag = Int((fps * 60 / 200).rounded(.down))
        let maxLag = Int((fps * 60 / 60).rounded(.up))
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag ... (maxLag + 1) {
            var sum: Double = 0
            for i in lag ..< frames { sum += Double(onset[i]) * Double(onset[i - lag]) }
            ac[lag] = sum / Double(frames - lag)
        }
        var bestLag = minLag
        var bestScore = -Double.infinity
        for lag in minLag ... maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            let score = ac[lag] * prior
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        var coarse = 60 * fps / Double(bestLag)
        while coarse < 78 { coarse *= 2 }
        while coarse >= 185 { coarse /= 2 }

        // --- fine tempo + phase by phase-histogram sharpness ---
        let bins = 64
        func evaluate(_ bpm: Double) -> (score: Double, phaseFrames: Double) {
            let period = fps * 60 / bpm
            var hist = [Double](repeating: 0, count: bins)
            for i in 0 ..< frames {
                let v = Double(onset[i])
                if v == 0 { continue }
                let ph = Double(i) / period
                hist[Int((ph - ph.rounded(.down)) * Double(bins)) % bins] += v
            }
            var mean = 0.0, peak = -1.0, peakBin = 0
            var sm = [Double](repeating: 0, count: bins)
            for b in 0 ..< bins {
                sm[b] = hist[(b + bins - 1) % bins] * 0.25 + hist[b] * 0.5 + hist[(b + 1) % bins] * 0.25
                mean += sm[b]
            }
            mean /= Double(bins)
            for b in 0 ..< bins where sm[b] > peak { peak = sm[b]; peakBin = b }
            let l = sm[(peakBin + bins - 1) % bins], r = sm[(peakBin + 1) % bins]
            let denom = l - 2 * peak + r
            let offset = denom != 0 ? 0.5 * (l - r) / denom : 0
            let phaseFrames = ((Double(peakBin) + 0.5 + offset) / Double(bins)) * period
            return ((peak - mean) / (mean + 1e-9), phaseFrames)
        }

        var best = (bpm: coarse, score: -Double.infinity, phaseFrames: 0.0)
        for k in -200 ... 200 {
            let bpm = coarse + Double(k) * 0.01
            let r = evaluate(bpm)
            if r.score > best.score { best = (bpm, r.score, r.phaseFrames) }
        }
        // Octave check (e.g. 87 vs 174): folding at the wrong octave splits the histogram
        // into two peaks, so the sharper fold wins. Triple-meter locks (e.g. 93 vs 140,
        // a syncopated R&B groove repeating every 1.5 beats) need x1.5 / x2/3 too.
        for mult in [2.0, 0.5, 1.5, 2.0 / 3.0] {
            let cand = best.bpm * mult
            if cand < 78 || cand > 185 { continue }
            var alt = (bpm: cand, score: -Double.infinity, phaseFrames: 0.0)
            for k in -50 ... 50 {
                let bpm = cand + Double(k) * 0.01
                let r = evaluate(bpm)
                if r.score > alt.score { alt = (bpm, r.score, r.phaseFrames) }
            }
            if alt.score > best.score * 1.05 { best = alt }
        }

        // Prefer an exact integer tempo when it scores almost as well.
        let rounded = best.bpm.rounded()
        if abs(rounded - best.bpm) < 0.06 {
            let r = evaluate(rounded)
            if r.score >= best.score * 0.9 { best = (rounded, r.score, r.phaseFrames) }
        }

        let bpm = (best.bpm * 100).rounded() / 100
        let beatLen = 60 / bpm
        // Frame f covers samples [f*hop, f*hop+win); its onset reflects energy that entered in
        // its newest half, so the event sits ~1.5 hops after the frame start.
        let onsetOffset = 1.5 * Double(hop)
        var firstBeat = (best.phaseFrames * Double(hop) + onsetOffset) / sampleRate
        firstBeat = firstBeat.truncatingRemainder(dividingBy: beatLen)
        if firstBeat < 0 { firstBeat += beatLen }
        let beats = beatTimes(onset: onset, fps: fps, bpm: bpm, fallbackPhase: best.phaseFrames,
                              hop: hop, sampleRate: sampleRate, x: x, low: lowSig)
        return TempoResult(bpm: bpm, firstBeat: beats.first ?? firstBeat, confidence: best.score, beats: beats)
    }

    // MARK: - Beat positions

    /// Beat times for the whole song.
    /// 1. Dynamic-programming beat tracker (Ellis 2007) on the onset envelope: follows the real
    ///    attacks, so tempo drift / live feel does not accumulate error.
    /// 2. If the tracked beats sit on a straight line (steady tempo) they are replaced by that
    ///    fitted line, which is smooth and also gives a more precise tempo than the 0.01 search.
    /// 3. Every beat is finally snapped to the sharpest attack in the raw audio (+-30 ms), so a
    ///    click lands on the transient itself and not on the 5.8 ms envelope frame.
    private static func beatTimes(onset: [Float], fps: Double, bpm: Double, fallbackPhase: Double,
                                  hop: Int, sampleRate: Double, x: [Float], low: [Float]) -> [Double] {
        let n = onset.count
        let period = fps * 60 / bpm // frames per beat
        let frameToSec = { (f: Double) -> Double in (f * Double(hop) + 1.5 * Double(hop)) / sampleRate }
        let duration = Double(x.count) / sampleRate

        // --- DP tracker ---
        var sumSq = 0.0
        for v in onset { sumSq += Double(v) * Double(v) }
        let sd = max(1e-9, (sumSq / Double(max(1, n))).squareRoot())
        let o = onset.map { Double($0) / sd }
        let lo = max(1, Int((period * 0.5).rounded(.up)))
        let hi = Int((period * 2).rounded())
        var cost = [Double](repeating: -Double.infinity, count: hi + 1)
        for d in lo ... hi {
            let r = log(Double(d) / period)
            cost[d] = -100 * r * r
        }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        for t in 0 ..< n {
            var bv = 0.0
            var bp = -1
            let dmax = min(hi, t)
            if dmax >= lo {
                for d in lo ... dmax {
                    let v = score[t - d] + cost[d]
                    if v > bv { bv = v; bp = t - d }
                }
            }
            score[t] = o[t] + bv
            back[t] = bp
        }
        var end = max(0, n - Int(period))
        for t in end ..< n where score[t] > score[end] { end = t }
        var chain: [Int] = []
        var cur = end
        while cur >= 0 { chain.append(cur); cur = back[cur] }
        chain.reverse()

        // --- grid or tracked ---
        var times: [Double] // seconds, before attack refinement
        var gridMode = false
        var a = fallbackPhase, b = period // frames: beat k at a + b*k
        if chain.count >= 8 {
            let f0 = Double(chain[0])
            var sk = 0.0, sf = 0.0, skk = 0.0, skf = 0.0
            let ks = chain.map { ((Double($0) - f0) / period).rounded() }
            for (i, f) in chain.enumerated() {
                let k = ks[i], fv = Double(f)
                sk += k; sf += fv; skk += k * k; skf += k * fv
            }
            let m = Double(chain.count)
            let den = m * skk - sk * sk
            if den > 0 {
                let bb = (m * skf - sk * sf) / den
                let aa = (sf - bb * sk) / m
                var se = 0.0
                for (i, f) in chain.enumerated() {
                    let e = Double(f) - (aa + bb * ks[i])
                    se += e * e
                }
                let rmsSec = (se / m).squareRoot() * Double(hop) / sampleRate
                if rmsSec < 0.012 && abs(bb - period) / period < 0.01 {
                    a = aa; b = bb; gridMode = true
                } else if rmsSec < 0.030 && abs(bb - period) / period < 0.01 {
                    // Near-metronomic song (tracker noise, not real drift): the fitted
                    // grid is far more accurate than per-beat tracking, so use it too.
                    // Real rubato/swing deviates far more than this and stays tracked.
                    a = aa; b = bb; gridMode = true
                }
            }
        }
        if !gridMode && chain.count < 8 { gridMode = true } // not enough to track: histogram grid
        if gridMode {
            var k = Int((-a / b).rounded(.up))
            times = []
            while true {
                let t = frameToSec(a + b * Double(k))
                if t >= duration - 0.05 { break }
                if t >= 0 { times.append(t) }
                k += 1
            }
        } else {
            times = chain.map { frameToSec(Double($0)) }.filter { $0 >= 0 && $0 < duration - 0.05 }
        }
        if times.isEmpty { return [] }

        // --- snap to the real attack ---
        if gridMode {
            // One common shift: median of the per-beat corrections (robust to the odd bad beat).
            var deltas: [Double] = []
            let stride = max(1, times.count / 200)
            for i in Swift.stride(from: 0, to: times.count, by: stride) {
                if let r = refineAttack(times[i], x: x, low: low, sampleRate: sampleRate) {
                    deltas.append(r - times[i])
                }
            }
            if deltas.count >= 5 {
                deltas.sort()
                let shift = max(-0.04, min(0.04, deltas[deltas.count / 2]))
                times = times.map { $0 + shift }.filter { $0 >= 0 }
            }
        } else {
            times = times.map { t in
                if let r = refineAttack(t, x: x, low: low, sampleRate: sampleRate) { return r }
                return t
            }
        }
        return times
    }

    /// Finds the attack closest to `t` in the raw signal: the position where the energy of the
    /// next 128 samples most exceeds the energy of the previous 128 samples. nil if no clear attack.
    private static func refineAttack(_ t: Double, x: [Float], low: [Float], sampleRate: Double) -> Double? {
        let half = Int(0.03 * sampleRate)
        let w = 128
        let c = Int((t * sampleRate).rounded())
        let s0 = c - half - w
        let s1 = c + half + w
        guard s0 >= 0, s1 < x.count else { return nil }
        let m = s1 - s0 + 1
        var pre = [Double](repeating: 0, count: m + 1)
        for i in 0 ..< m {
            pre[i + 1] = pre[i] + Double(abs(x[s0 + i]) + 2 * abs(low[s0 + i]))
        }
        var best = -Double.infinity
        var bestJ = 0
        var absSum = 0.0
        for j in -half ... half {
            let i = j + half + w
            let v = (pre[i + w] - pre[i]) - (pre[i] - pre[i - w])
            absSum += abs(v)
            if v > best { best = v; bestJ = j }
        }
        let meanAbs = absSum / Double(2 * half + 1)
        guard best > 0, best > 2.5 * meanAbs else { return nil }
        return t + Double(bestJ) / sampleRate
    }

    /// Convenience: mix stereo `[[L],[R]]` to mono and analyse.
    public static func detectTempo(stereo: [[Float]], sampleRate: Double = 44100) -> TempoResult {
        guard let l = stereo.first else { return TempoResult(bpm: 120, firstBeat: 0, confidence: 0, beats: []) }
        if stereo.count < 2 { return detectTempo(mono: l, sampleRate: sampleRate) }
        let r = stereo[1]
        var mono = [Float](repeating: 0, count: l.count)
        for i in 0 ..< l.count { mono[i] = 0.5 * (l[i] + r[i]) }
        return detectTempo(mono: mono, sampleRate: sampleRate)
    }

    private static func subtractLocalMean(_ arr: [Float], radius: Int) -> [Float] {
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        var sum: Float = 0
        var count = 0
        for i in 0 ..< min(n, radius) { sum += arr[i]; count += 1 }
        for i in 0 ..< n {
            let add = i + radius
            let rem = i - radius - 1
            if add < n { sum += arr[add]; count += 1 }
            if rem >= 0 { sum -= arr[rem]; count -= 1 }
            out[i] = max(0, arr[i] - sum / Float(max(1, count)))
        }
        return out
    }

    private static func smooth(_ arr: [Float]) -> [Float] {
        let n = arr.count
        var out = [Float](repeating: 0, count: n)
        let k: [Float] = [1, 2, 3, 2, 1]
        for i in 0 ..< n {
            var s: Float = 0, w: Float = 0
            for j in -2 ... 2 {
                let idx = i + j
                if idx >= 0 && idx < n { s += arr[idx] * k[j + 2]; w += k[j + 2] }
            }
            out[i] = s / w
        }
        return out
    }
}

/// Click track for the metronome: short sine ticks on the beat grid, as 16-bit stereo WAV
/// of the same length as the song, so it can be scheduled sample-aligned with the stems.
public enum ClickTrack {
    /// Constant-tempo grid (kept for tests / fallback).
    public static func writeWAV(path: String, frames: Int, bpm: Double, firstBeat: Double,
                                sampleRate: Int = 44100, gain: Float = 0.8) throws {
        precondition(bpm > 0)
        var beats: [Double] = []
        var t = firstBeat
        let dur = Double(frames) / Double(sampleRate)
        while t < dur { beats.append(t); t += 60 / bpm }
        try writeWAV(path: path, frames: frames, beats: beats, sampleRate: sampleRate, gain: gain)
    }

    /// One click per entry of `beats` (seconds). The file is as long as the song so it can be
    /// scheduled sample-aligned with the stems.
    public static func writeWAV(path: String, frames: Int, beats: [Double],
                                sampleRate: Int = 44100, gain: Float = 0.8) throws {
        var pcm = [Int16](repeating: 0, count: frames * 2)
        let clickLen = Int(0.04 * Double(sampleRate))
        let freq = 1500.0
        for beat in beats {
            let start = Int((beat * Double(sampleRate)).rounded())
            if start < 0 || start >= frames { continue }
            for j in 0 ..< clickLen {
                let i = start + j
                if i >= frames { break }
                let t = Double(j) / Double(sampleRate)
                let attack = min(1, Double(j) / 44.0) // ~1 ms ramp: no hard edge
                let env = attack * exp(-t / 0.007)
                let v = Float(sin(2 * Double.pi * freq * t) * env) * gain
                let s = Int16(max(-1, min(1, v)) * 32767)
                pcm[2 * i] = s
                pcm[2 * i + 1] = s
            }
        }

        var data = Data(capacity: 44 + pcm.count * 2)
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count * 2))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
