import Foundation

struct HighQualityProjectVoiceCentroid: Codable, Equatable, Sendable {
    let anonymousSpeakerID: String
    let vectorDimension: Int
    let values: [Float]
    let modelID: String
    let modelRevision: String
    let runtimeRevision: String
    let embeddingVariant: String
    let sourceJobID: UUID
}

enum HighQualityProjectDestructiveAction: Equatable {
    case reset
    case delete
}

struct HighQualityProjectVoiceProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let centroids: [HighQualityProjectVoiceCentroid]
}

struct HighQualityProjectHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let action: String
    let createdAt: Date
    let jobID: UUID?
    let details: [String: String]
}

struct HighQualityProjectScope: Codable, Equatable, Sendable {
    let metadata: [String: String]
    let glossarySelection: [String]
    let voiceProfiles: [HighQualityProjectVoiceProfile]
    let history: [HighQualityProjectHistoryEntry]

    static let empty = Self(
        metadata: [:],
        glossarySelection: [],
        voiceProfiles: [],
        history: []
    )
}

struct HighQualityProjectManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let name: String
    let folderPath: String
    let createdAt: Date
    let updatedAt: Date
    let jobReferences: [HighQualityProjectJobReference]
    let scope: HighQualityProjectScope?
}

struct HighQualityProjectError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct HighQualityProjectEntry: Identifiable, Sendable {
    let id: UUID
    let name: String
    let folderURL: URL?
    let project: HighQualityProject?
    let errorMessage: String?
    let canLocateFolder: Bool
    fileprivate let createdAt: Date
}

struct HighQualityProjectJobReference: Codable, Equatable, Identifiable, Sendable {
    let jobID: UUID
    let source: HighQualitySourceProvenance
    let sourceRelativePath: String?
    let resultPath: String

    var id: UUID { jobID }
}

