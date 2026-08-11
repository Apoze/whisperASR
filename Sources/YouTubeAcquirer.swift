import Foundation

enum YouTubeAcquirer {
    static func acquire(_ sourceURL: URL, to directory: URL) async throws
        -> HighQualityYouTubeAcquisition
    {
        guard let executable = ExecutableLocator.find(
            named: "yt-dlp",
            preferredPaths: [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                "/opt/local/bin/yt-dlp",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/yt-dlp").path,
            ]
        ) else {
            throw YouTubeAcquisitionError(
                "yt-dlp is not installed. Install it with `brew install yt-dlp`."
            )
        }
        return try await acquire(sourceURL, to: directory, using: executable)
    }

    static func acquire(_ sourceURL: URL, to directory: URL, using executable: URL) async throws
        -> HighQualityYouTubeAcquisition
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let versionResult = try await run(
            executable,
            arguments: ["--ignore-config", "--version"]
        )
        guard versionResult.status == 0 else {
            throw YouTubeAcquisitionError(
                diagnosticMessage("Could not read the yt-dlp version", versionResult),
                diagnostics: versionResult.stderr
            )
        }
        let version = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let formatSelector = AudioLoader.hasFFmpeg
                ? "bestaudio[acodec!=none]/best[acodec!=none]"
                : "bestaudio[ext=m4a][acodec!=none]"
            let result = try await run(executable, arguments: [
                "--ignore-config",
                "--no-playlist",
                "--no-simulate",
                "--no-progress",
                "--print-json",
                "-f", formatSelector,
                "-o", directory.appendingPathComponent("source.%(ext)s").path,
                sourceURL.absoluteString,
            ])
            guard result.status == 0 else {
                throw YouTubeAcquisitionError(
                    diagnosticMessage("yt-dlp could not acquire this video", result),
                    ytDLPVersion: version,
                    diagnostics: result.stderr
                )
            }

            let metadata = try metadata(from: result.stdout)
            let audioURL = try acquiredAudio(in: directory)
            let format = [metadata["format_id"], metadata["ext"]]
                .compactMap { $0 as? String }
                .joined(separator: "/")
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostics = [format.isEmpty ? "" : "format=\(format)", stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            return HighQualityYouTubeAcquisition(
                audioURL: audioURL,
                evidence: .init(
                    sourceURL: sourceURL.absoluteString,
                    title: metadata["title"] as? String ?? "",
                    channel: metadata["channel"] as? String
                        ?? metadata["uploader"] as? String
                        ?? "",
                    description: metadata["description"] as? String ?? "",
                    ytDLPVersion: version,
                    diagnostics: diagnostics
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as YouTubeAcquisitionError {
            throw error.withVersion(version)
        } catch {
            throw YouTubeAcquisitionError(
                error.localizedDescription,
                ytDLPVersion: version,
                diagnostics: error.localizedDescription
            )
        }
    }

    private static func metadata(from output: String) throws -> [String: Any] {
        guard let line = output.split(whereSeparator: \.isNewline).last,
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any] else {
            throw YouTubeAcquisitionError("yt-dlp returned invalid video metadata.")
        }
        return object
    }

    private static func acquiredAudio(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        guard let audio = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(
            where: {
                $0.lastPathComponent.hasPrefix("source.")
                    && $0.pathExtension != "part"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        ) else {
            throw YouTubeAcquisitionError("yt-dlp completed without producing usable audio.")
        }
        return audio
    }

    private static func diagnosticMessage(_ message: String, _ result: ProcessResult) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? message + "." : message + ": " + detail
    }

    private static func run(_ executable: URL, arguments: [String]) async throws -> ProcessResult {
        let controller = ProcessController()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try controller.start(process)
            async let output = read(stdout.fileHandleForReading)
            async let errors = read(stderr.fileHandleForReading)
            async let status = controller.wait()
            let result = await ProcessResult(
                status: status,
                stdout: String(decoding: output, as: UTF8.self),
                stderr: String(decoding: errors, as: UTF8.self)
            )
            if result.status != 0, controller.wasCancelled {
                throw CancellationError()
            }
            return result
        } onCancel: {
            controller.cancel()
        }
    }

    private static func read(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct YouTubeAcquisitionError: LocalizedError {
    let message: String
    let ytDLPVersion: String?
    let diagnostics: String

    init(_ message: String, ytDLPVersion: String? = nil, diagnostics: String? = nil) {
        self.message = message
        self.ytDLPVersion = ytDLPVersion
        self.diagnostics = (diagnostics ?? message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorDescription: String? { message }

    func withVersion(_ version: String) -> Self {
        Self(message, ytDLPVersion: ytDLPVersion ?? version, diagnostics: diagnostics)
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var isFinished = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func start(_ process: Process) throws {
        lock.lock()
        if isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        do {
            process.terminationHandler = { [weak self] _ in self?.recordTermination() }
            try process.run()
            self.process = process
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    func wait() async -> Int32 {
        while true {
            lock.lock()
            let result = isFinished ? process?.terminationStatus : nil
            lock.unlock()
            if let result { return result }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func recordTermination() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }
}
