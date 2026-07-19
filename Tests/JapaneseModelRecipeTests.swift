import CWhisper
import Foundation
import XCTest
@testable import WhisperASRApp

final class JapaneseModelRecipeTests: XCTestCase {
    func testCorrectiveRecipesFixNativeSessionSemantics() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("docs/japanese-live/model-recipes.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let common = try XCTUnwrap(json["common"] as? [String: Any])
        let endpoint = try XCTUnwrap(common["productEndpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["preRollSamples"] as? Int, LocalEndpointPlanner.preRoll)
        XCTAssertEqual(endpoint["postRollSamples"] as? Int, LocalEndpointPlanner.postRoll)
        XCTAssertEqual(endpoint["minimumBatchSamples"] as? Int, LocalEndpointPlanner.minimumBatch)
        XCTAssertEqual(endpoint["maximumPhraseSamples"] as? Int, LocalEndpointPlanner.maxPhrase)

        let recipes = try XCTUnwrap(json["recipes"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: recipes.compactMap { recipe in
            (recipe["id"] as? String).map { ($0, recipe) }
        })
        XCTAssertEqual(Set(byID.keys), Set([
            "whisper-turbo-whispercpp",
            "kotoba-v2-q5-whispercpp",
            "voxtral-q4-960",
            "nemotron-1120",
            "nemotron-560",
            "qwen3-asr-1.7b-mlx-8bit",
            "mlx-whisper-turbo",
            "whispermlx-v3.12.2-turbo",
            "whisperlivekit-simulstreaming-mlx-hybrid",
            "whisperlivekit-localagreement-mlx",
        ]))

        func execution(_ id: String) throws -> [String: Any] {
            try XCTUnwrap(byID[id]?["execution"] as? [String: Any])
        }
        let voxtral = try execution("voxtral-q4-960")
        XCTAssertEqual(voxtral["sessionScope"] as? String, "one-session-per-capture")
        XCTAssertEqual(voxtral["resetPolicy"] as? String, "finish-only")
        XCTAssertEqual(voxtral["transportBlockMilliseconds"] as? Int, 160)
        XCTAssertEqual(voxtral["transcriptionDelayMilliseconds"] as? Int, 960)

        for id in ["nemotron-1120", "nemotron-560"] {
            let nemotron = try execution(id)
            XCTAssertEqual(nemotron["language"] as? String, "ja-JP")
            XCTAssertEqual(nemotron["resetPolicy"] as? String, "after-safe-vad-final")
        }
        let mlx = try execution("mlx-whisper-turbo")
        XCTAssertEqual(mlx["temperature"] as? Int, 0)
        XCTAssertEqual(mlx["conditionOnPreviousText"] as? Bool, false)
        XCTAssertEqual(mlx["withoutTimestamps"] as? Bool, true)
        let whisperMLX = try execution("whispermlx-v3.12.2-turbo")
        XCTAssertEqual(whisperMLX["alignment"] as? Bool, false)
        XCTAssertEqual(whisperMLX["diarization"] as? Bool, false)
        XCTAssertEqual(whisperMLX["vadOffsetIgnoredBySileroMerge"] as? Bool, true)
        let simul = try execution("whisperlivekit-simulstreaming-mlx-hybrid")
        XCTAssertEqual(simul["fullMLXExperimental"] as? Bool, false)
        XCTAssertEqual(simul["decoder"] as? String, "beam")
        XCTAssertEqual(simul["beams"] as? Int, 1)
        XCTAssertEqual(simul["vadFlagEffective"] as? Bool, false)
        XCTAssertEqual(simul["responseMode"] as? String, "diff")
        let localAgreement = try execution("whisperlivekit-localagreement-mlx")
        XCTAssertEqual(localAgreement["policy"] as? String, "localagreement")
        XCTAssertEqual(localAgreement["correctiveRecipeStatus"] as? String, "not-yet-run")
        XCTAssertEqual(localAgreement["wordTimestamps"] as? Bool, true)
    }

    func testEmbeddedWhisperRuntimeMatchesPinnedRecipe() {
        XCTAssertEqual(String(cString: whisper_version()), "1.8.3")
        let system = String(cString: whisper_print_system_info())
        XCTAssertTrue(system.contains("COREML = 0"))
        XCTAssertTrue(system.contains("MTL : EMBED_LIBRARY = 1"))
    }

    func testInstalledRecipeArtifactsWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["WHISPERASR_VERIFY_MODEL_RECIPES"] == "1" else {
            throw XCTSkip("Set WHISPERASR_VERIFY_MODEL_RECIPES=1 for the local artifact audit.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let files: [(String, URL, String)] = [
            (
                "CWhisper",
                root.appendingPathComponent(
                    "Frameworks/CWhisper.xcframework/macos-arm64/libwhisper_all.a"
                ),
                "358986f0ac0f2669a015e6e832047089053081d41387383223afa69e7c2b7d90"
            ),
            (
                "Whisper Turbo",
                appSupport.appendingPathComponent(
                    "WhisperASR/Models/ggml-large-v3-turbo.bin"
                ),
                "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
            ),
            (
                "Kotoba Q5",
                root.appendingPathComponent(
                    ".build/benchmarks/japanese-live/tools/models/"
                        + "kotoba-whisper-v2.0-ggml/"
                        + "e3a0cf6a62b95911703cfb97d819292e058f12c3/"
                        + "ggml-kotoba-whisper-v2.0-q5_0.bin"
                ),
                "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"
            ),
            (
                "MLX Turbo",
                root.appendingPathComponent(
                    ".build/benchmarks/japanese-live/tools/models/"
                        + "mlx-whisper-large-v3-turbo/"
                        + "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb/weights.safetensors"
                ),
                "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"
            ),
            (
                "MLX Turbo config",
                root.appendingPathComponent(
                    ".build/benchmarks/japanese-live/tools/models/"
                        + "mlx-whisper-large-v3-turbo/"
                        + "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb/config.json"
                ),
                "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"
            ),
            (
                "Qwen 1.7B",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/"
                        + "Qwen3-ASR-1.7B-MLX-8bit/model.safetensors"
                ),
                "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
            ),
            (
                "Qwen config",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/config.json"
                ),
                "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"
            ),
            (
                "Qwen tokenizer config",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/"
                        + "Qwen3-ASR-1.7B-MLX-8bit/tokenizer_config.json"
                ),
                "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
            ),
            (
                "Qwen vocabulary",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/vocab.json"
                ),
                "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
            (
                "Qwen merges",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit/merges.txt"
                ),
                "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            (
                "Qwen weights index",
                cache.appendingPathComponent(
                    "qwen3-speech/models/aufklarer/"
                        + "Qwen3-ASR-1.7B-MLX-8bit/model.safetensors.index.json"
                ),
                "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"
            ),
            (
                "WhisperLiveKit decoder",
                root.appendingPathComponent(
                    ".build/benchmarks/japanese-live/tools/whisperlivekit/"
                        + "5874bdeeaddf968ab73e005eb287e1b597b0eb37/models/openai/"
                        + "large-v3-turbo.pt"
                ),
                "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a"
            ),
        ]
        for (name, url, expected) in files {
            XCTAssertEqual(
                try JapaneseBenchmarkSupport.artifactSHA256(at: url),
                expected,
                name
            )
        }

