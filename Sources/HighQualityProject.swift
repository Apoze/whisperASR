import Foundation

struct HighQualityProjectManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let name: String
    let folderPath: String
    let createdAt: Date
    let updatedAt: Date
}

struct HighQualityProjectError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct HighQualityProjectJobReference: Identifiable, Sendable {
    let jobID: UUID
    let source: HighQualitySourceProvenance
    let resultDirectory: URL

    var id: UUID { jobID }
}

struct HighQualityProject: Identifiable, Sendable {
    let directory: URL
    let manifest: HighQualityProjectManifest

    var id: UUID { manifest.id }
    var name: String { manifest.name }
    var folderURL: URL { URL(fileURLWithPath: manifest.folderPath) }
    var jobsDirectory: URL { directory.appendingPathComponent("Jobs", isDirectory: true) }
    var savedResults: [HighQualitySavedResult] {
        HighQualityJob.savedResults(in: jobsDirectory).filter { $0.manifest.projectID == id }
    }
    var jobReferences: [HighQualityProjectJobReference] {
        savedResults.map {
            .init(
                jobID: $0.id,
                source: $0.manifest.source,
                resultDirectory: $0.directory
            )
        }
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
        let folder = try validatedFolder(folder)
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
                updatedAt: now
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
        let current = try Self.load(from: directory)
        return try current.updating(name: Self.validatedName(name))
    }

    func relocated(to folder: URL) throws -> Self {
        let current = try Self.load(from: directory)
        return try current.updating(folder: Self.validatedFolder(folder))
    }

    func delete() throws {
        _ = try Self.load(from: directory)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw HighQualityProjectError(
                message: "Could not delete the Project: \(error.localizedDescription)"
            )
        }
    }

    func reset() throws -> Self {
        let current = try Self.load(from: directory)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: jobsDirectory.path) {
            try fileManager.createDirectory(at: jobsDirectory, withIntermediateDirectories: false)
            return current
        }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(
            ".\(id.uuidString).reset-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: staging) }
            try AtomicDirectory.swap(staging, with: jobsDirectory)
            return current
        } catch {
            throw HighQualityProjectError(
                message: "Could not reset the Project: \(error.localizedDescription)"
            )
        }
    }

    func validateForJob() throws {
        let current = try Self.load(from: directory)
        guard current.folderRelocationMessage == nil else {
            throw HighQualityProjectError(
                message: "The Project folder is missing or moved. Locate it before adding jobs."
            )
        }
    }

    private func updating(name: String? = nil, folder: URL? = nil) throws -> Self {
        let updated = Self(
            directory: directory,
            manifest: .init(
                schemaVersion: manifest.schemaVersion,
                id: id,
                name: name ?? self.name,
                folderPath: folder?.path ?? manifest.folderPath,
                createdAt: manifest.createdAt,
                updatedAt: Date()
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
            let manifest = try decoder.decode(
                HighQualityProjectManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
            guard manifest.schemaVersion == HighQualityProjectManifest.currentSchemaVersion,
                  directory.lastPathComponent == manifest.id.uuidString,
                  manifest.folderPath.hasPrefix("/"),
                  !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    private static func validatedFolder(_ url: URL) throws -> URL {
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, isDirectory(folder) else {
            throw HighQualityProjectError(
                message: "Choose an existing local folder for the Project."
            )
        }
        return folder
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
