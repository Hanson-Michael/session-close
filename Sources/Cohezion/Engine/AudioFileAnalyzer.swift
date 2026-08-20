import Foundation
import AVFoundation

/// Per-file entry point for a folder scan: reads format metadata, then runs
/// the full BS.1770 loudness + True Peak pass (see LoudnessMeter.swift).
/// Unlike Session Prep's analyzer, there's no classification step — every
/// readable file gets measured the same way; only multichannel (>2) or
/// unreadable files are set aside.
enum AudioFileAnalyzer {

    static func analyze(url: URL) -> AudioFileRecord {
        let filename = url.lastPathComponent
        let ext = url.pathExtension

        guard let file = try? AVAudioFile(forReading: url) else {
            var record = AudioFileRecord(
                url: url, filename: filename, fileExtension: ext,
                bitDepth: nil, sampleRate: 0, duration: 0,
                fileSizeBytes: fileSize(url), channelCount: 0
            )
            record.status = .error("Could not open file")
            return record
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let bitDepth = bitDepthFromSettings(file: file) ?? bitsPerSample(format: format)

        var record = AudioFileRecord(
            url: url, filename: filename, fileExtension: ext,
            bitDepth: bitDepth, sampleRate: sampleRate, duration: duration,
            fileSizeBytes: fileSize(url), channelCount: channelCount
        )

        guard channelCount >= 1 else {
            record.status = .error("No channels")
            return record
        }
        guard channelCount <= 2 else {
            // Multichannel (5.1, etc.) is outside v1 scope, same as Session Prep.
            record.status = .error("\(channelCount)-channel file, not stereo/mono")
            return record
        }

        do {
            let result = try LoudnessMeter.measure(file: file)
            record.integratedLUFS = result.integratedLUFS
            record.momentaryMaxLUFS = result.momentaryMaxLUFS
            record.shortTermMaxLUFS = result.shortTermMaxLUFS
            record.loudnessRangeLRA = result.loudnessRangeLRA
            record.truePeakDBTP = result.truePeakDBTP

            file.framePosition = 0
            record.spectrumBandsDB = try? SpectrumAnalyzer.analyze(file: file)

            record.status = .measured
        } catch {
            record.status = .error("Could not read audio data")
        }

        return record
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }

    private static func bitsPerSample(format: AVAudioFormat) -> Int? {
        let asbd = format.streamDescription.pointee
        return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
    }

    /// AVAudioFile.processingFormat is often converted to Float32 for
    /// decoding, which loses the file's real on-disk bit depth — read it
    /// from the file's own format settings instead.
    private static func bitDepthFromSettings(file: AVAudioFile) -> Int? {
        file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int
    }
}
