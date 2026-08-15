import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HighQualitySpeakerBetaControls: Equatable {
    var includeLabels = false
    var isExpanded = false
    var enhancedPrecision = false
    var sensitiveDetection = false
    var knowsSpeakerCount = false
    var expectedSpeakerCount = 2

    var showsAdvancedSettings: Bool { includeLabels }
    var showsExpectedCount: Bool { showsAdvancedSettings && knowsSpeakerCount }
    var configuration: HighQualitySpeakerConfiguration {
        guard includeLabels else { return .standard }
        return .init(
            enhancedPrecision: enhancedPrecision,
            sensitiveDetection: sensitiveDetection,
            countPolicy: knowsSpeakerCount ? .expected(expectedSpeakerCount) : .automatic
        )
    }
}

struct HighQualityJobView: View {
    @State private var sourceURL: URL?
    @State private var youtubeURL = ""
    @State private var includeJapaneseTranscript = true
    @State private var includeEnglishTranscript = false
    @State private var includeEnglishSubtitles = false
    @State private var speakerBeta = HighQualitySpeakerBetaControls()
    @State private var backend: HighQualityASRBackend? = .productDefault
    @State private var translator: HighQualityTranslator = .productDefault
    @State private var progress = HighQualityJobProgress(
        stage: .validating,
        fraction: 0,
        message: "Choose a local audio or video file."
    )
    @State private var result: HighQualityJobResult?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var customSpeakerLabels: [String: String] = [:]
    @State private var savedResults: [HighQualitySavedResult] = []
    @State private var selectedSavedResultID: UUID?
    @State private var projects: [HighQualityProject] = []
    @State private var selectedProjectID: UUID?
    @State private var projectName = ""
    @State private var isRenamingProject = false
    @State private var showsDeleteProjectConfirmation = false

