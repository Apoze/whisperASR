import Foundation
import XCTest
@testable import WhisperASRApp

final class VoxtralMarkerCalibrationProofTests: XCTestCase {
    func testIndependentCalibrationAndValidationPass() {
        let result = VoxtralMarkerCalibrationProof.evaluate(dataset())

        XCTAssertTrue(result.permitsBoundaries)
        XCTAssertEqual(result.biasSamples, 1_280)
        XCTAssertEqual(result.validationP95AbsoluteErrorSamples, 0)
        XCTAssertEqual(result.medianOffsetDriftSamples, 0)
        XCTAssertEqual(result.verifiedTextBoundaryCount, 40)
        XCTAssertTrue(result.transcriptIdentical)
        XCTAssertNotNil(result.calibration)
    }

    func testValidationRatherThanCalibrationOwnsAccuracyGate() {
        var validation = annotations(prefix: "validation", offset: 1_280, startIndex: 20)
        validation[18] = annotation(id: "validation-18", offset: 5_200)
        validation[19] = annotation(id: "validation-19", offset: 5_200)

        let result = VoxtralMarkerCalibrationProof.evaluate(dataset(validation: validation))

        XCTAssertEqual(result.biasSamples, 1_280)
        XCTAssertGreaterThan(
            result.validationP95AbsoluteErrorSamples,
            VoxtralMarkerCalibrationProofResult.maximumValidationP95Samples
        )
        XCTAssertTrue(result.violations.contains("validationP95Exceeded"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testMedianDriftAndTranscriptIdentityAreIndependentGates() {
        let result = VoxtralMarkerCalibrationProof.evaluate(dataset(
            instrumentedTranscript: "違う",
            validation: annotations(prefix: "validation", offset: 2_640, startIndex: 20)
        ))

        XCTAssertTrue(result.violations.contains("medianDriftExceeded"))
        XCTAssertTrue(result.violations.contains("transcriptMismatch"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testSplitsRequireTwentyUniqueDisjointHumanAnnotationIDs() {
        var validation = Array(annotations(
            prefix: "validation",
            offset: 1_280,
            startIndex: 20
        ).prefix(19))
        validation[0] = annotation(id: "calibration-0", offset: 1_280)
        let result = VoxtralMarkerCalibrationProof.evaluate(dataset(validation: validation))

        XCTAssertTrue(result.violations.contains("insufficientValidationAnnotations"))
        XCTAssertTrue(result.violations.contains("nonIndependentAnnotationSplits"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testFollowingMarkerMustMatchTheHumanAuditedUTF8Boundary() {
        var validation = annotations(prefix: "validation", offset: 1_280, startIndex: 20)
        let original = validation[0]
        validation[0] = VoxtralMarkerEndAnnotation(
            id: original.id,
            markerGeneratedIndex: original.markerGeneratedIndex,
            nextMarkerGeneratedIndex: original.nextMarkerGeneratedIndex,
            nextGroupTextStartUTF8: original.nextGroupTextStartUTF8,
            expectedTextEndUTF8: original.expectedTextEndUTF8 + 3,
            proxyEndSample: original.proxyEndSample,
            trueEndSample: original.trueEndSample
        )

        let result = VoxtralMarkerCalibrationProof.evaluate(dataset(validation: validation))

        XCTAssertTrue(result.violations.contains("textBoundaryMismatch"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testSplitsCannotReuseTheSameMarkerOrProxy() {
        var validation = annotations(prefix: "validation", offset: 1_280, startIndex: 20)
        let calibration = annotations(prefix: "calibration", offset: 1_280)
        let reused = calibration[0]
        let original = validation[0]
        validation[0] = VoxtralMarkerEndAnnotation(
            id: original.id,
            markerGeneratedIndex: reused.markerGeneratedIndex,
            nextMarkerGeneratedIndex: reused.nextMarkerGeneratedIndex,
            nextGroupTextStartUTF8: original.nextGroupTextStartUTF8,
            expectedTextEndUTF8: original.expectedTextEndUTF8,
            proxyEndSample: reused.proxyEndSample,
            trueEndSample: original.trueEndSample
        )

        let result = VoxtralMarkerCalibrationProof.evaluate(dataset(
            calibration: calibration,
            validation: validation
        ))

        XCTAssertTrue(result.violations.contains("nonIndependentMarkers"))
        XCTAssertTrue(result.violations.contains("nonIndependentProxySamples"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testRuntimeAndApprovedDatasetDigestArePinned() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dataset(runtimeIdentity: VoxtralMarkerRuntimeIdentity(
            runtimePatchSHA256: "old-runtime",
            modelID: VoxtralHelperManifest.modelID,
            modelRevision: VoxtralHelperManifest.modelRevision,
            transcriptionDelayMilliseconds: 960
        )))
        let result = try VoxtralMarkerCalibrationProof.evaluate(
            data: data,
            expectedDatasetSHA256: String(repeating: "0", count: 64)
        )

        XCTAssertTrue(result.violations.contains("runtimeIdentityMismatch"))
        XCTAssertTrue(result.violations.contains("datasetSHA256Mismatch"))
        XCTAssertFalse(result.permitsBoundaries)
    }

    func testApprovedCalibrationRequiresTheExactDatasetDigest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dataset())
        let evaluated = try VoxtralMarkerCalibrationProof.evaluate(data: data)

        XCTAssertNotNil(try VoxtralMarkerCalibrationProof.approvedCalibration(
            data: data,
            approvedDatasetSHA256: evaluated.datasetSHA256
        ))
        XCTAssertNil(try VoxtralMarkerCalibrationProof.approvedCalibration(
            data: data,
            approvedDatasetSHA256: String(repeating: "0", count: 64)
        ))
    }

    private func dataset(
        instrumentedTranscript: String = "同じ日本語。",
        calibration: [VoxtralMarkerEndAnnotation]? = nil,
        validation: [VoxtralMarkerEndAnnotation]? = nil,
        runtimeIdentity: VoxtralMarkerRuntimeIdentity = .current
    ) -> VoxtralMarkerCalibrationProofDataset {
        VoxtralMarkerCalibrationProofDataset(
            schemaVersion: 1,
            corpusID: "deterministic-test",
            runtimeIdentity: runtimeIdentity,
            baselineTranscript: "同じ日本語。",
            instrumentedTranscript: instrumentedTranscript,
            calibration: calibration ?? annotations(prefix: "calibration", offset: 1_280),
            validation: validation ?? annotations(
                prefix: "validation",
                offset: 1_280,
                startIndex: 20
            )
        )
    }

    private func annotations(
        prefix: String,
        offset: Int,
        startIndex: Int = 0
    ) -> [VoxtralMarkerEndAnnotation] {
        (0..<20).map {
            annotation(id: "\(prefix)-\($0)", offset: offset, index: startIndex + $0)
        }
    }

    private func annotation(
        id: String,
        offset: Int,
        index: Int = 0
    ) -> VoxtralMarkerEndAnnotation {
        let proxy = 16_000 + index * 8_000
        let expectedTextEnd = (index + 1) * 12
        return VoxtralMarkerEndAnnotation(
            id: id,
            markerGeneratedIndex: index * 10,
            nextMarkerGeneratedIndex: index * 10 + 5,
            nextGroupTextStartUTF8: expectedTextEnd,
            expectedTextEndUTF8: expectedTextEnd,
            proxyEndSample: proxy,
            trueEndSample: proxy + offset
        )
    }
}
