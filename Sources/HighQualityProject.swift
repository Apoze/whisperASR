import CryptoKit
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

    fileprivate var sourceKey: String { "\(sourceJobID.uuidString)/\(anonymousSpeakerID)" }

    var compatibilitySignature: HighQualitySpeakerCentroidSignature {
        .init(
            modelID: modelID,
            modelRevision: modelRevision,
            runtimeRevision: runtimeRevision,
            embeddingVariant: embeddingVariant,
            vectorDimension: vectorDimension
        )
    }
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

struct HighQualityRecurringVoiceSuggestion: Equatable, Identifiable, Sendable {
    static let betaDescription = "Project-local acoustic similarity only; uncertain voices stay "
        + "Unknown. A suggestion is not proof of a person, actor or character."

    let speakerLabel: String
    let profileID: UUID
    let displayName: String
    let cosineDistance: Float

    var id: String { "\(speakerLabel)/\(profileID.uuidString)" }
}

struct HighQualityRecurringVoiceEvaluation: Equatable, Sendable {
    let suggestions: [HighQualityRecurringVoiceSuggestion]
    let unknownSpeakerLabels: [String]
    let confirmableSpeakerLabels: [String]
    let profileIncompatibilities: [HighQualityVoiceProfileIncompatibility]

    static let empty = Self(
        suggestions: [],
        unknownSpeakerLabels: [],
        confirmableSpeakerLabels: [],
        profileIncompatibilities: []
    )
}

struct HighQualityVoiceProfileIncompatibility: Equatable, Identifiable, Sendable {
    let profileID: UUID
    let displayName: String
    let causes: [HighQualitySpeakerCentroidIncompatibilityCause]
    let sourceJobIDs: [UUID]

    var id: UUID { profileID }
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
    let voiceMemoryEnabled: Bool
    let voiceProfiles: [HighQualityProjectVoiceProfile]
    let history: [HighQualityProjectHistoryEntry]

