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
                jobReferences: [],
                scope: .empty
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
        withMetadataLock {
            cleanupResetDirectories(in: root)
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return [] }
            return directories.compactMap { try? load(from: $0) }.sorted {
                $0.manifest.createdAt < $1.manifest.createdAt
            }
        }
    }

    static func open(
        _ id: UUID,
        in root: URL = AppStoragePaths.highQualityProjects
    ) throws -> Self {
        try withMetadataLock {
            cleanupResetDirectories(in: root)
            return try load(from: root.appendingPathComponent(id.uuidString, isDirectory: true))
        }
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

    func updatingScope(_ scope: HighQualityProjectScope) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory)
            guard Self.validScope(scope, jobIDs: Set(current.jobReferences.map(\.id))) else {
                throw HighQualityProjectError(message: "This Project scope is invalid.")
            }
            return try current.updating(scope: scope)
        }
    }

    func reset() throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory)
            let staging = directory.deletingLastPathComponent().appendingPathComponent(
                ".\(id.uuidString).reset-\(UUID().uuidString)",
                isDirectory: true
            )
            let reset = Self(
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
                try? FileManager.default.removeItem(at: staging)
                throw HighQualityProjectError(
                    message: "Could not reset the Project: \(error.localizedDescription)"
                )
            }
            do {
                try FileManager.default.removeItem(at: staging)
            } catch {
                Self.removeResetDirectory(staging)
            }
            return reset
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
        jobReferences: [HighQualityProjectJobReference]? = nil,
        scope: HighQualityProjectScope? = nil
    ) throws -> Self {
        let updated = Self(
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
            let scope = manifest.scope ?? .empty
            guard (1...HighQualityProjectManifest.currentSchemaVersion).contains(
                    manifest.schemaVersion
                  ),
                  (manifest.schemaVersion == 1 || manifest.scope != nil),
                  directory.lastPathComponent == manifest.id.uuidString,
                  manifest.folderPath.hasPrefix("/"),
                  !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isInsideManagedRoot(
                    URL(fileURLWithPath: manifest.folderPath),
                    root: directory.deletingLastPathComponent()
                  ),
                  Set(manifest.jobReferences.map(\.id)).count == manifest.jobReferences.count,
                  manifest.jobReferences.allSatisfy(validReference),
                  validScope(scope, jobIDs: Set(manifest.jobReferences.map(\.id))) else {
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
              !isInsideManagedRoot(folder, root: managedRoot),
              !isInsideManagedRoot(managedRoot, root: folder) else {
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

    private static func cleanupResetDirectories(in root: URL) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for directory in directories where isResetDirectory(directory) {
            removeResetDirectory(directory)
        }
    }

    private static func isResetDirectory(_ directory: URL) -> Bool {
        let parts = directory.lastPathComponent.dropFirst().components(separatedBy: ".reset-")
        return directory.lastPathComponent.hasPrefix(".")
            && parts.count == 2
            && parts.allSatisfy { UUID(uuidString: $0) != nil }
    }

    private static func removeResetDirectory(_ directory: URL) {
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) {
            for case let item as URL in enumerator
                where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink != true {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: item.path
                )
            }
        }
        try? FileManager.default.setAttributes(
            [.immutable: false],
            ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

struct HighQualityProjectWorkspace {
    let projectsRoot: URL
    let standaloneJobsRoot: URL
    private(set) var projects: [HighQualityProject]
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
        projects = HighQualityProject.all(in: projectsRoot)
        selectedProjectID = nil
        savedResults = HighQualityJob.savedResults(in: standaloneJobsRoot)
        selectedSavedResultID = nil
        sourceURL = nil
        youtubeURL = ""
        pendingProjectAction = nil
    }

    var selectedProject: HighQualityProject? {
        projects.first { $0.id == selectedProjectID }
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
        speakerConfiguration: HighQualitySpeakerConfiguration = .standard,
        translationContextPolicy: HighQualityConversationContextPolicy = .productDefault,
        using job: HighQualityJob = HighQualityJob(),
        progress: @escaping @Sendable (HighQualityJobProgress) -> Void = { _ in }
    ) async throws -> HighQualityJobResult {
        guard let sourceURL = selectedSourceURL else {
            throw HighQualityProjectError(message: "Select a source first.")
        }
        return try await job.run(.init(
            sourceURL: sourceURL,
            deliverables: deliverables,
            backend: backend,
            translator: translator,
            speakerLabels: speakerLabels,
            speakerConfiguration: speakerConfiguration,
            translationContextPolicy: translationContextPolicy,
            project: selectedProject,
            outputRoot: standaloneJobsRoot
        ), progress: progress)
    }

    mutating func refresh() {
        projects = HighQualityProject.all(in: projectsRoot)
        if let id = selectedProjectID, !projects.contains(where: { $0.id == id }) {
            selectedProjectID = nil
            clearInput()
        }
        refreshSavedResults()
    }

    mutating func selectProject(_ id: UUID?) {
        selectedProjectID = id.flatMap { candidate in
            projects.contains(where: { $0.id == candidate }) ? candidate : nil
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
        let project = try requiredSelectedProject().relocated(to: folder)
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
    mutating func confirmProjectAction() throws -> HighQualityProjectDestructiveAction {
        guard let action = pendingProjectAction else {
            throw HighQualityProjectError(message: "Choose a Project action first.")
        }
        defer { pendingProjectAction = nil }
        switch action {
        case .reset:
            _ = try resetSelectedProject()
        case .delete:
            try deleteSelectedProject()
        }
        return action
    }

    private mutating func resetSelectedProject() throws -> HighQualityProject {
        let project = try requiredSelectedProject().reset()
        clearInput()
        refresh()
        return selectedProject ?? project
    }

    private mutating func deleteSelectedProject() throws {
        try requiredSelectedProject().delete()
        selectedProjectID = nil
        clearInput()
        refresh()
    }

    private mutating func refreshSavedResults() {
        savedResults = selectedProject?.savedResults
            ?? HighQualityJob.savedResults(in: standaloneJobsRoot)
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
