import CryptoKit
import Foundation
import XCTest
@testable import WhisperASRApp

final class VoxtralHelperRuntimeTests: XCTestCase {
    func testRealModelImmediatePublicationParityWhenOptedIn() throws {
        guard let wavPath = ProcessInfo.processInfo.environment[
            "WHISPERASR_VOXTRAL_PUBLICATION_PARITY_WAV"
        ] else {
            throw XCTSkip(
                "Set WHISPERASR_VOXTRAL_PUBLICATION_PARITY_WAV to the canonical 40-second WAV."
            )
        }

        let wavURL = URL(fileURLWithPath: wavPath)
        let wavDigest = SHA256.hash(data: try Data(contentsOf: wavURL))
            .map { String(format: "%02x", $0) }
            .joined()
        guard wavDigest == "c51b6fa61d0f769382efb4d23c21c9c35ddad2e5edaf046e03358bbcad740af8" else {
            XCTFail("The publication parity references require canonical-firefox-16k-mono.wav.")
            return
        }

        let runtimeRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("WhisperASR/Runtime", isDirectory: true)
        let python = runtimeRoot.appendingPathComponent("Environment/bin/python")
        let model = runtimeRoot.appendingPathComponent(
            "Models/voxtral-\(VoxtralHelperManifest.modelRevision)",
            isDirectory: true
        )
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(
                atPath: model.appendingPathComponent("config.json").path
              ) else {
            XCTFail("Prepare the app-managed Voxtral runtime before running this opt-in test.")
            return
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let script = temporaryDirectory.appendingPathComponent("publication_parity.py")
        let output = temporaryDirectory.appendingPathComponent("result.json")
        let errorLog = temporaryDirectory.appendingPathComponent("stderr.log")
        try Self.realModelPublicationParityProbe.write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, model.path, wavURL.path]
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let stderr = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            XCTFail(stderr)
            return
        }

        let data = try Data(contentsOf: output)
        let report = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(report["tokenCount"] as? Int, 511)
        XCTAssertEqual(report["deltaCount"] as? Int, 101)
        XCTAssertEqual(
            report["tokenIDsSHA256"] as? String,
            "b5c9fbc2db11185d4d3bbec2b9eff0c8e405f2fb60c48c4b2143c99c108a48d7"
        )
        XCTAssertEqual(
            report["deltasSHA256"] as? String,
            "965447382c1a414c9463984aefef70f3b0511b49eef1e3321a4f270c696dcbad"
        )
        XCTAssertEqual(
            report["transcriptSHA256"] as? String,
            "17edae7ed400e32216183076613c9f417daa1c27c9280a98772dc9bde7710308"
        )
        XCTAssertEqual(report["emissionMarkerCount"] as? Int, 54)
        XCTAssertEqual(report["emissionMarkerUsableCount"] as? Int, 54)
        XCTAssertEqual(report["emissionMarkersValid"] as? Bool, true)
        XCTAssertEqual(
            report["emissionMarkersSHA256"] as? String,
            "7bca321520b27dcd46b9374288cb56a2c77f110d62f7107f9852b50d1952f462"
        )