    init(
        metadata: [String: String],
        glossarySelection: [String],
        voiceMemoryEnabled: Bool = false,
        voiceProfiles: [HighQualityProjectVoiceProfile],
        history: [HighQualityProjectHistoryEntry]
    ) {
        self.metadata = metadata
        self.glossarySelection = glossarySelection
        self.voiceMemoryEnabled = voiceMemoryEnabled
        self.voiceProfiles = voiceProfiles
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, glossarySelection, voiceMemoryEnabled, voiceProfiles, history
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try values.decode([String: String].self, forKey: .metadata)
        glossarySelection = try values.decode([String].self, forKey: .glossarySelection)
        voiceMemoryEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .voiceMemoryEnabled
        ) ?? false
        voiceProfiles = try values.decode(
            [HighQualityProjectVoiceProfile].self,
            forKey: .voiceProfiles
        )
        history = try values.decode([HighQualityProjectHistoryEntry].self, forKey: .history)
    }

    static let empty = Self(
        metadata: [:],
        glossarySelection: [],
        voiceMemoryEnabled: false,
        voiceProfiles: [],
        history: []
    )

    fileprivate func replacing(
        voiceMemoryEnabled: Bool? = nil,
        voiceProfiles: [HighQualityProjectVoiceProfile]? = nil,
        history: [HighQualityProjectHistoryEntry]? = nil
    ) -> Self {
        .init(
            metadata: metadata,
            glossarySelection: glossarySelection,
            voiceMemoryEnabled: voiceMemoryEnabled ?? self.voiceMemoryEnabled,
            voiceProfiles: voiceProfiles ?? self.voiceProfiles,
            history: history ?? self.history
        )
    }
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

    func settingVoiceMemory(enabled: Bool) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            return try current.updating(scope: current.scope.replacing(
                voiceMemoryEnabled: enabled
            ))
        }
    }

    func recurringVoiceEvaluation(
        for result: HighQualityJobResult
    ) -> HighQualityRecurringVoiceEvaluation {
        guard scope.voiceMemoryEnabled,
              owns(result),
              let centroidsBySpeaker = HighQualityJob.projectVoiceCentroids(in: result),
              !centroidsBySpeaker.isEmpty else { return .empty }
        let anonymousLabels = Set(centroidsBySpeaker.keys.filter { label in
            result.editableSpeakerNames[label] == label
        })
        let evaluation = Self.recurringVoiceEvaluation(
            centroidsBySpeaker: centroidsBySpeaker,
            anonymousSpeakerLabels: anonymousLabels,
            profiles: scope.voiceProfiles
        )
        let retained = evaluation.suggestions.filter { suggestion in
            guard let centroids = centroidsBySpeaker[suggestion.speakerLabel] else {
                return false
            }
            return !scope.history.contains { entry in
                entry.action == "recurring-voice-rejected"
                    && entry.jobID == result.manifest.jobID
                    && entry.details["profileID"] == suggestion.profileID.uuidString
                    && entry.details["speakerLabel"] == suggestion.speakerLabel
                    && entry.details["evidenceFingerprint"]
                        == Self.voiceEvidenceFingerprint(centroids)
            }
        }
        let rejectedLabels = Set(evaluation.suggestions.map(\.speakerLabel))
            .subtracting(retained.map(\.speakerLabel))
        let existing = Set(scope.voiceProfiles.flatMap(\.centroids).map(\.sourceKey))
        let confirmable = centroidsBySpeaker.keys.filter { label in
            guard result.editableSpeakerNames[label] != label,
                  let centroids = centroidsBySpeaker[label] else { return false }
            return centroids.map(Self.projectCentroid).allSatisfy {
                !existing.contains($0.sourceKey)
            }
        }.sorted()
        return .init(
            suggestions: retained,
            unknownSpeakerLabels: Set(evaluation.unknownSpeakerLabels)
                .union(rejectedLabels).sorted(),
            confirmableSpeakerLabels: confirmable,
            profileIncompatibilities: evaluation.profileIncompatibilities
        )
    }

    static func recurringVoiceEvaluation(
        centroidsBySpeaker: [String: [HighQualitySpeakerCentroidEvidence]],
        anonymousSpeakerLabels: Set<String>,
        profiles: [HighQualityProjectVoiceProfile]
    ) -> HighQualityRecurringVoiceEvaluation {
        let currentSignatures = centroidsBySpeaker.values.joined().map(\.compatibilitySignature)
        let incompatibilities: [HighQualityVoiceProfileIncompatibility] = profiles.compactMap {
            profile in
            guard let profileSignature = profile.centroids.first?.compatibilitySignature,
                  !currentSignatures.isEmpty,
                  !currentSignatures.contains(profileSignature) else { return nil }
            let causes = currentSignatures.flatMap {
                profileSignature.incompatibilityCauses(comparedWith: $0)
            }.reduce(into: [HighQualitySpeakerCentroidIncompatibilityCause]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            return HighQualityVoiceProfileIncompatibility(
                profileID: profile.id,
                displayName: profile.displayName,
                causes: causes,
                sourceJobIDs: Array(Set(profile.centroids.map(\.sourceJobID))).sorted {
                    $0.uuidString < $1.uuidString
                }
            )
        }.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        let anonymous = centroidsBySpeaker.filter {
            anonymousSpeakerLabels.contains($0.key)
        }

        struct Comparison {
            let speakerLabel: String
            let profile: HighQualityProjectVoiceProfile
            let distance: Float
        }
        var comparisons: [Comparison] = []
        for (speakerLabel, speakerCentroids) in anonymous {
            for profile in profiles {
                guard let first = profile.centroids.first,
                      speakerCentroids.allSatisfy({
                          $0.compatibilitySignature == first.compatibilitySignature
                      }), let currentVector = Self.average(
                        speakerCentroids.map(\.vector)
                      ), let profileVector = Self.average(profile.centroids.map(\.values)),
                      let distance = HighQualityJob.cosineDistance(
                        currentVector,
                        profileVector
                      ) else { continue }
                comparisons.append(.init(
                    speakerLabel: speakerLabel,
                    profile: profile,
                    distance: distance
                ))
            }
        }
        func isUnambiguous(_ comparison: Comparison, key: (Comparison) -> String) -> Bool {
            let ranked = comparisons.filter {
                key($0) == key(comparison)
            }.sorted {
                ($0.distance, $0.speakerLabel, $0.profile.id.uuidString)
                    < ($1.distance, $1.speakerLabel, $1.profile.id.uuidString)
            }
            guard let nearest = ranked.first,
                  nearest.speakerLabel == comparison.speakerLabel,
                  nearest.profile.id == comparison.profile.id else { return false }
            return ranked.count == 1
                || ranked[1].distance - comparison.distance
                    >= HighQualityDuplicateSpeakerSuggestion.uncertaintyMargin
        }
        let suggestions: [HighQualityRecurringVoiceSuggestion] = comparisons.compactMap {
            comparison in
            guard comparison.distance
                    <= HighQualityDuplicateSpeakerSuggestion.maximumCosineDistance,
                  isUnambiguous(comparison, key: { $0.speakerLabel }),
                  isUnambiguous(comparison, key: { $0.profile.id.uuidString }) else { return nil }
            return HighQualityRecurringVoiceSuggestion(
                speakerLabel: comparison.speakerLabel,
                profileID: comparison.profile.id,
                displayName: comparison.profile.displayName,
                cosineDistance: comparison.distance
            )
        }.sorted {
            ($0.cosineDistance, $0.speakerLabel, $0.profileID.uuidString)
                < ($1.cosineDistance, $1.speakerLabel, $1.profileID.uuidString)
        }
        let suggestedLabels = Set(suggestions.map(\.speakerLabel))
        return .init(
            suggestions: suggestions,
            unknownSpeakerLabels: anonymous.keys.filter {
                !suggestedLabels.contains($0)
            }.sorted(),
            confirmableSpeakerLabels: [],
            profileIncompatibilities: incompatibilities
        )
    }

    func confirmVoiceProfile(
        from result: HighQualityJobResult,
        speakerLabel: String
    ) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            let centroids = try current.validatedVoiceCentroids(
                from: result,
                speakerLabel: speakerLabel
            )
            guard let displayName = result.editableSpeakerNames[speakerLabel],
                  displayName != speakerLabel else {
                throw HighQualityProjectError(
                    message: "Name this Speaker before creating a Voice profile."
                )
            }
            let stored = centroids.map(Self.projectCentroid)
            let keys = Set(current.scope.voiceProfiles.flatMap(\.centroids).map(\.sourceKey))
            guard stored.allSatisfy({ !keys.contains($0.sourceKey) }) else {
                throw HighQualityProjectError(
                    message: "This confirmed Speaker is already stored in a Voice profile."
                )
            }
            let profile = HighQualityProjectVoiceProfile(
                id: UUID(),
                displayName: displayName,
                centroids: stored
            )
            return try current.persistVoiceScope(
                profiles: current.scope.voiceProfiles + [profile],
                history: current.scope.history + [Self.history(
                    "voice-profile-created",
                    jobID: result.manifest.jobID,
                    details: [
                        "profileID": profile.id.uuidString,
                        "speakerLabel": speakerLabel,
                    ]
                )]
            )
        }
    }

    func acceptRecurringVoice(
        _ suggestion: HighQualityRecurringVoiceSuggestion,
        from result: HighQualityJobResult,
        beforeResultCommit: () throws -> Void = {}
    ) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            let fresh = try current.validatedRecurringSuggestion(suggestion, from: result)
            guard let persistedResult = HighQualityJob.persistedResultMatchingVoiceProvenance(
                result
            ) else {
                throw HighQualityProjectError(
                    message: "This Speaker result changed. Reopen it and try again."
                )
            }
            let centroids = try current.validatedVoiceCentroids(
                from: result,
                speakerLabel: fresh.speakerLabel
            )
            var profiles = current.scope.voiceProfiles
            guard let index = profiles.firstIndex(where: { $0.id == fresh.profileID }),
                  let first = profiles[index].centroids.first else {
                throw HighQualityProjectError(
                    message: "This Voice profile requires recomputation."
                )
            }
            let stored = centroids.map(Self.projectCentroid)
            guard stored.allSatisfy({
                $0.compatibilitySignature == first.compatibilitySignature
            }) else {
                throw HighQualityProjectError(
                    message: "This Voice profile requires recomputation."
                )
            }
            let existing = Set(profiles[index].centroids.map(\.sourceKey))
            profiles[index] = .init(
                id: profiles[index].id,
                displayName: profiles[index].displayName,
                centroids: profiles[index].centroids + stored.filter {
                    !existing.contains($0.sourceKey)
                }
            )
            let history = current.scope.history + [Self.history(
                "recurring-voice-accepted",
                jobID: result.manifest.jobID,
                details: [
                    "profileID": fresh.profileID.uuidString,
                    "speakerLabel": fresh.speakerLabel,
                    "evidenceFingerprint": Self.voiceEvidenceFingerprint(centroids),
                ]
            )]
            let updated = current.updated(scope: current.scope.replacing(
                voiceProfiles: profiles,
                history: history
            ))
            guard Self.validScope(
                updated.scope,
                jobIDs: Set(updated.jobReferences.map(\.id))
            ) else {
                throw HighQualityProjectError(message: "This Voice profile is invalid.")
            }
            try AtomicDirectory.update(current.directory) { staging in
                try Self.write(updated.manifest, to: staging)
                try beforeResultCommit()
                let stagedDirectory = staging.appendingPathComponent(
                    "Jobs/\(result.manifest.jobID.uuidString)",
                    isDirectory: true
                )
                let stagedResult = Self.result(persistedResult, relocatedTo: stagedDirectory)
                _ = try HighQualityJob.editSpeakers(
                    in: stagedResult,
                    edit: .rename(fresh.speakerLabel, to: fresh.displayName)
                )
            }
            return updated
        }
    }

    func rejectRecurringVoice(
        _ suggestion: HighQualityRecurringVoiceSuggestion,
        from result: HighQualityJobResult
    ) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            let fresh = try current.validatedRecurringSuggestion(suggestion, from: result)
            let centroids = try current.validatedVoiceCentroids(
                from: result,
                speakerLabel: fresh.speakerLabel
            )
            return try current.persistVoiceScope(
                profiles: current.scope.voiceProfiles,
                history: current.scope.history + [Self.history(
                    "recurring-voice-rejected",
                    jobID: result.manifest.jobID,
                    details: [
                        "profileID": fresh.profileID.uuidString,
                        "speakerLabel": fresh.speakerLabel,
                        "evidenceFingerprint": Self.voiceEvidenceFingerprint(centroids),
                    ]
                )]
            )
        }
    }

    func mergeVoiceProfile(_ sourceID: UUID, into targetID: UUID) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            guard sourceID != targetID,
                  let source = current.scope.voiceProfiles.first(where: { $0.id == sourceID }),
                  let targetIndex = current.scope.voiceProfiles.firstIndex(
                    where: { $0.id == targetID }
                  ), let targetFirst = current.scope.voiceProfiles[targetIndex].centroids.first,
                  source.centroids.allSatisfy({
                      $0.compatibilitySignature == targetFirst.compatibilitySignature
                  }) else {
                throw HighQualityProjectError(
                    message: "These Voice profiles are missing or require recomputation before merging."
                )
            }
            var profiles = current.scope.voiceProfiles
            var target = profiles[targetIndex]
            let existing = Set(target.centroids.map(\.sourceKey))
            target = .init(
                id: target.id,
                displayName: target.displayName,
                centroids: target.centroids + source.centroids.filter {
                    !existing.contains($0.sourceKey)
                }
            )
            profiles[targetIndex] = target
            profiles.removeAll { $0.id == sourceID }
            return try current.persistVoiceScope(
                profiles: profiles,
                history: current.scope.history + [Self.history(
                    "voice-profiles-merged",
                    details: [
                        "sourceProfileID": sourceID.uuidString,
                        "targetProfileID": targetID.uuidString,
                    ]
                )]
            )
        }
    }

    func forgetVoiceProfile(_ profileID: UUID) throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            guard current.scope.voiceProfiles.contains(where: { $0.id == profileID }) else {
                throw HighQualityProjectError(message: "This Voice profile no longer exists.")
            }
            return try current.persistVoiceScope(
                profiles: current.scope.voiceProfiles.filter { $0.id != profileID },
                history: current.scope.history + [Self.history(
                    "voice-profile-forgotten",
                    details: ["profileID": profileID.uuidString]
                )]
            )
        }
    }

    func resetVoiceProfiles() throws -> Self {
        try Self.withMetadataLock {
            let current = try Self.load(from: directory, requestedRoot: requestedRoot)
            return try current.persistVoiceScope(
                profiles: [],
                history: current.scope.history + [Self.history("voice-profiles-reset")]
            )
        }
    }

    private func validatedRecurringSuggestion(
        _ suggestion: HighQualityRecurringVoiceSuggestion,
        from result: HighQualityJobResult
    ) throws -> HighQualityRecurringVoiceSuggestion {
        guard let fresh = recurringVoiceEvaluation(for: result).suggestions.first(
            where: {
                $0.speakerLabel == suggestion.speakerLabel
                    && $0.profileID == suggestion.profileID
            }
        ) else {
            throw HighQualityProjectError(
                message: "This recurring Voice suggestion is no longer valid."
            )
        }
        return fresh
    }

    private func validatedVoiceCentroids(
        from result: HighQualityJobResult,
        speakerLabel: String
    ) throws -> [HighQualitySpeakerCentroidEvidence] {
        guard scope.voiceMemoryEnabled else {
            throw HighQualityProjectError(message: "Enable Project Voice memory first.")
        }
        guard owns(result) else {
            throw HighQualityProjectError(
                message: "This Speaker result does not belong to this Project."
            )
        }
        guard let centroids = HighQualityJob.projectVoiceCentroids(in: result)?[speakerLabel],
              !centroids.isEmpty else {
            throw HighQualityProjectError(
                message: "This Speaker has no compatible centroid to remember."
            )
        }
        return centroids
    }

    private func owns(_ result: HighQualityJobResult) -> Bool {
        guard result.manifest.projectID == id,
              let reference = jobReferences.first(where: {
                  $0.jobID == result.manifest.jobID
              }), result.directory.standardizedFileURL
                == directory.appendingPathComponent(reference.resultPath).standardizedFileURL else {
            return false
        }
        return HighQualityJob.persistedResultMatchingVoiceProvenance(result) != nil
    }

    private func persistVoiceScope(
        profiles: [HighQualityProjectVoiceProfile],
        history: [HighQualityProjectHistoryEntry]
    ) throws -> Self {
        try updating(scope: scope.replacing(voiceProfiles: profiles, history: history))
    }

    private static func projectCentroid(
        _ centroid: HighQualitySpeakerCentroidEvidence
    ) -> HighQualityProjectVoiceCentroid {
        .init(
            anonymousSpeakerID: centroid.speakerLabel,
            vectorDimension: centroid.vectorDimension,
            values: centroid.vector,
            modelID: centroid.modelID,
            modelRevision: centroid.modelRevision,
            runtimeRevision: centroid.runtimeRevision,
            embeddingVariant: centroid.embeddingVariant,
            sourceJobID: centroid.sourceJobID
        )
    }

    private static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first,
              !first.isEmpty,
              vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var average = Array(repeating: Float.zero, count: first.count)
        for vector in vectors {
            for index in vector.indices {
                average[index] += vector[index] / Float(vectors.count)
            }
        }
        return average.allSatisfy(\.isFinite) ? average : nil
    }

    private static func voiceEvidenceFingerprint(
        _ centroids: [HighQualitySpeakerCentroidEvidence]
    ) -> String {
        let payload = centroids.sorted { $0.speakerLabel < $1.speakerLabel }.map { centroid in
            [
                centroid.sourceJobID.uuidString,
                centroid.speakerLabel,
                centroid.modelID,
                centroid.modelRevision,
                centroid.runtimeRevision,
                centroid.embeddingVariant,
                String(centroid.vectorDimension),
                centroid.vector.map { String($0.bitPattern, radix: 16) }.joined(separator: ","),
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func result(
        _ result: HighQualityJobResult,
        relocatedTo directory: URL
    ) -> HighQualityJobResult {
        HighQualityJobResult(
            directory: directory,
            japaneseTranscript: result.japaneseTranscript,
            englishTranscript: result.englishTranscript,
            turns: result.turns,
            subtitleCues: result.subtitleCues,
            manifest: result.manifest,
            evidence: result.evidence,
            speakerReanalysisCompletion: result.speakerReanalysisCompletion
        )
    }

    private static func history(
        _ action: String,
        jobID: UUID? = nil,
        details: [String: String] = [:]
    ) -> HighQualityProjectHistoryEntry {
        .init(id: UUID(), action: action, createdAt: Date(), jobID: jobID, details: details)
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
                        && centroid.compatibilitySignature == first.compatibilitySignature
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
