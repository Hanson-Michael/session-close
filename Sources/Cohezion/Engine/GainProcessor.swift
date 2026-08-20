import Foundation
import AVFoundation

enum ProcessingError: Error, LocalizedError {
    case couldNotCreateOutputFolders
    /// macOS's Files-and-Folders privacy protection (TCC), not App Sandbox —
    /// applies to Desktop/Documents/Downloads for any app, sandboxed or not.
    /// Distinct from `.couldNotCreateOutputFolders` because the fix is a
    /// System Settings toggle, not a code/disk problem, so it gets its own
    /// message rather than a generic one that would leave someone stuck.
    case desktopAccessDenied
    case couldNotReadSource(String)
    case couldNotWriteOutput(String)
    case couldNotMoveOriginal(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateOutputFolders: return "Could not create the output folders."
        case .desktopAccessDenied:
            return "Cohezion doesn't have permission to write to your Desktop folder. Open System Settings ▸ Privacy & Security ▸ Files and Folders, find Cohezion, and turn on Desktop Folder — then try again. If Cohezion isn't listed there yet, run Process Selected once more; macOS adds an app to that list only after it's actually tried and been denied. Still not listed, or the toggle's already on but this keeps happening? Quit Cohezion, open Terminal, run: tccutil reset SystemPolicyDesktopFolder — then relaunch and try again; that clears the stuck permission and macOS will ask fresh."
        case .couldNotReadSource(let msg): return "Could not read the source file: \(msg)"
        case .couldNotWriteOutput(let msg): return "Could not write the leveled file: \(msg)"
        case .couldNotMoveOriginal(let msg): return "Could not move the original file: \(msg)"
        }
    }
}

struct ProcessingResult {
    let originalMovedTo: URL
    let leveledFileAt: URL
}

/// Applies a record's confirmed suggestedGainDB and writes a new WAV file —
/// gain-only (no limiting/compression, see Session-Close-Concept.md
/// "Leveling logic"), channel layout and count always unchanged, existing
/// BEXT/broadcast metadata retained (never fabricated) via
/// BroadcastMetadata.swift. Output format is always WAV regardless of the
/// source container, same policy as Session Prep.
enum GainProcessor {

    /// A no-op gain (file's already exactly at the target within floating
    /// point noise) writes nothing and moves nothing — matches Session
    /// Prep's own convention of never producing a byte-for-byte duplicate
    /// for a file that didn't need touching.
    private static let noOpGainEpsilonDB = 0.01

    /// `sourceFolder` used to be a separate parameter, one shared value for
    /// the whole batch. Since Main window backlog item 9 (Add Files),
    /// records can come from scattered locations with no single folder in
    /// common, so it's derived here instead, per record, from
    /// `record.url`'s own parent directory — used for the
    /// `.defaultSubfolder`/`.sourceFolder`/`.moveToSubfolder` options below,
    /// each of which places output next to *that file*, not one batch-wide
    /// location.
    static func process(record: AudioFileRecord, options: ProcessOptions) throws -> ProcessingResult? {
        guard let gainDB = record.suggestedGainDB, abs(gainDB) >= noOpGainEpsilonDB else { return nil }

        guard let sourceFile = try? AVAudioFile(forReading: record.url) else {
            throw ProcessingError.couldNotReadSource(record.filename)
        }

        let sourceFolder = record.url.deletingLastPathComponent()
        let folders = try resolveFolders(sourceFolder: sourceFolder, options: options)
        let baseName = (record.filename as NSString).deletingPathExtension
        let suffix = options.suffixesEnabled ? "_leveled" : ""
        let (outSettings, outExtension) = resolvedOutputSettings(sourceFile: sourceFile)
        let leveledURL = uniqueURL(in: folders.output, baseName: "\(baseName)\(suffix)", ext: outExtension)

        let gainLinear = Float(pow(10.0, gainDB / 20.0))
        do {
            try writeGainAdjustedFile(from: sourceFile, gain: gainLinear, to: leveledURL, outputSettings: outSettings)
        } catch {
            throw ProcessingError.couldNotWriteOutput(error.localizedDescription)
        }
        preserveBroadcastMetadata(from: record.url, into: leveledURL)

        let movedOriginalURL = try moveOriginalIfNeeded(record: record, baseName: baseName, to: folders.original)
        return ProcessingResult(originalMovedTo: movedOriginalURL, leveledFileAt: leveledURL)
    }

    private static func preserveBroadcastMetadata(from source: URL, into destination: URL) {
        var chunks = BroadcastMetadata.extractChunks(from: source)
        if chunks.isEmpty, let id3Chunk = BroadcastMetadata.extractID3TagAsWavChunk(from: source) {
            chunks = [id3Chunk]
        }
        BroadcastMetadata.injectChunks(chunks, into: destination)
    }