    private var isRunning: Bool { task != nil }
    private var canStart: Bool {
        (sourceURL != nil || !youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (includeJapaneseTranscript || includeEnglishTranscript || includeEnglishSubtitles)
            && backend != nil
            && !isRunning
            && selectedProject?.folderRelocationMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("High-quality transcript")
                .font(.title2.bold())

            HStack {
                Picker("Project", selection: $selectedProjectID) {
                    Text("Standalone").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .disabled(isRunning)
                .accessibilityIdentifier("high-quality-project")
                .onChange(of: selectedProjectID) { _, _ in selectProject() }

                Button("New Project…", action: createProject)
                    .disabled(isRunning)
                    .accessibilityIdentifier("high-quality-new-project")

                if let project = selectedProject {
                    Button("Open Folder") { NSWorkspace.shared.open(project.folderURL) }
                        .disabled(project.folderRelocationMessage != nil)
                    Menu("Project Actions") {
                        Button("Rename…") {
                            projectName = project.name
                            isRenamingProject = true
                        }
                        Button("Locate Folder…") { locateFolder(for: project) }
                        Divider()
                        Button("Delete Project…", role: .destructive) {
                            showsDeleteProjectConfirmation = true
                        }
                    }
                    .disabled(isRunning)
                    .accessibilityIdentifier("high-quality-project-actions")
                }
            }

            if let project = selectedProject {
                Text(project.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Only files you explicitly choose are processed; source media stays in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = project.folderRelocationMessage {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Button("Locate Project Folder…") { locateFolder(for: project) }
                            .accessibilityIdentifier("high-quality-locate-project-folder")
                    }
                }
            }

            if !savedResults.isEmpty {
                Picker("Saved result", selection: $selectedSavedResultID) {
                    Text("New High-quality job").tag(nil as UUID?)
                    ForEach(savedResults) { saved in
                        Text(saved.sourceURL.lastPathComponent).tag(Optional(saved.id))
                    }
                }
                .disabled(isRunning)
                .accessibilityIdentifier("high-quality-saved-result")
                .onChange(of: selectedSavedResultID) { _, id in
                    reopenSavedResult(id)
                }
            }

            sourcePicker

            TextField("Public YouTube video URL", text: $youtubeURL)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
                .onChange(of: youtubeURL) { _, value in
                    guard !value.isEmpty else { return }
                    selectedSavedResultID = nil
                    sourceURL = nil
                    result = nil
                    errorMessage = nil
                }

            Toggle("Japanese transcript", isOn: $includeJapaneseTranscript)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("English translation transcript", isOn: $includeEnglishTranscript)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("English WebVTT and SRT subtitles", isOn: $includeEnglishSubtitles)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("Speaker labels", isOn: $speakerBeta.includeLabels)
                .toggleStyle(.checkbox)
                .disabled(isRunning)

            if includeEnglishTranscript || includeEnglishSubtitles {
                Picker("Local translator", selection: $translator) {
                    ForEach(HighQualityTranslator.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(isRunning)
                Text(translator.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if speakerBeta.showsAdvancedSettings {
                DisclosureGroup(
                    "Réglages avancés (Bêta)",
                    isExpanded: $speakerBeta.isExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Précision renforcée", isOn: $speakerBeta.enhancedPrecision)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("speaker-beta-enhanced-precision")
                            .accessibilityHint("Analyse des locuteurs environ 30 % plus lente.")
                        Text("Modèles haute précision. Analyse environ 30 % plus lente.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Détection plus sensible", isOn: $speakerBeta.sensitiveDetection)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("speaker-beta-sensitive-detection")
                            .accessibilityHint("Peut mieux séparer des voix proches.")
                        Text("Peut mieux séparer des voix proches. Ajoute quelques secondes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Nombre de locuteurs", selection: $speakerBeta.knowsSpeakerCount) {
                            Text("Auto").tag(false)
                            Text("Je le connais (Bêta)").tag(true)
                        }
                        .accessibilityIdentifier("speaker-beta-speaker-count-mode")
                        .accessibilityHint("Auto, ou nombre exact si vous le connaissez.")
                        if speakerBeta.showsExpectedCount {
                            Stepper(
                                "Nombre exact : \(speakerBeta.expectedSpeakerCount)",
                                value: $speakerBeta.expectedSpeakerCount,
                                in: HighQualitySpeakerCountPolicy.validExpectedCounts
                            )
                            .accessibilityIdentifier("speaker-beta-expected-speaker-count")
                            Text("À utiliser seulement si vous connaissez le nombre exact.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                    .disabled(isRunning)
                }
                .accessibilityIdentifier("speaker-beta-settings")
            }

            Picker("Japanese ASR", selection: $backend) {
                Text("Choose a backend…").tag(nil as HighQualityASRBackend?)
                ForEach(HighQualityASRBackend.allCases) {
                    Text($0.displayName).tag(Optional($0))
                }
            }
            .disabled(isRunning)

            HStack {
                if isRunning {
                    Button("Cancel", role: .cancel) { task?.cancel() }
                } else {
                    Button("Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                }

                if let result {
                    Button("Open Results Folder") {
                        NSWorkspace.shared.open(result.directory)
                    }
                }
            }

            ProgressView(value: progress.fraction)
            Text(progress.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let saved = selectedSavedResult,
               let message = saved.sourceRelocationMessage {
                HStack(alignment: .firstTextBaseline) {
                    Text(message)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    if saved.manifest.source.youtube == nil {
                        Button("Locate Source…") { locateSource(for: saved) }
                            .accessibilityIdentifier("high-quality-locate-source")
                    }
                }
            }

            if let result {
                Divider()
                resultView(result)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .onAppear {
            refreshProjects()
            refreshSavedResults()
        }
        .onDisappear { task?.cancel() }
        .alert("Rename Project", isPresented: $isRenamingProject) {
            TextField("Project name", text: $projectName)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: renameProject)
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: $showsDeleteProjectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive, action: deleteProject)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only this Project and its saved results. Source media is not deleted.")
        }
    }

    private var selectedProject: HighQualityProject? {
        projects.first { $0.id == selectedProjectID }
    }

    private var selectedSavedResult: HighQualitySavedResult? {
        savedResults.first { $0.id == selectedSavedResultID }
    }

    private var sourcePicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceURL?.lastPathComponent ?? "Drop a local audio or video file here")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sourceURL {
                    Text(sourceURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button("Choose File…", action: chooseFile)
                .disabled(isRunning)
        }
        .padding(16)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : .secondary.opacity(0.3))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.directoryURL = selectedProject?.folderURL
        panel.begin { response in
            guard response == .OK else { return }
            selectLocalSource(panel.url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
              }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                selectLocalSource(url)
            }
        }
        return true
    }

    private func selectLocalSource(_ url: URL?) {
        selectedSavedResultID = nil
        sourceURL = url
        youtubeURL = ""
        result = nil
        errorMessage = nil
    }

    private func start() {
        let value = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSource = value.isEmpty ? sourceURL : URL(string: value)
        var deliverables: Set<HighQualityDeliverable> = []
        if includeJapaneseTranscript { deliverables.insert(.japaneseTranscript) }
        if includeEnglishTranscript { deliverables.insert(.englishTranslationTranscript) }
        if includeEnglishSubtitles { deliverables.insert(.englishSubtitles) }
        guard let selectedSource, let backend, !deliverables.isEmpty else {
            errorMessage = "Select a source and at least one Deliverable."
            return
        }
        selectedSavedResultID = nil
        result = nil
        errorMessage = nil
        progress = .init(stage: .validating, fraction: 0, message: "Starting…")
        let job = HighQualityJob()
        task = Task {
            do {
                let completed = try await job.run(.init(
                    sourceURL: selectedSource,
                    deliverables: deliverables,
                    backend: backend,
                    translator: translator,
                    speakerLabels: speakerBeta.includeLabels,
                    speakerConfiguration: speakerBeta.configuration,
                    translationContextPolicy: .productDefault,
                    project: selectedProject
                )) { update in
                    Task { @MainActor in progress = update }
                }
                result = completed
                customSpeakerLabels = initialCustomSpeakerLabels(for: completed)
                refreshSavedResults()
                selectedSavedResultID = completed.manifest.jobID
            } catch let error as HighQualityJobError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }

    private func refreshSavedResults() {
        savedResults = selectedProject?.savedResults ?? HighQualityJob.savedResults()
    }

    private func refreshProjects() {
        projects = HighQualityProject.all()
        if let id = selectedProjectID, !projects.contains(where: { $0.id == id }) {
            selectedProjectID = nil
        }
    }

    private func selectProject() {
        guard !isRunning else { return }
        selectedSavedResultID = nil
        sourceURL = nil
        youtubeURL = ""
        result = nil
        errorMessage = nil
        customSpeakerLabels = [:]
        refreshSavedResults()
    }

    private func createProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Create Project"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                let project = try HighQualityProject.create(
                    named: folder.lastPathComponent,
                    folder: folder
                )
                refreshProjects()
                selectedProjectID = project.id
                selectProject()
                progress = .init(
                    stage: .validating,
                    fraction: 0,
                    message: "Project created. Choose a source explicitly."
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renameProject() {
        guard let project = selectedProject else { return }
        do {
            _ = try project.renamed(to: projectName)
            refreshProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateFolder(for project: HighQualityProject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Locate Project Folder"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                _ = try project.relocated(to: folder)
                refreshProjects()
                selectedProjectID = project.id
                refreshSavedResults()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteProject() {
        guard let project = selectedProject else { return }
        do {
            try project.delete()
            selectedProjectID = nil
            refreshProjects()
            selectProject()
            progress = .init(stage: .validating, fraction: 0, message: "Project deleted")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reopenSavedResult(_ id: UUID?) {
        guard let id else {
            guard !isRunning else { return }
            result = nil
            errorMessage = nil
            customSpeakerLabels = [:]
            return
        }
        guard let saved = savedResults.first(where: { $0.id == id }) else { return }
        do {
            try showSavedResult(saved)
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }

    private func locateSource(for saved: HighQualitySavedResult) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let relocated = try HighQualityJob.relocateSource(saved, to: url)
                refreshSavedResults()
                selectedSavedResultID = relocated.id
                try showSavedResult(
                    savedResults.first(where: { $0.id == relocated.id }) ?? relocated
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showSavedResult(_ saved: HighQualitySavedResult) throws {
        let reopened = try HighQualityJob.reopen(saved)
        let deliverables = Set(reopened.manifest.deliverables)
        sourceURL = saved.sourceURL
        youtubeURL = ""
        includeJapaneseTranscript = deliverables.contains(.japaneseTranscript)
        includeEnglishTranscript = deliverables.contains(.englishTranslationTranscript)
        includeEnglishSubtitles = deliverables.contains(.englishSubtitles)
        speakerBeta.includeLabels = reopened.manifest.speakerLabels
        backend = reopened.manifest.selectedBackend
        if let savedTranslator = reopened.manifest.translationModel?.translator {
            translator = savedTranslator
        }
        result = reopened
        errorMessage = nil
        progress = .init(stage: .completed, fraction: 1, message: "Saved result reopened")
        customSpeakerLabels = initialCustomSpeakerLabels(for: reopened)
    }

    private func initialCustomSpeakerLabels(
        for result: HighQualityJobResult
    ) -> [String: String] {
        result.turns.reduce(into: [:]) { names, turn in
            if let label = turn.speakerLabel {
                names[label] = turn.speakerName ?? label
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: HighQualityJobResult) -> some View {
        let deliverables = Set(result.manifest.deliverables)
        if result.manifest.speakerLabels {
            speakerResultView(result, deliverables: deliverables)
        } else if deliverables == [.japaneseTranscript] {
            Text("Japanese result").font(.headline)
            ScrollView {
                Text(result.japaneseTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else if deliverables == [.englishTranslationTranscript] {
            Text("English result").font(.headline)
            ScrollView {
                Text(result.englishTranscript ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else {
            Text("Japanese / English result").font(.headline)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Japanese").bold()
                        Text("English").bold()
                    }
                    Divider().gridCellColumns(2)
                    ForEach(result.turns, id: \.id) { turn in
                        GridRow(alignment: .top) {
                            Text(turn.japanese)
                            Text(turn.english ?? "")
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func speakerResultView(
        _ result: HighQualityJobResult,
        deliverables: Set<HighQualityDeliverable>
    ) -> some View {
        Text("Results").font(.headline)
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Time").bold()
                    Text("Speaker").bold()
                    Text("Japanese").bold()
                    if deliverables.contains(.englishTranslationTranscript)
                        || deliverables.contains(.englishSubtitles) {
                        Text("English").bold()
                    }
                }
                ForEach(result.turns, id: \.id) { turn in
                    GridRow(alignment: .top) {
                        Text(time(turn.start, turn.end))
                        Text(turn.speakerName ?? turn.speakerLabel ?? "—")
                        Text(turn.japanese)
                        if deliverables.contains(.englishTranslationTranscript)
                            || deliverables.contains(.englishSubtitles) {
                            Text(turn.english ?? "")
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
        if !customSpeakerLabels.isEmpty {
            HStack {
                ForEach(customSpeakerLabels.keys.sorted(), id: \.self) { label in
                    TextField(label, text: Binding(
                        get: { customSpeakerLabels[label] ?? label },
                        set: { customSpeakerLabels[label] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                Button("Apply Labels") {
                    do {
                        self.result = try HighQualityJob.renameSpeakers(
                            in: result,
                            names: customSpeakerLabels
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(result.manifest.schemaVersion < 3)
            }
            if result.manifest.schemaVersion < 3 {
                Text("Speaker label edits require a result saved with the current schema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func time(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
        guard let start, let end else { return "—" }
        return "\(SubtitleTimecode.webVTT(start))–\(SubtitleTimecode.webVTT(end))"
    }
}
