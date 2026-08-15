import Foundation

struct HighQualityProjectManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let name: String
    let folderPath: String
    let createdAt: Date
    let updatedAt: Date
    let jobReferences: [HighQualityProjectJobReference]
}

struct HighQualityProjectError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct HighQualityProjectJobReference: Codable, Equatable, Identifiable, Sendable {
    let jobID: UUID
    let source: HighQualitySourceProvenance
    let sourceRelativePath: String?
    let resultPath: String

    var id: UUID { jobID }
}

struct HighQualityProject: Identifiable, Sendable {
    // ponytail: process-wide lock; use per-Project locks only if metadata contention appears.
    private static let metadataLock = NSLock()

    let directory: URL
    let manifest: HighQualityProjectManifest

    var id: UUID { manifest.id }
    var name: String { manifest.name }
    var folderURL: URL { URL(fileURLWithPath: manifest.folderPath) }
    var jobsDirectory: URL { directory.appendingPathComponent("Jobs", isDirectory: true) }
    var savedResults: [HighQualitySavedResult] {
        let references = Dictionary(uniqueKeysWithValues: jobReferences.map { ($0.id, $0) })
        return HighQualityJob.savedResults(in: jobsDirectory)
            .filter { $0.manifest.projectID == id }
            .map { saved in
                guard saved.relocatedSourcePath == nil,
                      let relativePath = references[saved.id]?.sourceRelativePath else {
                    return saved
                }
                return HighQualitySavedResult(
                    directory: saved.directory,
                    manifest: saved.manifest,
                    relocatedSourcePath: folderURL.appendingPathComponent(relativePath).path
                )
            }
    }
    var jobReferences: [HighQualityProjectJobReference] {
        manifest.jobReferences
    }
    var folderRelocationMessage: String? {
        guard Self.isDirectory(folderURL) else {
            return "The Project folder is missing or moved. Locate it before adding jobs."
        }
        return nil
    }

    static func create(
        named name: String,
        folder: URL,
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> Self {
        let name = try validatedName(name)
        let folder = try validatedFolder(folder, managedRoot: root)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let now = Date()
        let project = Self(
            directory: directory,
            manifest: .init(
                schemaVersion: HighQualityProjectManifest.currentSchemaVersion,
                id: id,
                name: name,
                folderPath: folder.path,
                createdAt: now,
                updatedAt: now,
                jobReferences: []
            )
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: project.jobsDirectory,
                withIntermediateDirectories: false
            )
            try write(project.manifest, to: directory)
            return project
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw HighQualityProjectError(
                message: "Could not create the Project: \(error.localizedDescription)"
            )
        }
    }

