import Foundation

enum FolderScanner {

    /// Extensions AVFoundation can generally decode. WAV/AIFF are the
    /// primary target; the rest are here so the app isn't locked out of
    /// other formats even though it won't be the common case.
    static let supportedExtensions: Set<String> = [
        "wav", "wave", "aiff", "aif", "aifc", "caf", "m4a", "mp3", "flac", "alac"
    ]

    /// Top-level only — matches Session Prep's non-recursive scope, kept
    /// consistent across the two apps. The main window's subfolder chips +
    /// Cmd+arrow navigation (see ContentView) are how you move deeper into
    /// an album's subfolders instead of scanning recursively.
    ///
    /// Per-file analysis (a full BS.1770 K-weighted pass plus an FFT
    /// spectrum pass over every sample of every file — see
    /// AudioFileAnalyzer/LoudnessMeter/SpectrumAnalyzer) is real CPU work,
    /// not a quick metadata read, so a several-minute album can take a
    /// noticeable amount of wall-clock time. Two things make that
    /// tolerable: files are analyzed concurrently across CPU cores
    /// (`DispatchQueue.concurrentPerform`) instead of one at a time, and
    /// `onProgress` reports completed/total as each file finishes so the
    /// caller can show real progress instead of an indeterminate spinner.
    /// `onProgress` fires on whichever background thread finished that
    /// file — callers must hop back to the main thread themselves before
    /// touching UI state.
    static func scan(folder: URL, onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> [AudioFileRecord] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let audioFiles = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !audioFiles.isEmpty else { return [] }

        // Preallocated, index-addressed slots rather than concurrent
        // appends — every iteration below only ever touches its own index,
        // and all writes still go through `lock` so there's no data race on
        // the array's shared storage.
        var results = [AudioFileRecord?](repeating: nil, count: audioFiles.count)
        let lock = NSLock()
        var completedCount = 0

        DispatchQueue.concurrentPerform(iterations: audioFiles.count) { index in
            let record = AudioFileAnalyzer.analyze(url: audioFiles[index])
            lock.lock()
            results[index] = record
            completedCount += 1
            let current = completedCount
            lock.unlock()
            onProgress?(current, audioFiles.count)
        }

        return results.compactMap { $0 }
    }

    /// Immediate child directories of `folder`, alphabetical, hidden ones
    /// excluded — feeds ContentView's subfolder chip bar. Not recursive,
    /// matching the audio scan's own non-recursive scope.
    static func listSubfolders(of folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
