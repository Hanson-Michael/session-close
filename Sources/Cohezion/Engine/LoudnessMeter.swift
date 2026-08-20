import Foundation
import AVFoundation

/// ITU-R BS.1770-4 / EBU R128 loudness measurement: K-weighted, gated
/// Integrated LUFS (the target-setting metric), plus ungated Momentary
/// (400ms) and Short-term (3s) maximums as QC readouts, plus a Loudness
/// Range (LRA) figure per EBU Tech 3342. True Peak (see TruePeakMeter.swift)
/// is measured in the same streaming pass for efficiency, since both need a
/// full read of every channel.
///
/// This follows the published algorithm directly (K-weighting filter
/// coefficients generalized to arbitrary sample rates via the standard
/// analog-prototype parameters + bilinear transform, 400ms/75%-overlap
/// gating blocks, absolute -70 LUFS gate then relative gate at mean-10LU)
/// rather than a certified reference implementation's exact fixed-point
/// behavior — a practical, production-tool-grade measurement, same spirit
/// as TruePeakMeter's own "practical approximation" framing.
enum LoudnessMeter {

    struct Result {
        /// Gated, whole-file — the target-setting metric.
        var integratedLUFS: Double
        /// Highest ungated 400ms window over the file. QC readout, not a
        /// target — good for spotting one hot section.
        var momentaryMaxLUFS: Double
        /// Highest ungated 3s window over the file. QC readout, not a
        /// target.
        var shortTermMaxLUFS: Double
        /// EBU Tech 3342 loudness range: P95 - P10 of the gated short-term
        /// distribution. Bonus stat, cheap once short-term's computed.
        var loudnessRangeLRA: Double
        /// Oversampled True Peak, dBTP — the hotter of the two channels for
        /// a stereo file (so neither channel can end up past the ceiling).
        var truePeakDBTP: Double
    }

    enum MeterError: Error {
        case unreadable(String)
        case zeroLength
    }

    private static let hopSeconds = 0.1     // 100ms — standard gating-block hop
    private static let momentarySlots = 4   // 4 * 100ms = 400ms
    private static let shortTermSlots = 30  // 30 * 100ms = 3s
    private static let absoluteGateLUFS = -70.0
    private static let integratedRelativeGateLU = 10.0
    private static let lraRelativeGateLU = 20.0 // EBU Tech 3342