    static func all(
        in root: URL = AppStoragePaths.highQualityProjects
    ) -> [Self] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return directories.compactMap { try? load(from: $0) }.sorted {
            $0.manifest.createdAt < $1.manifest.createdAt
        }
    }

    static func open(
        _ id: UUID,
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> Self {
        try load(from: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func renamed(to name: String) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory)
            return try current.updating(name: Self.validatedName(name))
        }
    }

    func relocated(to folder: URL) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory)
            return try current.updating(folder: Self.validatedFolder(
                folder,
                managedRoot: directory.deletingLastPathComponent()
            ))
        }
    }

    func delete() throws {
        try Self.withMetadataLock {
            _ = try Self.load(from: directory)
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                throw HighQualityProjectError(
                    message: "Could not delete the Project: \(error.localizedDescription)"
                )
            }
        }
    }

    func validateForJob() throws {
        let current = try Self.load(from: directory)
        if let message = current.folderRelocationMessage {
            throw HighQualityProjectError(message: message)
        }
    }

    @discardableResult
    func indexJob(
        id jobID: UUID,
        source: HighQualitySourceProvenance,
        resultDirectory: URL
    ) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory)
            if let message = current.folderRelocationMessage {
                throw HighQualityProjectError(message: message)
            }
            let resultPath = "Jobs/\(jobID.uuidString)"
            let expectedDirectory = current.directory.appendingPathComponent(
                resultPath,
                isDirectory: true
            )
            guard resultDirectory.standardizedFileURL == expectedDirectory.standardizedFileURL else {
                throw HighQualityProjectError(
                    message: "The Project result reference is outside its managed storage."
                )
            }
            let reference = HighQualityProjectJobReference(
                jobID: jobID,
                source: source,
                sourceRelativePath: source.sourceURL == nil
                    ? Self.relativePath(for: source.path, in: current.folderURL) : nil,
                resultPath: resultPath
            )
            if let existing = current.jobReferences.first(where: { $0.id == jobID }) {
                guard existing == reference else {
                    throw HighQualityProjectError(
                        message: "This Project already indexes a different job with that identifier."
                    )
                }
                return current
            }
            return try current.updating(jobReferences: current.jobReferences + [reference])
        }
    }

    private func updating(
        name: String? = nil,
        folder: URL? = nil,
        jobReferences: [HighQualityProjectJobReference]? = nil
    ) throws -> Self {
        let updated = Self(
            directory: directory,
            manifest: .init(
                schemaVersion: manifest.schemaVersion,
                id: id,
                name: name ?? self.name,
                folderPath: folder?.path ?? manifest.folderPath,
                createdAt: manifest.createdAt,
                updatedAt: Date(),
                jobReferences: jobReferences ?? manifest.jobReferences
            )
        )
        do {
            try Self.write(updated.manifest, to: directory)
            return updated
        } catch {
            throw HighQualityProjectError(
                message: "Could not update the Project: \(error.localizedDescription)"
            )
        }
    }

    private static func load(from directory: URL) throws -> Self {
        do {
            guard isManagedDirectory(directory),
                  isManagedDirectory(directory.appendingPathComponent("Jobs"), allowMissing: true)
            else {
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
            let manifest = try decoder.decode(
                HighQualityProjectManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
            guard manifest.schemaVersion == HighQualityProjectManifest.currentSchemaVersion,
                  directory.lastPathComponent == manifest.id.uuidString,
                  manifest.folderPath.hasPrefix("/"),
                  !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isInsideManagedRoot(
                    URL(fileURLWithPath: manifest.folderPath),
                    root: directory.deletingLastPathComponent()
                  ),
                  Set(manifest.jobReferences.map(\.id)).count == manifest.jobReferences.count,
                  manifest.jobReferences.allSatisfy(validReference) else {
                throw HighQualityProjectError(message: "This Project metadata is unsupported.")
            }
            return Self(directory: directory, manifest: manifest)
        } catch let error as HighQualityProjectError {
            throw error
        } catch {
            throw HighQualityProjectError(
                message: "The Project metadata is missing or unreadable."
            )
        }
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw HighQualityProjectError(message: "Project name cannot be empty.")
        }
        return name
    }

    private static func validatedFolder(_ url: URL, managedRoot: URL) throws -> URL {
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL,
              isDirectory(folder),
              !isInsideManagedRoot(folder, root: managedRoot) else {
            throw HighQualityProjectError(
                message: "Choose an existing local folder outside Project storage."
            )
        }
        return folder
    }

    private static func isInsideManagedRoot(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return path.starts(with: rootPath)
    }

    private static func relativePath(for sourcePath: String, in folder: URL) -> String? {
        let source = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard source.count > folder.count, source.starts(with: folder) else { return nil }
        return source.dropFirst(folder.count).joined(separator: "/")
    }

    private static func validReference(_ reference: HighQualityProjectJobReference) -> Bool {
        guard reference.resultPath == "Jobs/\(reference.id.uuidString)" else { return false }
        guard let relativePath = reference.sourceRelativePath else { return true }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func withMetadataLock<T>(_ operation: () throws -> T) rethrows -> T {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return try operation()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isManagedDirectory(_ url: URL, allowMissing: Bool = false) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return allowMissing && !FileManager.default.fileExists(atPath: url.path)
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func write(
        _ manifest: HighQualityProjectManifest,
        to directory: URL
    ) throws {
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("project.json"),
            options: .atomic
        )
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
