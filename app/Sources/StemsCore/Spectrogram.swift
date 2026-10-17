import Foundation

// Portions derived from facebookresearch/demucs (MIT License, Copyright (c) Meta Platforms,
// Inc. and affiliates). See THIRD_PARTY_NOTICES.md.
//
// Checked against the PyTorch implementation during development: forward 132 dB, inverse 137 dB.
// Mirrors demucs/htdemucs.py _spec/_ispec: nfft=4096 hop=1024 hann periodic,
// ortho, center=True reflect, _spec trims (top bin, 2 frames/side).

public let sampleRate = 44100
public let nfft = 4096
public let hop = 1024
private let pad = 1536
private let invSqrtN: Float = 1.0 / 64.0
private let sqrtN: Float = 64.0

private func hannPeriodic(_ n: Int) -> [Float] {
    (0 ..< n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
}

private let window = hannPeriodic(nfft)
private let windowSq = window.map { $0 * $0 }

/// torch F.pad reflect (== numpy 'reflect'). Pads here are << length.
private func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
    let L = x.count
    func at(_ p: Int) -> Float {
        var p = p
        if p < 0 { p = -p }
        if p >= L { p = 2 * (L - 1) - p }
        return x[p]
    }
    var out = [Float](repeating: 0, count: left + L + right)
    for i in 0 ..< out.count { out[i] = at(i - left) }
    return out
}

/// Iterative radix-2 complex FFT, Float32. Forward and inverse both unscaled
/// (inverse returns N× the true values); call sites apply ortho scales.
private struct Radix2FFT {
    let n: Int
    let rev: [Int]
    let cosT: [Float]
    let sinT: [Float]

    init(_ n: Int) {
        self.n = n
        var rev = [Int](repeating: 0, count: n)
        var bits = 0
        var m = n
        while m > 1 { bits += 1; m >>= 1 }
        for i in 0 ..< n {
            var r = 0, x = i
            for _ in 0 ..< bits { r = (r << 1) | (x & 1); x >>= 1 }
            rev[i] = r
        }
        self.rev = rev
        cosT = (0 ..< n / 2).map { Float(cos(2 * Double.pi * Double($0) / Double(n))) }
        sinT = (0 ..< n / 2).map { Float(sin(2 * Double.pi * Double($0) / Double(n))) }
    }

    func run(_ re: inout [Float], _ im: inout [Float], inverse: Bool) {
        for i in 0 ..< n {
            let j = rev[i]
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var k = 0
            while k < n {
                var j = 0
                while j < half {
                    let tw = j * step
                    let wr = cosT[tw], wi = inverse ? sinT[tw] : -sinT[tw]
                    let xr = re[k + j + half], xi = im[k + j + half]
                    let tr = wr * xr - wi * xi, ti = wr * xi + wi * xr
                    re[k + j + half] = re[k + j] - tr
                    im[k + j + half] = im[k + j] - ti
                    re[k + j] += tr
                    im[k + j] += ti
                    j += 1
                }
                k += len
            }
            len <<= 1
        }
    }
}

private let fft = Radix2FFT(nfft)

/// One complex spectrum (full 4096 bins) of a windowed frame.
private func frameSpectrum(_ frame: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
    var re = [Float](repeating: 0, count: nfft)
    for n in 0 ..< nfft { re[n] = frame[frame.startIndex + n] * window[n] }
    var im = [Float](repeating: 0, count: nfft)
    fft.run(&re, &im, inverse: false)
    return (re.map { $0 * invSqrtN }, im.map { $0 * invSqrtN })
}

/// _spec for one channel. Returns frames+freqs and re/im as [2048][le] row-major.
public func stftForward(_ x: [Float]) -> (le: Int, re: [Float], im: [Float]) {
    let L = x.count
    let le = (L + hop - 1) / hop
    var y = reflectPad(x, left: pad, right: pad + le * hop - L)
    y = reflectPad(y, left: nfft / 2, right: nfft / 2)
    let nFrames = (y.count - nfft) / hop + 1
    var re = [Float](repeating: 0, count: 2048 * nFrames)
    var im = [Float](repeating: 0, count: 2048 * nFrames)
    for k in 0 ..< nFrames {
        let (R, I) = frameSpectrum(y[k * hop ..< k * hop + nfft])
        for f in 0 ..< 2048 {
            re[f * nFrames + k] = R[f]
            im[f * nFrames + k] = I[f]
        }
    }
    var ro = [Float](repeating: 0, count: 2048 * le)
    var io = [Float](repeating: 0, count: 2048 * le)
    for f in 0 ..< 2048 {
        for t in 0 ..< le {
            ro[f * le + t] = re[f * nFrames + 2 + t]
            io[f * le + t] = im[f * nFrames + 2 + t]
        }
    }
    return (le, ro, io)
}

/// _ispec for one channel. z is (re, im) [2048][le]; returns `length` samples.
public func stftInverse(re: [Float], im: [Float], le: Int, length: Int) -> [Float] {
    let nFrames = le + 4
    var R = [Float](repeating: 0, count: 2049 * nFrames)
    var I = [Float](repeating: 0, count: 2049 * nFrames)
    for f in 0 ..< 2048 {
        for t in 0 ..< le {
            R[f * nFrames + 2 + t] = re[f * le + t]
            I[f * nFrames + 2 + t] = im[f * le + t]
        }
    }
    let bufLen = (nFrames - 1) * hop + nfft
    var buf = [Float](repeating: 0, count: bufLen)
    var env = [Float](repeating: 0, count: bufLen)
    for k in 0 ..< nFrames {
        var sr = [Float](repeating: 0, count: nfft), si = [Float](repeating: 0, count: nfft)
        for f in 0 ..< 2049 {
            sr[f] = R[f * nFrames + k]
            si[f] = I[f * nFrames + k]
        }
        for f in 2049 ..< nfft {
            sr[f] = sr[nfft - f]
            si[f] = -si[nfft - f]
        }
        fft.run(&sr, &si, inverse: true)
        for n in 0 ..< nfft {
            buf[k * hop + n] += sr[n] / sqrtN * window[n]
            env[k * hop + n] += windowSq[n]
        }
    }
    for n in 0 ..< bufLen { if env[n] > 1e-8 { buf[n] /= env[n] } }
    let start = nfft / 2 + pad
    return Array(buf[start ..< start + length])
}