    /// Every channel written back out unchanged in layout — never a
    /// channel-count or L/R-balance change, just a uniform gain.
    private static func writeGainAdjustedFile(from sourceFile: AVAudioFile, gain: Float, to destination: URL, outputSettings: [String: Any]) throws {
        let sourceFormat = sourceFile.processingFormat
        let channelCount = Int(sourceFormat.channelCount)
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: sourceFormat.commonFormat,
            interleaved: false
        )

        let blockSize: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: blockSize) else {
            throw ProcessingError.couldNotWriteOutput("Could not allocate buffer")
        }

        sourceFile.framePosition = 0
        while true {
            try sourceFile.read(into: buffer, frameCount: blockSize)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for ch in 0..<channelCount {
                let channelData = data[ch]
                for i in 0..<n { channelData[i] *= gain }
            }
            try outputFile.write(from: buffer)
            if n < Int(blockSize) { break }
        }
    }

    /// Always WAV — the app exists to hand off a finished, leveled batch,
    /// so one consistent BWF-capable delivery format beats "whatever
    /// container happened to show up," same policy as Session Prep.
    private static func resolvedOutputSettings(sourceFile: AVAudioFile) -> (settings: [String: Any], extension: String) {
        var settings = sourceFile.fileFormat.settings
        let formatID = settings[AVFormatIDKey] as? UInt32
        let isWritablePCM = formatID == kAudioFormatLinearPCM

        if isWritablePCM {
            // WAV is always little-endian; an AIFF source's own format
            // settings carry AVLinearPCMIsBigEndianKey: true — forcing the
            // container to WAV without also forcing this false would
            // silently byte-swap an AIFF source's samples into noise.
            settings[AVLinearPCMIsBigEndianKey] = false
            return (settings, "wav")
        } else {
            let fallback: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFile.fileFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFile.processingFormat.channelCount,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            return (fallback, "wav")
        }
    }

    /// Resolves where originals and leveled files actually go, based on the
    /// pre-flight review sheet's choices — same shape as Session Prep's
    /// MonoConverter.resolveFolders.
    private static func resolveFolders(sourceFolder: URL, options: ProcessOptions) throws -> (original: URL?, output: URL) {
        let fm = FileManager.default

        let outputFolder: URL
        switch options.outputLocation {
        case .defaultSubfolder:
            outputFolder = sourceFolder.appendingPathComponent("Processed - Leveled", isDirectory: true)
        case .sourceFolder:
            outputFolder = sourceFolder
        case .customFolder:
            guard let custom = options.customOutputFolder else { throw ProcessingError.couldNotCreateOutputFolders }
            outputFolder = custom
        case .desktop:
            outputFolder = AppSettings.Defaults.defaultProcessedFolder
        }
        do {
            try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            throw (options.outputLocation == .desktop && isPermissionDenied(error))
                ? ProcessingError.desktopAccessDenied : ProcessingError.couldNotCreateOutputFolders
        }

        let originalFolder: URL?
        switch options.originalHandling {
        case .moveToSubfolder:
            let folder = sourceFolder.appendingPathComponent("Source - Unleveled", isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw ProcessingError.couldNotCreateOutputFolders
            }
            originalFolder = folder
        case .leaveInPlace:
            originalFolder = nil
        case .customFolder:
            guard let custom = options.customOriginalsFolder else { throw ProcessingError.couldNotCreateOutputFolders }
            do {
                try fm.createDirectory(at: custom, withIntermediateDirectories: true)
            } catch {
                throw ProcessingError.couldNotCreateOutputFolders
            }
            originalFolder = custom
        case .desktop:
            let folder = AppSettings.Defaults.defaultOriginalsFolder
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw isPermissionDenied(error) ? ProcessingError.desktopAccessDenied : ProcessingError.couldNotCreateOutputFolders
            }
            originalFolder = folder
        }

        return (originalFolder, outputFolder)
    }

    /// TCC (Files and Folders privacy protection) denials show up wrapped
    /// differently depending on which layer surfaces them — Cocoa's own
    /// "no permission" codes, or a raw POSIX EPERM/EACCES underneath —
    /// so both are checked rather than assuming one specific shape.
    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        return false
    }

    private static func moveOriginalIfNeeded(record: AudioFileRecord, baseName: String, to originalFolder: URL?) throws -> URL {
        guard let originalFolder else { return record.url }
        let originalExt = record.fileExtension.isEmpty ? "wav" : record.fileExtension
        let movedURL = uniqueURL(in: originalFolder, baseName: baseName, ext: originalExt)
        do {
            try FileManager.default.moveItem(at: record.url, to: movedURL)
        } catch {
            throw ProcessingError.couldNotMoveOriginal(error.localizedDescription)
        }
        return movedURL
    }

    private static func uniqueURL(in folder: URL, baseName: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
