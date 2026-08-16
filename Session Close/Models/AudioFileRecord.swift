import Foundation

/// One row in the batch table — a single file's file-level info, BS.1770
/// loudness measurements, True Peak, spectral QC data, and (once a target's
/// been confirmed) its proposed/applied gain.
struct AudioFileRecord: Identifiable {
    let id = UUID()

    var url: URL
    var filename: String
    var fileExtension: String

    var bitDepth: Int?
    var sampleRate: Double
    var duration: TimeInterval
    var fileSizeBytes: Int64
    var channelCount: Int

    var status: MeasurementStatus = .pending

    // MARK: BS.1770 / EBU R128 loudness (see Engine/LoudnessMeter.swift)

    /// Gated, whole-file — the target-setting metric.
    var integratedLUFS: Double?
    /// Highest 3s (ungated) window over the file — QC readout only, not a
    /// target. Per Session-Close-Concept.md "Decisions #3": max-value
    /// summary in the table, no per-file history graph in v1.
    var shortTermMaxLUFS: Double?
    /// Highest 400ms (ungated) window over the file — QC readout only, good
    /// for spotting one hot section.
    var momentaryMaxLUFS: Double?
    /// Loudness Range — dynamic spread across the file, from short-term
    /// percentiles. Bonus column, cheap once short-term is computed.
    var loudnessRangeLRA: Double?

    /// Oversampled True Peak, dBTP. Catches inter-sample peaks a
    /// sample-domain scan misses (see Engine/TruePeakMeter.swift).
    var truePeakDBTP: Double?

    // MARK: Spectral QC (see Engine/SpectrumAnalyzer.swift)

    /// Long-term average spectrum, banded to 1/3-octave, aligned index-for-
    /// index with SpectrumAnalyzer.bandCenterFrequenciesHz. Forward-FFT-only,
    /// display/QC purposes — never used to actually alter a file's tone.
    var spectrumBandsDB: [Double]?

    // MARK: Target / leveling (see Engine/LevelingEngine.swift)

    /// The "Target" marker — repurposed from Session Prep's True Stereo/
    /// Mono tag column (see Session-Close-Concept.md "Reused from Session
    /// Prep"). Only meaningful when TargetMode == .referenceTrack; at most
    /// one record should have this set true at a time (ContentView enforces
    /// that when the user clicks a row to flag it).
    var isReferenceTrack: Bool = false

    /// gain_dB = target_LUFS - measured_LUFS, computed once a target's
    /// proposed/confirmed. Nil until a target exists.
    var suggestedGainDB: Double?
    /// What integratedLUFS/truePeakDBTP would become after suggestedGainDB
    /// is applied — a flat gain moves both by the same dB amount.
    var projectedLUFS: Double?
    var projectedTruePeakDBTP: Double?

    // Populated after Process Selected actually writes a leveled file.
    var writtenURL: URL?

    // MARK: Sort keys
    //
    // Table column sorting needs a plain Comparable KeyPath per sortable
    // column; Optional<Double> isn't Comparable, so these give each
    // measurement a non-optional stand-in. Missing values sort to the
    // bottom, matching Session Prep's same convention.

    var bitDepthSortValue: Int { bitDepth ?? -1 }
    var integratedLUFSSortValue: Double { integratedLUFS ?? -.infinity }
    var truePeakSortValue: Double { truePeakDBTP ?? -.infinity }
    var suggestedGainSortValue: Double { suggestedGainDB ?? -.infinity }
    var shortTermMaxSortValue: Double { shortTermMaxLUFS ?? -.infinity }
    var momentaryMaxSortValue: Double { momentaryMaxLUFS ?? -.infinity }
    var lraSortValue: Double { loudnessRangeLRA ?? -.infinity }
}