    static func measure(url: URL) throws -> Result {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw MeterError.unreadable("Could not open file")
        }
        return try measure(file: file)
    }

    static func measure(file: AVAudioFile) throws -> Result {
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard channelCount >= 1, sampleRate > 0 else { throw MeterError.zeroLength }

        let slotSamples = max(1, Int((sampleRate * hopSeconds).rounded()))

        var filters = (0..<channelCount).map { _ in KWeightingFilter(sampleRate: sampleRate) }
        // TruePeakAccumulator is a class — its instances' internal state
        // mutates via process(), but the array itself (which reference each
        // slot holds) never gets reassigned, so this can be a `let`. (The
        // per-channel `filters` array right below stays `var`: KWeightingFilter
        // is a struct with a `mutating` process(), so calling
        // filters[ch].process(...) genuinely mutates that array's storage.)
        let peakAccumulators = (0..<channelCount).map { _ in TruePeakAccumulator(sampleRate: sampleRate) }

        // Per-channel sum-of-squares for each completed 100ms slot.
        var slotSumSq: [[Double]] = Array(repeating: [], count: channelCount)
        var currentSlotSumSq = [Double](repeating: 0, count: channelCount)
        var samplesInCurrentSlot = 0

        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
            throw MeterError.unreadable("Could not allocate buffer")
        }

        file.framePosition = 0
        while true {
            try file.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }

            // True Peak scanning has no notion of slot boundaries, so it's
            // fine (and simpler) to hand each channel its whole block in
            // one call, outside the per-sample loop below.
            for ch in 0..<channelCount {
                peakAccumulators[ch].process(data[ch], count: n)
            }

            // K-weighting + slot accumulation, on the other hand, must
            // advance sample-by-sample across *all* channels together —
            // each 100ms slot has to close at the same source sample for
            // every channel, so the outer loop is over sample index, not
            // channel index (looping fully through one channel before
            // starting the next would attribute an entire block's worth of
            // that channel's energy to whichever slot happened to close
            // first, corrupting every subsequent slot in the block).
            for i in 0..<n {
                for ch in 0..<channelCount {
                    let weighted = filters[ch].process(Double(data[ch][i]))
                    currentSlotSumSq[ch] += weighted * weighted
                }
                samplesInCurrentSlot += 1
                if samplesInCurrentSlot >= slotSamples {
                    for c in 0..<channelCount { slotSumSq[c].append(currentSlotSumSq[c]) }
                    currentSlotSumSq = [Double](repeating: 0, count: channelCount)
                    samplesInCurrentSlot = 0
                }
            }
            if n < Int(blockSize) { break }
        }
        // Trailing partial slot (< 100ms of audio) is dropped, matching
        // common reference-implementation practice — negligible for any
        // file long enough to be worth measuring.

        let slotCount = slotSumSq.first?.count ?? 0
        guard slotCount > 0 else { throw MeterError.zeroLength }

        let momentarySeries = blockLoudnessSeries(slotSumSq: slotSumSq, slotSamples: slotSamples, windowSlots: momentarySlots)
        let shortTermSeries = blockLoudnessSeries(slotSumSq: slotSumSq, slotSamples: slotSamples, windowSlots: shortTermSlots)

        let momentaryMax = momentarySeries.map(\.loudnessLUFS).max() ?? -.infinity
        let shortTermMax = shortTermSeries.map(\.loudnessLUFS).max() ?? -.infinity

        let integrated = integratedLoudness(from: momentarySeries)
        let lra = loudnessRange(from: shortTermSeries)

        let truePeak = peakAccumulators.map(\.peakDBTP).max() ?? -160.0

        return Result(
            integratedLUFS: integrated,
            momentaryMaxLUFS: momentaryMax,
            shortTermMaxLUFS: shortTermMax,
            loudnessRangeLRA: lra,
            truePeakDBTP: truePeak
        )
    }

    // MARK: Block-loudness series

    private struct Block {
        let z: Double            // linear-domain weighted mean square, summed across channels (Gi = 1 for L/R/mono)
        let loudnessLUFS: Double // -0.691 + 10*log10(z)
    }

    /// Slides a `windowSlots`-wide window across the 100ms slots, one slot
    /// at a time (giving 400ms blocks 75% overlap, matching BS.1770's
    /// gating-block definition; 3s short-term blocks get the same
    /// one-slot-at-a-time slide by extension). Each block's z-value sums
    /// mean-square across channels with Gi = 1.0 for L/R/mono (Session
    /// Close never sees the surround channels BS.1770's other Gi weights
    /// exist for).
    private static func blockLoudnessSeries(slotSumSq: [[Double]], slotSamples: Int, windowSlots: Int) -> [Block] {
        let channelCount = slotSumSq.count
        let slotCount = slotSumSq.first?.count ?? 0
        guard slotCount >= windowSlots else { return [] }

        var blocks: [Block] = []
        blocks.reserveCapacity(slotCount - windowSlots + 1)
        let windowSamples = Double(windowSlots * slotSamples)

        for start in 0...(slotCount - windowSlots) {
            var z = 0.0
            for ch in 0..<channelCount {
                var sum = 0.0
                for s in start..<(start + windowSlots) { sum += slotSumSq[ch][s] }
                z += sum / windowSamples
            }
            let loudness = z > 0 ? -0.691 + 10 * log10(z) : -160.0
            blocks.append(Block(z: z, loudnessLUFS: loudness))
        }
        return blocks
    }

    /// BS.1770-4's two-stage gate: absolute gate at -70 LUFS, then a
    /// relative gate 10 LU below the mean of what passed the absolute gate
    /// — both computed and applied on the 400ms momentary block series.
    private static func integratedLoudness(from blocks: [Block]) -> Double {
        let absoluteGated = blocks.filter { $0.loudnessLUFS >= absoluteGateLUFS }
        guard !absoluteGated.isEmpty else { return -.infinity }

        let meanZAbsolute = absoluteGated.map(\.z).reduce(0, +) / Double(absoluteGated.count)
        let relativeThresholdLUFS = (-0.691 + 10 * log10(max(meanZAbsolute, 1e-15))) - integratedRelativeGateLU

        let relativeGated = absoluteGated.filter { $0.loudnessLUFS >= relativeThresholdLUFS }
        guard !relativeGated.isEmpty else { return -.infinity }

        let meanZFinal = relativeGated.map(\.z).reduce(0, +) / Double(relativeGated.count)
        return meanZFinal > 0 ? -0.691 + 10 * log10(meanZFinal) : -.infinity
    }

    /// EBU Tech 3342: absolute gate at -70 LUFS, relative gate 20 LU below
    /// the mean of what passed, then LRA = P95 - P10 of what's left.
    private static func loudnessRange(from blocks: [Block]) -> Double {
        let absoluteGated = blocks.filter { $0.loudnessLUFS >= absoluteGateLUFS }
        guard !absoluteGated.isEmpty else { return 0 }

        let meanZAbsolute = absoluteGated.map(\.z).reduce(0, +) / Double(absoluteGated.count)
        let relativeThresholdLUFS = (-0.691 + 10 * log10(max(meanZAbsolute, 1e-15))) - lraRelativeGateLU

        let relativeGated = absoluteGated.filter { $0.loudnessLUFS >= relativeThresholdLUFS }.map(\.loudnessLUFS).sorted()
        guard relativeGated.count > 1 else { return 0 }

        return percentile(relativeGated, 0.95) - percentile(relativeGated, 0.10)
    }

    /// Linear-interpolation percentile over an already-sorted array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = p * Double(sorted.count - 1)
        let lowerIndex = Int(position)
        let upperIndex = min(lowerIndex + 1, sorted.count - 1)
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }
}

