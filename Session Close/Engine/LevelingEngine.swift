import Foundation

/// Proposes a batch target Integrated LUFS and every file's suggested gain
/// — the "measure, propose, confirm" step (see Session-Close-Concept.md
/// "Leveling logic"). Never applies anything itself; ContentView shows the
/// result and lets the user edit/confirm before GainProcessor writes files.
enum LevelingEngine {

    struct Proposal {
        /// The target actually used for gain math — equal to the requested
        /// `targetLUFS` unless .lowerBatchTarget pulled it down to fit
        /// every file under the TP ceiling.
        var effectiveTargetLUFS: Double
        /// Which record's True Peak headroom forced the batch target down,
        /// only set (and only meaningful) in .lowerBatchTarget mode.
        var forcingRecordID: AudioFileRecord.ID?
    }

    /// What a fresh target proposal should be for the given mode — used to
    /// seed/refresh the editable target field on scan, on a target-mode
    /// switch, or when the flagged reference track changes. Once seeded,
    /// the field is freely user-editable (see Session-Close-Concept.md
    /// "Leveling logic" step 4: "User can edit/confirm the proposed target
    /// before anything is applied") — further edits don't re-derive from
    /// the mode until one of those trigger events happens again.
    static func proposedTargetLUFS(records: [AudioFileRecord], mode: TargetMode, settings: AppSettings) -> Double? {
        let measuredLUFS = records.compactMap { $0.status.isMeasured ? $0.integratedLUFS : nil }
        guard !measuredLUFS.isEmpty else { return nil }

        switch mode {
        case .referenceTrack:
            return records.first(where: { $0.isReferenceTrack })?.integratedLUFS
        case .batchAverage:
            // REVISIT (flagged 2026-08-15, deliberately left as-is for
            // now): a plain arithmetic mean of each file's Integrated LUFS
            // number. Two things this does *not* do, either of which could
            // change what "the album's average loudness" means here:
            //   - Duration weighting — a 30s interlude counts exactly as
            //     much as an 8-minute track.
            //   - Power/energy-domain averaging — LUFS is a logarithmic
            //     unit, so averaging the dB-like numbers directly isn't the
            //     same as converting each to linear loudness power,
            //     averaging *that*, and converting back; the latter skews
            //     slightly toward the louder tracks and is arguably the
            //     more "correct" way to average a log unit. Simple mean was
            //     kept as the v1 default since it's what most loudness-
            //     matching tools do informally and is the more intuitive
            //     number to look at — worth a real discussion before
            //     changing it, not a silent swap.
            return measuredLUFS.reduce(0, +) / Double(measuredLUFS.count)
        case .loudestFile:
            return measuredLUFS.max()
        case .fixedStandard:
            return settings.fixedStandardLUFS
        }
    }

    /// Computes and writes suggestedGainDB / projectedLUFS /
    /// projectedTruePeakDBTP / status onto every measured record in place,
    /// against an explicit target (see `proposedTargetLUFS` for how
    /// ContentView seeds/refreshes that number). **Never clip, TP always
    /// wins** — a flat gain change moves LUFS and True Peak by the same
    /// number of dB, so the maximum gain any file can take before hitting
    /// the TP ceiling is exactly `ceiling - measuredTP`, in either
    /// direction (see Session-Close-Concept.md "Leveling logic" step 6).
    @discardableResult
    static func apply(to records: inout [AudioFileRecord], targetLUFS initialTarget: Double, settings: AppSettings) -> Proposal {
        let ceiling = settings.truePeakCeilingDBTP
        let measuredIndices = records.indices.filter { $0.isMeasuredIndex(in: records) }

        switch settings.tpConstraintHandling {
        case .flagAndLeaveShort:
            for i in measuredIndices {
                guard let lufs = records[i].integratedLUFS, let tp = records[i].truePeakDBTP else { continue }
                let desired = initialTarget - lufs
                let maxAllowed = ceiling - tp
                let applied = min(desired, maxAllowed)
                records[i].suggestedGainDB = applied
                records[i].projectedLUFS = lufs + applied
                records[i].projectedTruePeakDBTP = tp + applied
                records[i].status = applied < desired - 0.001 ? .tpConstrained : .measured
            }
            return Proposal(effectiveTargetLUFS: initialTarget, forcingRecordID: nil)

        case .lowerBatchTarget:
            // The most any record's target could be without exceeding the
            // TP ceiling is its own measured LUFS plus its own headroom —
            // the batch target can never exceed the smallest of those
            // without forcing at least one file over the ceiling.
            var effectiveTarget = initialTarget
            var forcingID: AudioFileRecord.ID?
            for i in measuredIndices {
                guard let lufs = records[i].integratedLUFS, let tp = records[i].truePeakDBTP else { continue }
                let maxTargetForThisFile = lufs + (ceiling - tp)
                if maxTargetForThisFile < effectiveTarget {
                    effectiveTarget = maxTargetForThisFile
                    forcingID = records[i].id
                }
            }
            for i in measuredIndices {
                guard let lufs = records[i].integratedLUFS, let tp = records[i].truePeakDBTP else { continue }
                let applied = effectiveTarget - lufs
                records[i].suggestedGainDB = applied
                records[i].projectedLUFS = lufs + applied
                records[i].projectedTruePeakDBTP = tp + applied
                records[i].status = .measured // nothing's short of the (now-lowered) target in this mode
            }
            return Proposal(effectiveTargetLUFS: effectiveTarget, forcingRecordID: forcingID)
        }
    }
}

private extension Int {
    func isMeasuredIndex(in records: [AudioFileRecord]) -> Bool {
        records[self].status.isMeasured
    }
}
