import CryptoKit
import Foundation

struct VoxtralMarkerRuntimeIdentity: Codable, Equatable, Sendable {
    let runtimePatchSHA256: String
    let modelID: String
    let modelRevision: String
    let transcriptionDelayMilliseconds: Int

    static let current = Self(
        runtimePatchSHA256: VoxtralHelperManifest.runtimePatchSHA256,
        modelID: VoxtralHelperManifest.modelID,
        modelRevision: VoxtralHelperManifest.modelRevision,
        transcriptionDelayMilliseconds: VoxtralHelperManifest.runtimeTranscriptionDelayMilliseconds
    )
}

struct VoxtralMarkerEndAnnotation: Codable, Equatable, Sendable {
    let id: String
    /// The current marker supplies the acoustic end proxy.
    let markerGeneratedIndex: Int
    /// The following marker supplies the UTF-8 cut after the current group.
    let nextMarkerGeneratedIndex: Int
    let nextGroupTextStartUTF8: Int
    /// Human-audited end of the same lexical group in the raw transcript.
    let expectedTextEndUTF8: Int
    let proxyEndSample: Int
    let trueEndSample: Int
}

/// Human-reviewed evidence. Calibration and validation IDs must be disjoint;
/// production must additionally pin the SHA-256 of the complete encoded file.
struct VoxtralMarkerCalibrationProofDataset: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let corpusID: String
    let runtimeIdentity: VoxtralMarkerRuntimeIdentity
    let baselineTranscript: String
    let instrumentedTranscript: String
    let calibration: [VoxtralMarkerEndAnnotation]
    let validation: [VoxtralMarkerEndAnnotation]
}

struct VoxtralMarkerCalibrationProofResult: Codable, Equatable, Sendable {
    static let minimumAnnotationsPerSplit = 20
    static let maximumValidationP95Samples =
        VoxtralMarkerCalibration.maximumP95ErrorSamples
    static let maximumMedianDriftSamples = 1_280 // 80 ms at 16 kHz

    let schemaVersion: Int
    let corpusID: String
    let datasetSHA256: String
    let runtimeIdentity: VoxtralMarkerRuntimeIdentity
    let calibrationCount: Int
    let validationCount: Int
    let verifiedTextBoundaryCount: Int
    let biasSamples: Int
    let calibrationP95AbsoluteErrorSamples: Int
    let validationP95AbsoluteErrorSamples: Int
    let medianOffsetDriftSamples: Int
    let transcriptSHA256: String
    let transcriptIdentical: Bool
    let violations: [String]
    let permitsBoundaries: Bool

    var calibration: VoxtralMarkerCalibration? {
        permitsBoundaries
            ? VoxtralMarkerCalibration(
                biasSamples: biasSamples,
                p95AbsoluteErrorSamples: validationP95AbsoluteErrorSamples
            )
            : nil
    }
}

enum VoxtralMarkerCalibrationProof {
    static func approvedCalibration(
        data: Data,
        approvedDatasetSHA256: String
    ) throws -> VoxtralMarkerCalibration? {
        try evaluate(
            data: data,
            expectedDatasetSHA256: approvedDatasetSHA256
        ).calibration
    }

    static func evaluate(
        data: Data,
        expectedDatasetSHA256: String? = nil
    ) throws -> VoxtralMarkerCalibrationProofResult {
        let dataset = try JSONDecoder().decode(
            VoxtralMarkerCalibrationProofDataset.self,
            from: data
        )
        return evaluate(
            dataset,
            datasetSHA256: sha256(data),
            expectedDatasetSHA256: expectedDatasetSHA256
        )
    }

    static func evaluate(
        _ dataset: VoxtralMarkerCalibrationProofDataset,
        datasetSHA256: String = "in-memory",
        expectedDatasetSHA256: String? = nil
    ) -> VoxtralMarkerCalibrationProofResult {
        var violations: [String] = []
        if dataset.schemaVersion != 1 { violations.append("unsupportedSchema") }
        if dataset.corpusID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append("missingCorpusID")
        }
        if dataset.runtimeIdentity != .current { violations.append("runtimeIdentityMismatch") }
        if dataset.runtimeIdentity.transcriptionDelayMilliseconds != 960 {
            violations.append("unsupportedTranscriptionDelay")
        }
        if let expectedDatasetSHA256,
           datasetSHA256.lowercased() != expectedDatasetSHA256.lowercased() {
            violations.append("datasetSHA256Mismatch")
        }
        if dataset.calibration.count < VoxtralMarkerCalibrationProofResult.minimumAnnotationsPerSplit {
            violations.append("insufficientCalibrationAnnotations")
        }
        if dataset.validation.count < VoxtralMarkerCalibrationProofResult.minimumAnnotationsPerSplit {
            violations.append("insufficientValidationAnnotations")
        }

