import Foundation
import AVFoundation
import Accelerate

/// Forward-FFT-only spectral QC (see Session-Close-Concept.md "Frequency
/// response comparison"). Computes one long-term averaged spectrum per
/// file — Welch's method: overlapping Hann-windowed FFT frames, power
/// averaged across the whole file — then bands it to 1/12-octave for a
/// readable log-frequency overlay across a batch. This is a QC signal
/// ("how close are these, really"), never used to alter a file's tone —
/// corrective spectral matching (which would need iFFT resynthesis) is
/// explicitly out of scope.
/// Display reference for the batch spectrum overlay. SpectrumAnalyzer's raw
/// per-band values are a power-spectral-density-style average (mean power
/// per FFT bin within each band), which is flat for white noise (equal
/// power per Hz) and slopes down ~3dB/octave for pink noise (equal power
/// per octave) — that's "white reference," the convention some analyzers
/// (e.g. iZotope Insight) use by default, and the reason most real-world
/// music reads as tilted down on them. "Pink reference" applies a
/// +3dB/octave display correction so pink noise (and typically-tilted real
/// program material) reads flat instead — the convention most RTAs and
/// mastering meters use, and what most engineers are calibrated to expect.
/// This only affects display; it never touches the underlying measurement,
/// outlier detection, or anything stored on AudioFileRecord.
enum SpectrumReference: String, CaseIterable, Identifiable {
    case pink
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pink: return "Pink (flat for music)"
        case .white: return "White (flat for noise)"
        }
    }
}

enum SpectrumAnalyzer {

    /// Bands per octave — 1/12-octave is one musical semitone per band,
    /// noticeably finer than a standard 1/3-octave RTA (4x the band
    /// density). Generated from a 1000Hz reference (`center = 1000 *
    /// 2^(n/12)`) rather than hand-listed, so the table isn't hostage to a
    /// hardcoded array if this ever needs tuning again.
    private static let bandsPerOctave = 12

    /// ~140 bands, 20Hz–20kHz — index-aligned with every
    /// AudioFileRecord.spectrumBandsDB array. See the note on `fftSize`
    /// below for why the very lowest handful of these bands still won't be
    /// fully resolved even at this window size — that's an inherent
    /// frequency-resolution limit, not a bug.
    static let bandCenterFrequenciesHz: [Double] = {
        var centers: [Double] = []
        var n = -100 // 1000 * 2^(-100/12) ≈ 0.24Hz — comfortably below 20Hz, loop below trims it
        while true {
            let hz = 1000 * pow(2, Double(n) / Double(bandsPerOctave))
            if hz > 20000 { break }
            if hz >= 20 { centers.append(hz) }
            n += 1
        }
        return centers
    }()

    /// Per-band pink-reference display correction, index-aligned with
    /// bandCenterFrequenciesHz — add this to a band's raw (white-referenced)
    /// dB value to display it pink-referenced instead (see SpectrumReference
    /// above). +10*log10(f / f_ref) dB is the standard +3dB/octave tilt
    /// that cancels pink noise's -3dB/octave slope in this band-averaged
    /// (not band-summed) measurement; f_ref is arbitrary (any reference
    /// frequency works, it only shifts every band by the same constant) so
    /// the lowest band is used for convenience.
    static let pinkReferenceCorrectionDB: [Double] = {
        guard let refHz = bandCenterFrequenciesHz.first else { return [] }
        return bandCenterFrequenciesHz.map { 10 * log10($0 / refHz) }
    }()

    /// Band half-bandwidth in octaves is 1/(2 * bandsPerOctave) — the
    /// factor each center is divided/multiplied by to get its lower/upper
    /// edge. (For the old 1/3-octave scheme this was the hardcoded
    /// `2^(1/6)`; this is the same formula generalized to bandsPerOctave.)
    private static let bandEdgeFactor = pow(2.0, 1.0 / (2.0 * Double(bandsPerOctave)))