// MARK: - K-weighting filter

/// The two-stage K-weighting filter BS.1770 measures loudness through: a
/// high-shelf "head effects" pre-filter, then an RLB high-pass weighting
/// filter. The spec publishes fixed z-domain coefficients at 48kHz;
/// generalizing to arbitrary sample rates (needed since scanned files are
/// often 44.1kHz) means re-deriving both stages from their analog-prototype
/// parameters via the standard RBJ Audio EQ Cookbook biquad formulas and a
/// fresh bilinear transform per sample rate — the widely-used approach for
/// building a BS.1770 meter that isn't hard-locked to one sample rate.
private struct KWeightingFilter {
    private var stage1: Biquad // high-shelf, head-effects pre-filter
    private var stage2: Biquad // high-pass, RLB weighting curve

    init(sampleRate: Double) {
        stage1 = Biquad.highShelf(f0: 1681.9744509555319, dBGain: 3.999843853973347, q: 0.7071752369554196, sampleRate: sampleRate)
        stage2 = Biquad.highPass(f0: 38.13547087602444, q: 0.5003270373238773, sampleRate: sampleRate)
    }

    mutating func process(_ x: Double) -> Double {
        stage2.process(stage1.process(x))
    }
}

/// Direct Form II Transposed biquad — one set of coefficients (a0 already
/// normalized to 1) plus two state variables carried across calls.
private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// RBJ cookbook high-shelf, coefficients normalized so a0 == 1.
    static func highShelf(f0: Double, dBGain: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, dBGain / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0), sinw0 = sin(w0)
        let alpha = sinw0 / (2 * q)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha

        let b0 = a * ((a + 1) + (a - 1) * cosw0 + twoSqrtAAlpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosw0)
        let b2 = a * ((a + 1) + (a - 1) * cosw0 - twoSqrtAAlpha)
        let a0 = (a + 1) - (a - 1) * cosw0 + twoSqrtAAlpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosw0)
        let a2 = (a + 1) - (a - 1) * cosw0 - twoSqrtAAlpha

        var f = Biquad()
        f.b0 = b0 / a0; f.b1 = b1 / a0; f.b2 = b2 / a0
        f.a1 = a1 / a0; f.a2 = a2 / a0
        return f
    }

    /// RBJ cookbook high-pass, coefficients normalized so a0 == 1.
    static func highPass(f0: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0), sinw0 = sin(w0)
        let alpha = sinw0 / (2 * q)

        let b0 = (1 + cosw0) / 2
        let b1 = -(1 + cosw0)
        let b2 = (1 + cosw0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw0
        let a2 = 1 - alpha

        var f = Biquad()
        f.b0 = b0 / a0; f.b1 = b1 / a0; f.b2 = b2 / a0
        f.a1 = a1 / a0; f.a2 = a2 / a0
        return f
    }
}