        let calibrationIDs = dataset.calibration.map(\.id)
        let validationIDs = dataset.validation.map(\.id)
        if Set(calibrationIDs).count != calibrationIDs.count
            || Set(validationIDs).count != validationIDs.count {
            violations.append("duplicateAnnotationID")
        }
        if !Set(calibrationIDs).isDisjoint(with: validationIDs) {
            violations.append("nonIndependentAnnotationSplits")
        }
        let calibrationMarkerIDs = dataset.calibration.map(\.markerGeneratedIndex)
        let validationMarkerIDs = dataset.validation.map(\.markerGeneratedIndex)
        if Set(calibrationMarkerIDs).count != calibrationMarkerIDs.count
            || Set(validationMarkerIDs).count != validationMarkerIDs.count {
            violations.append("duplicateMarkerID")
        }
        if !Set(calibrationMarkerIDs).isDisjoint(with: validationMarkerIDs) {
            violations.append("nonIndependentMarkers")
        }
        let calibrationProxies = dataset.calibration.map(\.proxyEndSample)
        let validationProxies = dataset.validation.map(\.proxyEndSample)
        if Set(calibrationProxies).count != calibrationProxies.count
            || Set(validationProxies).count != validationProxies.count {
            violations.append("duplicateProxySample")
        }
        if !Set(calibrationProxies).isDisjoint(with: validationProxies) {
            violations.append("nonIndependentProxySamples")
        }
        let calibrationTrueEnds = dataset.calibration.map(\.trueEndSample)
        let validationTrueEnds = dataset.validation.map(\.trueEndSample)
        if Set(calibrationTrueEnds).count != calibrationTrueEnds.count
            || Set(validationTrueEnds).count != validationTrueEnds.count {
            violations.append("duplicateAnnotationSample")
        }
        if !Set(calibrationTrueEnds).isDisjoint(with: validationTrueEnds) {
            violations.append("nonIndependentAnnotationSamples")
        }
        if (dataset.calibration + dataset.validation).contains(where: {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.markerGeneratedIndex < 0
                || $0.nextMarkerGeneratedIndex <= $0.markerGeneratedIndex
                || $0.nextGroupTextStartUTF8 < 0
                || $0.expectedTextEndUTF8 < 0
                || $0.proxyEndSample < 0
                || $0.trueEndSample < 0
        }) {
            violations.append("invalidAnnotation")
        }
        if (dataset.calibration + dataset.validation).contains(where: {
            $0.nextGroupTextStartUTF8 != $0.expectedTextEndUTF8
        }) {
            violations.append("textBoundaryMismatch")
        }

        let calibrationOffsets = dataset.calibration.map { $0.trueEndSample - $0.proxyEndSample }
        let validationOffsets = dataset.validation.map { $0.trueEndSample - $0.proxyEndSample }
        let rawBias = median(calibrationOffsets) ?? 0
        let bias = Int((Double(rawBias) / Double(VoxtralMarkerCalibration.frameSamples)).rounded())
            * VoxtralMarkerCalibration.frameSamples
        let calibrationP95 = p95(dataset.calibration.map {
            abs($0.proxyEndSample + bias - $0.trueEndSample)
        }) ?? .max
        let validationP95 = p95(dataset.validation.map {
            abs($0.proxyEndSample + bias - $0.trueEndSample)
        }) ?? .max
        let medianDrift = abs((median(calibrationOffsets) ?? 0) - (median(validationOffsets) ?? 0))

        if validationP95 > VoxtralMarkerCalibrationProofResult.maximumValidationP95Samples {
            violations.append("validationP95Exceeded")
        }
        if medianDrift > VoxtralMarkerCalibrationProofResult.maximumMedianDriftSamples {
            violations.append("medianDriftExceeded")
        }

        let transcriptIdentical = dataset.baselineTranscript == dataset.instrumentedTranscript
        if !transcriptIdentical { violations.append("transcriptMismatch") }
        if dataset.baselineTranscript.isEmpty { violations.append("emptyTranscript") }

        let uniqueViolations = Array(Set(violations)).sorted()
        return VoxtralMarkerCalibrationProofResult(
            schemaVersion: dataset.schemaVersion,
            corpusID: dataset.corpusID,
            datasetSHA256: datasetSHA256,
            runtimeIdentity: dataset.runtimeIdentity,
            calibrationCount: dataset.calibration.count,
            validationCount: dataset.validation.count,
            verifiedTextBoundaryCount: (dataset.calibration + dataset.validation).filter {
                $0.nextGroupTextStartUTF8 == $0.expectedTextEndUTF8
            }.count,
            biasSamples: bias,
            calibrationP95AbsoluteErrorSamples: calibrationP95,
            validationP95AbsoluteErrorSamples: validationP95,
            medianOffsetDriftSamples: medianDrift,
            transcriptSHA256: sha256(Data(dataset.baselineTranscript.utf8)),
            transcriptIdentical: transcriptIdentical,
            violations: uniqueViolations,
            permitsBoundaries: uniqueViolations.isEmpty
        )
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Int((Int64(sorted[middle - 1]) + Int64(sorted[middle])) / 2)
            : sorted[middle]
    }

    private static func p95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