    /// Power of two so vDSP's real-FFT (zrip) can run directly with no
    /// resampling. 32768 samples is ~743ms at 44.1kHz — deliberately much
    /// larger than a real-time analyzer would use, since this only ever
    /// runs offline (no latency to protect) and 1/12-octave bands are
    /// narrow enough that a small window's bin spacing would leave most of
    /// them empty. Even at this size, frequency resolution is a hard
    /// physical tradeoff against window length: a 1/12-octave band at 20Hz
    /// is only ~1.2Hz wide, narrower than this window's ~1.35Hz bin
    /// spacing, so the very lowest few bands (roughly below 30-40Hz) may
    /// still read as flat/near-duplicate values rather than fully
    /// independent measurements. That's inherent to any FFT-based analyzer
    /// at this resolution, not something a bigger window alone fixes short
    /// of a much longer (and much slower) transform.
    private static let fftSize = 32768
    private static let hopSize = fftSize / 2 // 50% overlap

    enum SpectrumError: Error { case unreadable, tooShort }

    static func analyze(file: AVAudioFile) throws -> [Double] {
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard channelCount >= 1, sampleRate > 0 else { throw SpectrumError.unreadable }

        let monoSamples = try readMonoSum(file: file, channelCount: channelCount)
        guard monoSamples.count >= fftSize else { throw SpectrumError.tooShort }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw SpectrumError.unreadable }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var powerSum = [Double](repeating: 0, count: fftSize / 2)
        var frameCount = 0
        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        var start = 0
        while start + fftSize <= monoSamples.count {
            monoSamples.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }

            realp.withUnsafeMutableBufferPointer { realPtr in
                imagp.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                    // Standard Accelerate real-FFT prep: reinterpret the
                    // windowed real samples as fftSize/2 interleaved
                    // complex pairs, then let vDSP_fft_zrip unpack them
                    // during the transform itself.
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            for i in 0..<(fftSize / 2) { powerSum[i] += Double(magnitudes[i]) }
            frameCount += 1
            start += hopSize
        }

        guard frameCount > 0 else { throw SpectrumError.tooShort }

        let averagedPower = powerSum.map { $0 / Double(frameCount) }
        let binHz = sampleRate / Double(fftSize)

        return bandCenterFrequenciesHz.map { center in
            let lower = center / bandEdgeFactor
            let upper = center * bandEdgeFactor
            let lowBin = max(1, Int((lower / binHz).rounded()))
            let highBin = min(averagedPower.count - 1, Int((upper / binHz).rounded()))
            guard lowBin <= highBin else { return -160.0 }
            let bandPower = averagedPower[lowBin...highBin].reduce(0, +) / Double(highBin - lowBin + 1)
            return bandPower > 0 ? 10 * log10(bandPower) : -160.0
        }
    }

    /// Mono sum (L+R)/2 for spectral QC — one tonal-balance curve per file
    /// rather than a channel-by-channel breakdown, so a batch overlay of
    /// several files stays readable.
    private static func readMonoSum(file: AVAudioFile, channelCount: Int) throws -> [Float] {
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(Int(file.length))

        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize) else {
            throw SpectrumError.unreadable
        }
        file.framePosition = 0
        while true {
            try file.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            if channelCount == 1 {
                monoSamples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            } else {
                let l = data[0]; let r = data[1]
                for i in 0..<n { monoSamples.append((l[i] + r[i]) * 0.5) }
            }
            if n < Int(blockSize) { break }
        }
        return monoSamples
    }

    /// Per-band deviation of `record` vs. the batch average — used to flag
    /// outliers in the overlay (e.g. "Track 4 is +3dB in the 2-5kHz band vs.
    /// the rest of the album"). Returns nil for bands where either side has
    /// no data.
    static func outlierBands(record: [Double], batchAverage: [Double], thresholdDB: Double) -> [Int] {
        guard record.count == batchAverage.count else { return [] }
        var flagged: [Int] = []
        for i in 0..<record.count {
            if abs(record[i] - batchAverage[i]) >= thresholdDB {
                flagged.append(i)
            }
        }
        return flagged
    }

    /// Batch average spectrum — index-aligned mean across every file that
    /// has spectral data, ignoring ones that failed to measure (e.g. too
    /// short for a full FFT window).
    static func batchAverage(_ spectra: [[Double]]) -> [Double]? {
        guard let bandCount = spectra.first?.count, bandCount > 0 else { return nil }
        var sums = [Double](repeating: 0, count: bandCount)
        var counts = [Int](repeating: 0, count: bandCount)
        for spectrum in spectra where spectrum.count == bandCount {
            for i in 0..<bandCount {
                sums[i] += spectrum[i]
                counts[i] += 1
            }
        }
        return (0..<bandCount).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : -160.0 }
    }
}