        let trees: [(String, URL, String)] = [
            (
                "Voxtral Q4",
                appSupport.appendingPathComponent(
                    "WhisperASR/Runtime/Models/"
                        + "voxtral-12091661ce5f58788624fa49fad9ddbbf67cf063"
                ),
                "178e8cd18ffe0e6788504cac1146bbc0c0eafb262acecd24aa63c0e863333d86"
            ),
            (
                "Nemotron 1120",
                root.appendingPathComponent(
                    ".build/models/nemotron-"
                        + "1a41b75758b0337ff67db7d5408280aaaf23074e/"
                        + "nemotron-multilingual/multilingual/1120ms"
                ),
                "a398b4fb9d1818395934191c7301571f6a958b8ad2a82e670029da38bd3efae9"
            ),
            (
                "Nemotron 560",
                root.appendingPathComponent(
                    ".build/models/nemotron-"
                        + "1a41b75758b0337ff67db7d5408280aaaf23074e/"
                        + "nemotron-multilingual/multilingual/560ms"
                ),
                "ad9a4c88796e765d60e304d36ae2688b914835447203f44af92056212cfc340d"
            ),
        ]
        for (name, url, expected) in trees {
            XCTAssertEqual(
                try JapaneseBenchmarkSupport.artifactSHA256(at: url),
                expected,
                name
            )
        }
    }
}