actor HighQualityProjectLifecycle {
    static let shared = HighQualityProjectLifecycle()

    private var jobs: [UUID: [UUID: Task<HighQualityJobResult, Error>]] = [:]
    private var mutations: Set<UUID> = []

    func run(
        projectID: UUID,
        operation: @escaping @Sendable () async throws -> HighQualityJobResult
    ) async throws -> HighQualityJobResult {
        guard !mutations.contains(projectID) else {
            throw HighQualityProjectError(message: "This Project is being reset or deleted.")
        }
        let token = UUID()
        let task = Task { try await operation() }
        jobs[projectID, default: [:]][token] = task
        defer {
            jobs[projectID]?[token] = nil
            if jobs[projectID]?.isEmpty == true { jobs[projectID] = nil }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func mutate<T: Sendable>(
        projectID: UUID,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        guard mutations.insert(projectID).inserted else {
            throw HighQualityProjectError(message: "This Project is already being changed.")
        }
        defer { mutations.remove(projectID) }
        let running = jobs[projectID].map { Array($0.values) } ?? []
        running.forEach { $0.cancel() }
        for task in running { _ = try? await task.value }
        return try operation()
    }
}

struct HighQualityProject: Identifiable, Sendable {
    private static let storageAnchorName = ".storage-root"

    private let requestedRoot: URL
    let directory: URL
    let manifest: HighQualityProjectManifest

    var id: UUID { manifest.id }
    var name: String { manifest.name }
    var folderURL: URL { URL(fileURLWithPath: manifest.folderPath) }
    var jobsDirectory: URL { directory.appendingPathComponent("Jobs", isDirectory: true) }
    var scope: HighQualityProjectScope { manifest.scope ?? .empty }
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
        try withMetadataLock {
            let name = try validatedName(name)
            let requestedRoot = root.standardized
            let root = try validatedProjectsRoot(requestedRoot, createIfMissing: true)
            let folder = try validatedFolder(folder, managedRoot: root)
            let id = UUID()
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let now = Date()
            let project = Self(
                requestedRoot: requestedRoot,
                directory: directory,
                manifest: .init(
                    schemaVersion: HighQualityProjectManifest.currentSchemaVersion,
                    id: id,
                    name: name,
                    folderPath: folder.path,
                    createdAt: now,
                    updatedAt: now,
                    jobReferences: [],
                    scope: .empty
                )
            )
            do {
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
    }

    static func all(
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> [Self] {
        try entries(in: root).compactMap(\.project)
    }

    static func entries(
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> [HighQualityProjectEntry] {
        try withMetadataLock {
            let requestedRoot = root.standardized
            guard let root = try existingProjectsRoot(requestedRoot) else { return [] }
            try cleanupInterruptedDirectories(in: root)
            let directories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            return directories.compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                do {
                    let project = try load(from: directory, requestedRoot: requestedRoot)
                    return HighQualityProjectEntry(
                        id: project.id,
                        name: project.name,
                        folderURL: project.folderURL,
                        project: project,
                        errorMessage: nil,
                        canLocateFolder: true,
                        createdAt: project.manifest.createdAt
                    )
                } catch {
                    return invalidEntry(id: id, from: directory, root: root, error: error)
                }
            }.sorted {
                $0.createdAt < $1.createdAt
            }
        }
    }

    static func open(
        _ id: UUID,
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> Self {
        try withMetadataLock {
            let requestedRoot = root.standardized
            let root = try validatedProjectsRoot(requestedRoot)
            return try load(
                from: root.appendingPathComponent(id.uuidString, isDirectory: true),
                requestedRoot: requestedRoot
            )
        }
    }

    func renamed(to name: String) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            return try current.updating(name: Self.validatedName(name))
        }
    }

    func relocated(to folder: URL) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            let folder = try Self.validatedFolder(
                folder,
                managedRoot: current.directory.deletingLastPathComponent()
            )
            return try Self.persistRelocation(current, to: folder)
        }
    }

    static func recoverFolder(
        for id: UUID,
        to folder: URL,
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> Self {
        try withMetadataLock {
            let requestedRoot = root.standardized
            let root = try validatedProjectsRoot(requestedRoot)
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            guard isManagedProjectDirectory(directory, in: root) else {
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
            let manifest = try decoder.decode(
                HighQualityProjectManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
            guard validMetadata(manifest, in: directory) else {
                throw HighQualityProjectError(message: "This Project metadata is unsupported.")
            }
            let folder = try validatedFolder(folder, managedRoot: root)
            try cleanupInterruptedDirectories(in: root)
            try cleanupInterruptedDirectories(
                in: directory.appendingPathComponent("Jobs", isDirectory: true)
            )
            return try persistRelocation(
                Self(
                    requestedRoot: requestedRoot,
                    directory: directory,
                    manifest: manifest
                ),
                to: folder
            )
        }
    }

    func updatingScope(_ scope: HighQualityProjectScope) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            guard Self.validScope(scope, jobIDs: Set(current.jobReferences.map(\.id))) else {
                throw HighQualityProjectError(message: "This Project scope is invalid.")
            }
            return try current.updating(scope: scope)
        }
    }

    func reset() async throws -> Self {
        try await HighQualityProjectLifecycle.shared.mutate(projectID: id) {
            try Self.withMetadataLock {
                let current = try Self.load(from: directory, requestedRoot: requestedRoot)
                let directory = current.directory
                let staging = directory.deletingLastPathComponent().appendingPathComponent(
                    ".\(id.uuidString).reset-\(UUID().uuidString)",
                    isDirectory: true
                )
                let reset = Self(
                    requestedRoot: current.requestedRoot,
                    directory: directory,
                    manifest: .init(
                        schemaVersion: HighQualityProjectManifest.currentSchemaVersion,
                        id: current.id,
                        name: current.name,
                        folderPath: current.folderURL.path,
                        createdAt: current.manifest.createdAt,
                        updatedAt: Date(),
                        jobReferences: [],
                        scope: .empty
                    )
                )
                do {
                    try FileManager.default.createDirectory(
                        at: staging,
                        withIntermediateDirectories: false
                    )
                    try FileManager.default.createDirectory(
                        at: staging.appendingPathComponent("Jobs", isDirectory: true),
                        withIntermediateDirectories: false
                    )
                    try Self.write(reset.manifest, to: staging)
                    try AtomicDirectory.swap(staging, with: directory)
                } catch {
                    do {
                        try AtomicDirectory.remove(staging)
                    } catch let cleanupError {
                        throw HighQualityProjectError(
                            message: "Could not reset the Project: \(error.localizedDescription). "
                                + "Staging cleanup also failed: "
                                + cleanupError.localizedDescription
                        )
                    }
                    throw HighQualityProjectError(
                        message: "Could not reset the Project: \(error.localizedDescription)"
                    )
                }
                do {
                    try AtomicDirectory.remove(staging)
                } catch {
                    throw HighQualityProjectError(
                        message: "The Project reset committed, but old data cleanup failed: "
                            + error.localizedDescription
                    )
                }
                return reset
            }
        }
    }

    func delete() async throws {
        try await HighQualityProjectLifecycle.shared.mutate(projectID: id) {
            try Self.withMetadataLock {
                let current = try Self.load(from: directory, requestedRoot: requestedRoot)
                do {
                    try AtomicDirectory.remove(current.directory)
                } catch {
                    throw HighQualityProjectError(
                        message: "Could not delete the Project: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func validateForJob() throws {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            if let message = current.folderRelocationMessage {
                throw HighQualityProjectError(message: message)
            }
        }
    }

    @discardableResult
    func indexJob(
        id jobID: UUID,
        source: HighQualitySourceProvenance,
        resultDirectory: URL
    ) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
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
        jobReferences: [HighQualityProjectJobReference]? = nil,
        scope: HighQualityProjectScope? = nil
    ) throws -> Self {
        let updated = updated(
            name: name,
            folder: folder,
            jobReferences: jobReferences,
            scope: scope
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

    private func updated(
        name: String? = nil,
        folder: URL? = nil,
        jobReferences: [HighQualityProjectJobReference]? = nil,
        scope: HighQualityProjectScope? = nil
    ) -> Self {
        Self(
            requestedRoot: requestedRoot,
            directory: directory,
            manifest: .init(
                schemaVersion: HighQualityProjectManifest.currentSchemaVersion,
                id: id,
                name: name ?? self.name,
                folderPath: folder?.path ?? manifest.folderPath,
                createdAt: manifest.createdAt,
                updatedAt: Date(),
                jobReferences: jobReferences ?? manifest.jobReferences,
                scope: scope ?? self.scope
            )
        )
    }

    private static func persistRelocation(_ current: Self, to folder: URL) throws -> Self {
        let updated = current.updated(folder: folder)
        do {
            try AtomicDirectory.update(current.directory) { staging in
                for reference in current.jobReferences where reference.sourceRelativePath != nil {
                    try HighQualityJob.clearRelocatedSource(
                        in: staging.appendingPathComponent(reference.resultPath)
                    )
                }
                try write(updated.manifest, to: staging)
            }
            return updated
        } catch {
            throw HighQualityProjectError(
                message: "Could not update the Project: \(error.localizedDescription)"
            )
        }
    }

    private static func load(from directory: URL, requestedRoot: URL) throws -> Self {
        do {
            let root = try validatedProjectsRoot(requestedRoot)
            guard isManagedProjectDirectory(directory, in: root) else {
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
            let directory = root.appendingPathComponent(
                directory.lastPathComponent,
                isDirectory: true
            )
            let manifest = try decoder.decode(
                HighQualityProjectManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
            let folder = try validatedFolder(
                URL(fileURLWithPath: manifest.folderPath),
                managedRoot: root,
                allowMissing: true
            )
            guard validMetadata(manifest, in: directory),
                  folder.path == manifest.folderPath else {
                throw HighQualityProjectError(message: "This Project metadata is unsupported.")
            }
            try cleanupInterruptedDirectories(in: root)
            try cleanupInterruptedDirectories(
                in: directory.appendingPathComponent("Jobs", isDirectory: true)
            )
            return Self(
                requestedRoot: requestedRoot.standardized,
                directory: directory,
                manifest: manifest
            )
        } catch let error as HighQualityProjectError {
            throw error
        } catch {
            throw HighQualityProjectError(
                message: "The Project metadata is missing or unreadable."
            )
        }
    }

    private static func invalidEntry(
        id: UUID,
        from directory: URL,
        root: URL,
        error: Error
    ) -> HighQualityProjectEntry {
        guard isManagedProjectDirectory(directory, in: root) else {
            return .init(
                id: id,
                name: "Invalid Project",
                folderURL: nil,
                project: nil,
                errorMessage: error.localizedDescription,
                canLocateFolder: false,
                createdAt: .distantPast
            )
        }
        let manifest: HighQualityProjectManifest
        do {
            manifest = try decoder.decode(
                HighQualityProjectManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("project.json"))
            )
        } catch {
            return .init(
                id: id,
                name: "Invalid Project",
                folderURL: nil,
                project: nil,
                errorMessage: "The Project metadata is missing or unreadable.",
                canLocateFolder: false,
                createdAt: .distantPast
            )
        }
        var folderIsInvalid = false
        do {
            let folder = try validatedFolder(
                URL(fileURLWithPath: manifest.folderPath),
                managedRoot: root,
                allowMissing: true
            )
            folderIsInvalid = folder.path != manifest.folderPath
        } catch {
            folderIsInvalid = true
        }
        return .init(
            id: id,
            name: manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Invalid Project" : manifest.name,
            folderURL: URL(fileURLWithPath: manifest.folderPath),
            project: nil,
            errorMessage: error.localizedDescription,
            canLocateFolder: folderIsInvalid && validMetadata(manifest, in: directory),
            createdAt: manifest.createdAt
        )
    }

    private static func validMetadata(
        _ manifest: HighQualityProjectManifest,
        in directory: URL
    ) -> Bool {
        let scope = manifest.scope ?? .empty
        return (1...HighQualityProjectManifest.currentSchemaVersion).contains(
            manifest.schemaVersion
        )
            && (manifest.schemaVersion == 1 || manifest.scope != nil)
            && directory.lastPathComponent == manifest.id.uuidString
            && !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Set(manifest.jobReferences.map(\.id)).count == manifest.jobReferences.count
            && manifest.jobReferences.allSatisfy(validReference)
            && validScope(scope, jobIDs: Set(manifest.jobReferences.map(\.id)))
    }

    private static func isManagedProjectDirectory(_ directory: URL, in root: URL) -> Bool {
        isManagedDirectory(directory)
            && isManagedDirectory(
                directory.appendingPathComponent("Jobs", isDirectory: true),
                allowMissing: true
            )
            && directory.resolvingSymlinksInPath().deletingLastPathComponent()
                == root.resolvingSymlinksInPath()
    }

    private static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw HighQualityProjectError(message: "Project name cannot be empty.")
        }
        return name
    }

    private static func validatedFolder(
        _ url: URL,
        managedRoot: URL,
        allowMissing: Bool = false
    ) throws -> URL {
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              isDirectory(folder)
                || (allowMissing && !FileManager.default.fileExists(atPath: folder.path)),
              !isInsideManagedRoot(folder, root: managedRoot),
              !isInsideManagedRoot(managedRoot, root: folder) else {
            throw HighQualityProjectError(
                message: "Choose an existing local folder outside Project storage."
            )
        }
        return folder
    }

    private static func validatedProjectsRoot(
        _ url: URL,
        createIfMissing: Bool = false
    ) throws -> URL {
        let resolved = try resolvedProjectsRoot(url)
        var root = resolved.root
        if !resolved.exists {
            guard createIfMissing else {
                throw HighQualityProjectError(message: "This Project storage is missing.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let created = try resolvedProjectsRoot(root)
            guard created.exists, created.root.path == root.path else {
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
            root = created.root
        }
        return try anchoredProjectsRoot(root, createAnchor: createIfMissing)
    }

    private static func existingProjectsRoot(_ url: URL) throws -> URL? {
        let resolved = try resolvedProjectsRoot(url)
        guard resolved.exists else { return nil }
        return try anchoredProjectsRoot(resolved.root, createAnchor: false)
    }

    private static func resolvedProjectsRoot(_ url: URL) throws -> (root: URL, exists: Bool) {
        let requested = url.standardized
        guard requested.isFileURL, requested.path != "/" else {
            throw HighQualityProjectError(message: "This Project storage is unsafe.")
        }
        let components = Array(requested.pathComponents.dropFirst())
        var root = URL(fileURLWithPath: "/", isDirectory: true)
        var exists = true
        for (offset, component) in components.enumerated() {
            let candidate = root.appendingPathComponent(component, isDirectory: true)
            guard exists else {
                root = candidate
                continue
            }
            switch try fileType(at: candidate) {
            case .typeDirectory:
                root = candidate
            case .typeSymbolicLink where offset < components.count - 1:
                root = try canonicalDirectoryTarget(of: candidate)
            case nil:
                root = candidate
                exists = false
            default:
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
        }
        return (root.standardized, exists)
    }

    private static func canonicalDirectoryTarget(
        of symlink: URL,
        depth: Int = 0
    ) throws -> URL {
        guard depth < 32 else {
            throw HighQualityProjectError(message: "This Project storage is unsafe.")
        }
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        let target = URL(
            fileURLWithPath: destination,
            relativeTo: symlink.deletingLastPathComponent()
        ).absoluteURL.standardized
        var directory = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.pathComponents.dropFirst() {
            let candidate = directory.appendingPathComponent(component, isDirectory: true)
            switch try fileType(at: candidate) {
            case .typeDirectory:
                directory = candidate
            case .typeSymbolicLink:
                directory = try canonicalDirectoryTarget(of: candidate, depth: depth + 1)
            default:
                throw HighQualityProjectError(message: "This Project storage is unsafe.")
            }
        }
        return directory
    }

    private static func anchoredProjectsRoot(
        _ root: URL,
        createAnchor: Bool
    ) throws -> URL {
        guard try fileType(at: root) == .typeDirectory else {
            throw HighQualityProjectError(message: "This Project storage is unsafe.")
        }
        let anchor = root.appendingPathComponent(storageAnchorName)
        if let anchorType = try fileType(at: anchor) {
            guard anchorType == .typeRegular,
                  String(decoding: try Data(contentsOf: anchor), as: UTF8.self) == root.path else {
                throw HighQualityProjectError(message: "This Project storage moved or changed.")
            }
        } else {
            guard createAnchor else {
                throw HighQualityProjectError(message: "This Project storage is not anchored.")
            }
            try Data(root.path.utf8).write(to: anchor, options: .atomic)
        }
        return root
    }

    private static func fileType(at url: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)[.type]
                as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw HighQualityProjectError(message: "This Project storage is unsafe.")
        }
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

    private static func validScope(
        _ scope: HighQualityProjectScope,
        jobIDs: Set<UUID>
    ) -> Bool {
        let glossary = scope.glossarySelection
        let profiles = scope.voiceProfiles
        let history = scope.history
        return scope.metadata.keys.allSatisfy(validIdentifier)
            && Set(glossary).count == glossary.count
            && glossary.allSatisfy(validIdentifier)
            && Set(profiles.map(\.id)).count == profiles.count
            && profiles.allSatisfy { profile in
                guard validIdentifier(profile.displayName),
                      let first = profile.centroids.first else { return false }
                return profile.centroids.allSatisfy { centroid in
                    validIdentifier(centroid.anonymousSpeakerID)
                        && centroid.vectorDimension == centroid.values.count
                        && centroid.vectorDimension > 0
                        && centroid.values.allSatisfy(\.isFinite)
                        && jobIDs.contains(centroid.sourceJobID)
                        && compatible(centroid, with: first)
                        && [
                            centroid.modelID,
                            centroid.modelRevision,
                            centroid.runtimeRevision,
                            centroid.embeddingVariant,
                        ].allSatisfy(validIdentifier)
                }
            }
            && Set(history.map(\.id)).count == history.count
            && history.allSatisfy {
                validIdentifier($0.action)
                    && $0.details.keys.allSatisfy(validIdentifier)
                    && $0.jobID.map(jobIDs.contains) != false
            }
    }

    private static func compatible(
        _ centroid: HighQualityProjectVoiceCentroid,
        with reference: HighQualityProjectVoiceCentroid
    ) -> Bool {
        centroid.vectorDimension == reference.vectorDimension
            && centroid.modelID == reference.modelID
            && centroid.modelRevision == reference.modelRevision
            && centroid.runtimeRevision == reference.runtimeRevision
            && centroid.embeddingVariant == reference.embeddingVariant
    }

    private static func cleanupInterruptedDirectories(in root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        for directory in directories
            where isResetDirectory(directory) || AtomicDirectory.isStagingDirectory(directory) {
            try AtomicDirectory.remove(directory)
        }
    }

    private static func isResetDirectory(_ directory: URL) -> Bool {
        let parts = directory.lastPathComponent.dropFirst().components(separatedBy: ".reset-")
        return directory.lastPathComponent.hasPrefix(".")
            && parts.count == 2
            && parts.allSatisfy { UUID(uuidString: $0) != nil }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func withMetadataLock<T>(_ operation: () throws -> T) rethrows -> T {
        try AtomicDirectory.coordinated(operation)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isManagedDirectory(_ url: URL, allowMissing: Bool = false) -> Bool {
        do {
            guard let type = try fileType(at: url) else { return allowMissing }
            return type == .typeDirectory
        } catch {
            return false
        }
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

struct HighQualityProjectWorkspace {
    let projectsRoot: URL
    let standaloneJobsRoot: URL
    private(set) var projectEntries: [HighQualityProjectEntry]
    private(set) var projectStorageError: String?
    private(set) var selectedProjectID: UUID?
    private(set) var savedResults: [HighQualitySavedResult]
    private(set) var selectedSavedResultID: UUID?
    private(set) var sourceURL: URL?
    private(set) var youtubeURL: String
    private(set) var pendingProjectAction: HighQualityProjectDestructiveAction?

    init(
        projectsRoot: URL = AppStoragePaths.highQualityProjects,
        standaloneJobsRoot: URL = AppStoragePaths.highQualityJobs
    ) {
        self.projectsRoot = projectsRoot
        self.standaloneJobsRoot = standaloneJobsRoot
        do {
            projectEntries = try HighQualityProject.entries(in: projectsRoot)
            projectStorageError = nil
        } catch {
            projectEntries = []
            projectStorageError = error.localizedDescription
        }
        selectedProjectID = nil
        savedResults = HighQualityJob.savedResults(in: standaloneJobsRoot)
        selectedSavedResultID = nil
        sourceURL = nil
        youtubeURL = ""
        pendingProjectAction = nil
    }

    var projects: [HighQualityProject] {
        projectEntries.compactMap(\.project)
    }

    var selectedProjectEntry: HighQualityProjectEntry? {
        projectEntries.first { $0.id == selectedProjectID }
    }

    var selectedProject: HighQualityProject? {
        selectedProjectEntry?.project
    }

    var selectedSavedResult: HighQualitySavedResult? {
        savedResults.first { $0.id == selectedSavedResultID }
    }

    var selectedSourceURL: URL? {
        let value = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? sourceURL : URL(string: value)
    }

    func runSelectedJob(
        deliverables: Set<HighQualityDeliverable>,
        backend: HighQualityASRBackend,
        translator: HighQualityTranslator = .productDefault,
        speakerLabels: Bool = false,
        readableSubtitles: Bool = false,
        speakerConfiguration: HighQualitySpeakerConfiguration = .standard,
        translationContextPolicy: HighQualityConversationContextPolicy = .productDefault,
        using job: HighQualityJob = HighQualityJob(),
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
    ) async throws -> HighQualityJobResult {
        if selectedProjectID != nil, selectedProject == nil {
            throw HighQualityProjectError(
                message: selectedProjectEntry?.errorMessage
                    ?? "Locate and validate this Project folder before starting a job."
            )
        }
        guard let sourceURL = selectedSourceURL else {
            throw HighQualityProjectError(message: "Select a source first.")
        }
        return try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: deliverables,
            backend: backend,
            translator: translator,
            speakerLabels: speakerLabels,
            readableSubtitles: readableSubtitles,
            speakerConfiguration: speakerConfiguration,
            translationContextPolicy: translationContextPolicy,
            project: selectedProject,
            outputRoot: standaloneJobsRoot
        ), progress: progress)
    }

    mutating func refresh() {
        do {
            projectEntries = try HighQualityProject.entries(in: projectsRoot)
            projectStorageError = nil
        } catch {
            projectEntries = []
            projectStorageError = error.localizedDescription
        }
        if let id = selectedProjectID, !projectEntries.contains(where: { $0.id == id }) {
            selectedProjectID = nil
            clearInput()
        }
        refreshSavedResults()
    }

    mutating func selectProject(_ id: UUID?) {
        selectedProjectID = id.flatMap { candidate in
            projectEntries.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        pendingProjectAction = nil
        clearInput()
        refreshSavedResults()
    }

    mutating func selectLocalSource(_ url: URL?) {
        selectedSavedResultID = nil
        sourceURL = url
        youtubeURL = ""
    }

    mutating func selectYouTube(_ value: String) {
        youtubeURL = value
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedSavedResultID = nil
        sourceURL = nil
    }

    mutating func selectSavedResult(_ id: UUID?) {
        guard let saved = savedResults.first(where: { $0.id == id }) else {
            clearInput()
            return
        }
        selectedSavedResultID = saved.id
        sourceURL = saved.sourceURL
        youtubeURL = ""
    }

    @discardableResult
    mutating func createProject(named name: String, folder: URL) throws -> HighQualityProject {
        let project = try HighQualityProject.create(named: name, folder: folder, in: projectsRoot)
        refresh()
        selectProject(project.id)
        return selectedProject ?? project
    }

    @discardableResult
    mutating func renameSelectedProject(to name: String) throws -> HighQualityProject {
        let project = try requiredSelectedProject().renamed(to: name)
        refresh()
        return selectedProject ?? project
    }

    @discardableResult
    mutating func relocateSelectedProject(to folder: URL) throws -> HighQualityProject {
        let project: HighQualityProject
        if let selectedProject {
            project = try selectedProject.relocated(to: folder)
        } else if let entry = selectedProjectEntry, entry.canLocateFolder {
            project = try HighQualityProject.recoverFolder(
                for: entry.id,
                to: folder,
                in: projectsRoot
            )
        } else {
            throw HighQualityProjectError(
                message: "This Project cannot be recovered by locating a folder."
            )
        }
        clearInput()
        refresh()
        return selectedProject ?? project
    }

    mutating func requestProjectAction(_ action: HighQualityProjectDestructiveAction) {
        guard selectedProject != nil else { return }
        pendingProjectAction = action
    }

    mutating func cancelProjectAction() {
        pendingProjectAction = nil
    }

    @discardableResult
    mutating func confirmProjectAction() async throws -> HighQualityProjectDestructiveAction {
        guard let action = pendingProjectAction else {
            throw HighQualityProjectError(message: "Choose a Project action first.")
        }
        defer { pendingProjectAction = nil }
        switch action {
        case .reset:
            _ = try await resetSelectedProject()
        case .delete:
            try await deleteSelectedProject()
        }
        return action
    }

    private mutating func resetSelectedProject() async throws -> HighQualityProject {
        let project = try await requiredSelectedProject().reset()
        clearInput()
        refresh()
        return selectedProject ?? project
    }

    private mutating func deleteSelectedProject() async throws {
        try await requiredSelectedProject().delete()
        selectedProjectID = nil
        clearInput()
        refresh()
    }

    private mutating func refreshSavedResults() {
        savedResults = selectedProjectID == nil
            ? HighQualityJob.savedResults(in: standaloneJobsRoot)
            : selectedProject?.savedResults ?? []
        if let id = selectedSavedResultID,
           !savedResults.contains(where: { $0.id == id }) {
            clearInput()
        }
    }

    private mutating func clearInput() {
        selectedSavedResultID = nil
        sourceURL = nil
        youtubeURL = ""
    }

    private func requiredSelectedProject() throws -> HighQualityProject {
        guard let selectedProject else {
            throw HighQualityProjectError(message: "Select a Project first.")
        }
        return selectedProject
    }
}