        let reportDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: reportDirectory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: reportDirectory.appendingPathComponent(
                "voxtral-real-model-publication-parity-960ms-160ms.json"
            ),
            options: .atomic
        )
    }

    func testRealtimeHelperWhenOptedIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISPERASR_VOXTRAL_HELPER_SMOKE_WAV"] else {
            throw XCTSkip("Set WHISPERASR_VOXTRAL_HELPER_SMOKE_WAV to exercise the real helper.")
        }
        let samples = try await AudioLoader.loadSamples(url: URL(fileURLWithPath: path))
        let model = ProcessInfo.processInfo.environment["WHISPERASR_VOXTRAL_HELPER_VARIANT"]
            .flatMap(VoxtralModelVariant.init(rawValue:)) ?? .q4
        let delay = ProcessInfo.processInfo.environment["WHISPERASR_VOXTRAL_HELPER_DELAY_MS"]
            .flatMap(Int.init)
            .flatMap(VoxtralTranscriptionDelay.init(rawValue:)) ?? .milliseconds960
        let configuration = VoxtralContinuousConfiguration(model: model, delay: delay)
        let runtime = VoxtralHelperRuntime(configuration: configuration)
        do {
            try await runtime.prepare()
            let events = try await runtime.startSession(delayMilliseconds: delay.rawValue)
            let collector = Task { () -> [VoxtralHelperEvent] in
                var result: [VoxtralHelperEvent] = []
                for await event in events { result.append(event) }
                return result
            }
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + 5_120)
                try await runtime.append(
                    samples: Array(samples[offset..<end]),
                    range: offset..<end
                )
                offset = end
            }
            let transcript = try await runtime.stopAndFlush()
            let progress = await runtime.progress()
            XCTAssertFalse(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(progress.sentThrough, samples.count)
            XCTAssertEqual(progress.acknowledgedThrough, samples.count)
            XCTAssertNotNil(progress.helperRSSBytes)
            let firstProcess = try XCTUnwrap(progress.helperProcessIdentifier)
            let collected = await collector.value
            XCTAssertTrue(collected.contains {
                if case .completed = $0 { return true }
                return false
            })

            await runtime.shutdown()
            try await runtime.prepare()
            let replacementProgress = await runtime.progress()
            let replacement = try XCTUnwrap(replacementProgress.helperProcessIdentifier)
            XCTAssertNotEqual(firstProcess, replacement)
            _ = try await runtime.startSession()
            await runtime.cancel()
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testEachSessionGetsANewUnboundedEventStream() async {
        var pipe = VoxtralHelperEventPipe()
        let first = pipe.start()
        pipe.yield(.delta(text: "old", sentThrough: 1))
        pipe.finish()

        let second = pipe.start()
        pipe.yield(.ready)
        pipe.finish()

        var firstEvents: [VoxtralHelperEvent] = []
        for await event in first { firstEvents.append(event) }
        var secondEvents: [VoxtralHelperEvent] = []
        for await event in second { secondEvents.append(event) }
        XCTAssertEqual(firstEvents, [.delta(text: "old", sentThrough: 1)])
        XCTAssertEqual(secondEvents, [.ready])
    }

    func testSessionGenerationRejectsStaleReceiverWork() {
        var generation = VoxtralHelperSessionGeneration()
        let first = generation.begin()
        XCTAssertTrue(generation.accepts(first))

        let second = generation.begin()
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))

        generation.invalidate()
        XCTAssertFalse(generation.accepts(second))
    }

    func testFinalFlushDeadlineDoesNotWaitForBlockedWork() async {
        let started = ContinuousClock.now
        do {
            _ = try await VoxtralHelperRuntime.awaitFinalTranscript(
                deadline: .milliseconds(20)
            ) {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            XCTFail("Expected the final flush deadline to expire")
        } catch let error as VoxtralHelperError {
            XCTAssertEqual(
                error,
                .serverUnavailable(
                    "Voxtral did not finish its final transcript within 15 seconds. Audio was retained."
                )
            )
            XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManifestPinsTheAuditedRuntimeAndModel() {
        XCTAssertEqual(VoxtralHelperManifest.mlxAudioVersion, "0.4.5")
        XCTAssertEqual(
            VoxtralHelperManifest.mlxAudioCommit,
            "04151c6abb74b886f879a4457ccdc96761f10102"
        )
        XCTAssertEqual(VoxtralHelperManifest.modelID, "iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit")
        XCTAssertEqual(
            VoxtralHelperManifest.modelRevision,
            "12091661ce5f58788624fa49fad9ddbbf67cf063"
        )
        XCTAssertEqual(VoxtralHelperManifest.transcriptionDelayMilliseconds, 960)
        XCTAssertEqual(VoxtralHelperManifest.modelFrameSamples, 1_280)
        XCTAssertEqual(VoxtralHelperManifest.transportBlockMilliseconds, 160)
        XCTAssertEqual(VoxtralHelperManifest.runtimePatchVersion, "continuous-stream-v4")
    }

    func testContinuousConfigurationsPinBothModelsAndSupportedDelays() throws {
        XCTAssertEqual(VoxtralModelVariant.q4.modelID, "iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit")
        XCTAssertEqual(
            VoxtralModelVariant.q4.modelRevision,
            "12091661ce5f58788624fa49fad9ddbbf67cf063"
        )
        XCTAssertEqual(VoxtralModelVariant.q6.modelID, "mlx-community/Voxtral-Mini-4B-Realtime-6bit")
        XCTAssertEqual(
            VoxtralModelVariant.q6.modelRevision,
            "02eb0caeb9dafb554c17a72b93dbf40cd3736c31"
        )
        XCTAssertEqual(
            VoxtralModelVariant.q6.conversionSource?.modelID,
            "mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16"
        )
        XCTAssertEqual(
            VoxtralModelVariant.q6.conversionSource?.revision,
            "9977a0f5c0fce8472083af92957497118adc412b"
        )
        XCTAssertEqual(
            VoxtralModelVariant.q6.localSnapshotID,
            "mlx-audio-q6-9977a0f5-v1"
        )
        XCTAssertEqual(
            VoxtralModelVariant.q6.localArtifactRevision,
            "mlx-audio-04151c6abb74b886f879a4457ccdc96761f10102-9977a0f5c0fce8472083af92957497118adc412b-q6-g64-affine"
        )
        XCTAssertEqual(
            Set(VoxtralTranscriptionDelay.allCases.map(\.rawValue)),
            [960, 1_200, 2_400]
        )

        let configurations = VoxtralModelVariant.allCases.flatMap { model in
            VoxtralTranscriptionDelay.allCases.map {
                VoxtralContinuousConfiguration(model: model, delay: $0)
            }
        }
        XCTAssertEqual(Set(configurations.map(\.modelSnapshotDirectoryName)).count, 2)
        for configuration in configurations {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    VoxtralContinuousConfiguration.self,
                    from: JSONEncoder().encode(configuration)
                ),
                configuration
            )
        }
    }

    func testStabilityGuardTracksSelectedDelayPlusTransportBlock() {
        XCTAssertEqual(
            VoxtralContinuousConfiguration(
                model: .q4,
                delay: .milliseconds960
            ).stabilityGuardSamples,
            17_920
        )
        XCTAssertEqual(
            VoxtralContinuousConfiguration(
                model: .q6,
                delay: .milliseconds1200
            ).stabilityGuardSamples,
            21_760
        )
        XCTAssertEqual(
            VoxtralContinuousConfiguration(
                model: .q6,
                delay: .milliseconds2400
            ).stabilityGuardSamples,
            40_960
        )
    }

    func testStoredConfigurationDefaultsSafelyAndAcceptsOnlySelectablePairs() {
        let suite = "VoxtralHelperRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VoxtralContinuousConfiguration.stored(in: defaults), .default)
        defaults.set("q4-2400", forKey: VoxtralContinuousConfiguration.storageKey)
        XCTAssertEqual(VoxtralContinuousConfiguration.stored(in: defaults), .default)
        defaults.set("q6-1200", forKey: VoxtralContinuousConfiguration.storageKey)
        XCTAssertEqual(
            VoxtralContinuousConfiguration.stored(in: defaults),
            .init(model: .q6, delay: .milliseconds1200)
        )
    }

    func testBundledPythonLockMatchesTheAuditedHash() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "uv",
                withExtension: "lock",
                subdirectory: "VoxtralHelper"
            )
        )
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, VoxtralHelperManifest.uvLockSHA256)
    }

    func testBundledRuntimePatchMatchesTheAuditedHash() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "patch_runtime",
                withExtension: "py",
                subdirectory: "VoxtralHelper"
            )
        )
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(digest, VoxtralHelperManifest.runtimePatchSHA256)
    }

    func testPCM16ConversionClampsAndUsesLittleEndian() {
        let data = VoxtralRealtimeWire.pcm16Data([-2, -1, -0.5, .nan, 0, 0.5, 1, 2])
        let values = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
        XCTAssertEqual(values, [-32_768, -32_768, -16_384, 0, 0, 16_384, 32_767, 32_767])
    }

    func testAppendUsesOpenAIRealtimePCMMessage() throws {
        let text = try VoxtralRealtimeWire.appendMessage(samples: [0, 1])
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        let audio = try XCTUnwrap(object["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: audio)?.count, 4)
    }

    func testSessionDisablesTurnDetection() throws {
        let text = try VoxtralRealtimeWire.sessionUpdateMessage(model: "/tmp/model")
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 16_000)
    }

    func testOnlyExplicitStopMessageCommitsTheStream() throws {
        XCTAssertFalse(try VoxtralRealtimeWire.appendMessage(samples: [0]).contains("commit"))
        XCTAssertFalse(try VoxtralRealtimeWire.barrierMessage().contains("commit"))
        XCTAssertTrue(try VoxtralRealtimeWire.commitMessage().contains("input_audio_buffer.commit"))
    }

    func testFeedCursorRequiresContiguousExactRangesAndTracksBarrierACKs() throws {
        var cursor = VoxtralHelperFeedCursor()
        XCTAssertNil(cursor.absoluteSample(forRelativeSample: 0))
        try cursor.stage(10_000..<15_120, sampleCount: 5_120)
        try cursor.stage(15_120..<20_240, sampleCount: 5_120)
        XCTAssertEqual(cursor.sessionBaseSample, 10_000)
        XCTAssertEqual(cursor.absoluteSample(forRelativeSample: 3_840), 13_840)
        XCTAssertEqual(cursor.sentThrough, 20_240)
        XCTAssertEqual(cursor.acknowledgedThrough, 10_000)
        XCTAssertEqual(cursor.backlogSamples, 10_240)
        XCTAssertEqual(cursor.acknowledgeNext(), 15_120)
        XCTAssertEqual(cursor.backlogSamples, 5_120)
        XCTAssertEqual(cursor.acknowledgeNext(), 20_240)
        XCTAssertEqual(cursor.backlogSamples, 0)
        XCTAssertThrowsError(try cursor.stage(20_241..<25_361, sampleCount: 5_120))
    }

    func testWireEventsDecodeDeltasFinalsACKsAndErrors() throws {
        XCTAssertEqual(
            try VoxtralRealtimeWire.decode(
                #"{"type":"conversation.item.input_audio_transcription.delta","delta":"こん"}"#
            ),
            .delta("こん")
        )
        XCTAssertEqual(
            try VoxtralRealtimeWire.decode(
                #"{"type":"whisperasr.voxtral.emission_marker","generated_index":15,"decoder_position":60,"delay_frames":12,"proxy_end_sample":3840,"group_text_start_utf8":3,"is_usable":true}"#
            ),
            .emissionMarker(
                generatedIndex: 15,
                decoderPosition: 60,
                delayFrames: 12,
                proxyEndSample: 3_840,
                groupTextStartUTF8: 3,
                isUsable: true
            )
        )
        XCTAssertThrowsError(try VoxtralRealtimeWire.decode(
            #"{"type":"whisperasr.voxtral.emission_marker","generated_index":15}"#
        ))
        XCTAssertEqual(
            try VoxtralRealtimeWire.decode(
                #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"こんにちは"}"#
            ),
            .completed("こんにちは")
        )
        XCTAssertEqual(
            try VoxtralRealtimeWire.decode(#"{"type":"session.updated"}"#),
            .sessionUpdated
        )
        XCTAssertEqual(
            try VoxtralRealtimeWire.decode(
                #"{"type":"error","error":{"message":"broken"}}"#
            ),
            .error("broken")
        )
    }

    private static let realModelPublicationParityProbe = #"""
    import gc
    import hashlib
    import json
    import sys

    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt.models.voxtral_realtime.streaming import VoxtralStreamingSession
    from mlx_audio.stt.utils import load_audio, load_model


    def delayed_decode_some(self, max_decode_tokens):
        """Reference behavior: publish a prediction after its next audio frame exists."""
        deltas = []
        eos = self.model.config.eos_token_id
        tok_emb = self.model.decoder.tok_embeddings

        for _ in range(max_decode_tokens):
            if self._n_adapter() <= self._pos and not self._flushed_close:
                return deltas

            if self._n_adapter() <= self._pos:
                if not self._next_tok_emitted:
                    token = int(self._next_tok.item())
                    delta = self._record_token(token)
                    if delta:
                        deltas.append(delta)
                    self._next_tok_emitted = True
                    if token == eos:
                        self._done = True
                        return deltas
                    if self.max_tokens is not None and len(self.generated) > self.max_tokens:
                        raise RuntimeError("Voxtral streaming token limit reached before EOS")
                self._done = True
                return deltas

            previous = self._next_tok
            token_embed = tok_emb(previous.reshape(1))[0]
            embed = self._adapter_at(self._pos) + token_embed
            hidden, self._cache = self.model.decoder.forward(
                embed[None, :], start_pos=self._pos, cache=self._cache
            )
            logits = self.model.decoder.logits(hidden.squeeze(0))
            following = self.model._next_token_mx(logits, self.temperature)
            mx.async_eval(following)

            token = int(previous.item())
            delta = self._record_token(token)
            if delta:
                deltas.append(delta)
            self._next_tok_emitted = True
            if token == eos:
                self._done = True
                return deltas
            if self.max_tokens is not None and len(self.generated) > self.max_tokens:
                raise RuntimeError("Voxtral streaming token limit reached before EOS")

            self._next_tok = following
            self._next_tok_emitted = False
            self._pos += 1
            self._trim_adapter(self._pos)
            if len(self.generated) % 256 == 0:
                mx.clear_cache()

        return deltas


    def run(model, audio):
        session = model.create_streaming_session(
            temperature=0.0,
            transcription_delay_ms=960,
        )
        deltas = []
        markers = []
        for start in range(0, audio.size, 2_560):
            session.feed(audio[start:start + 2_560])
            deltas.extend(session.step(max_decode_tokens=8))
            markers.extend(session.drain_emission_markers())
        session.close()
        steps = 0
        while not session.done:
            deltas.extend(session.step(max_decode_tokens=16))
            markers.extend(session.drain_emission_markers())
            steps += 1
            if steps > 2_000:
                raise RuntimeError("Voxtral final flush made no progress")
        return list(session.generated), deltas, session.final_text, markers


    def digest(value):
        if isinstance(value, str):
            payload = value.encode("utf-8")
        else:
            payload = json.dumps(
                value, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
        return hashlib.sha256(payload).hexdigest()


    model_path, wav_path = sys.argv[1:]
    audio = np.asarray(load_audio(wav_path, sr=16_000), dtype=np.float32).reshape(-1)
    if audio.size != 640_000:
        raise RuntimeError(f"Expected 640000 samples, got {audio.size}")
    model = load_model(model_path)

    production_decode_some = VoxtralStreamingSession._decode_some
    try:
        VoxtralStreamingSession._decode_some = delayed_decode_some
        reference = run(model, audio)
    finally:
        VoxtralStreamingSession._decode_some = production_decode_some
    gc.collect()
    mx.clear_cache()
    production = run(model, audio)

    if reference != production:
        names = ("token IDs", "deltas", "transcript", "emission markers")
        for name, before, after in zip(names, reference, production):
            if before != after:
                raise AssertionError(f"Immediate publication changed {name}")

    tokens, deltas, transcript, markers = production
    markers_valid = all(
        marker["decoder_position"] - 45 == marker["generated_index"]
        and marker["delay_frames"] == 12
        and marker["proxy_end_sample"]
            == max(0, marker["generated_index"] - 12) * 1_280
        for marker in markers
    )
    if not markers_valid:
        raise AssertionError("Voxtral emission marker invariant failed")
    print(json.dumps({
        "tokenCount": len(tokens),
        "deltaCount": len(deltas),
        "emissionMarkerCount": len(markers),
        "emissionMarkerUsableCount": sum(marker["is_usable"] for marker in markers),
        "emissionMarkersSHA256": digest(markers),
        "emissionMarkersValid": markers_valid,
        "tokenIDsSHA256": digest(tokens),
        "deltasSHA256": digest(deltas),
        "transcriptSHA256": digest(transcript),
    }, ensure_ascii=False, indent=2, sort_keys=True))
    """#
}
