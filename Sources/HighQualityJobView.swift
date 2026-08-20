import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HighQualityReadableSubtitleBetaControls: Equatable {
    var enabled = false

    func isVisible(hasEnglishSubtitles: Bool) -> Bool { hasEnglishSubtitles }

    mutating func reconcile(hasEnglishSubtitles: Bool) {
        if !hasEnglishSubtitles { enabled = false }
    }
}

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

struct HighQualityJobResultPresentation {
    private(set) var visibleResult: HighQualityJobResult?

    mutating func publish(_ completed: HighQualityJobResult?) {
        if let completed { visibleResult = completed }
    }

    mutating func clear() {
        visibleResult = nil
    }
}

struct HighQualitySpeakerReanalysisActionState: Equatable {
    let isVisible: Bool
    let isEnabled: Bool
    let explanation: String?

    init(
        result: HighQualityJobResult,
        saved: HighQualitySavedResult,
        isRunning: Bool,
        includeLabels: Bool
    ) {
        let availability = HighQualityJob.speakerReanalysisAvailability(result)
        isVisible = availability != .unavailable
        isEnabled = availability == .available
            && !isRunning && includeLabels && saved.sourceRelocationMessage == nil
        explanation = availability.explanation
    }
}

struct HighQualitySpeakerLabelActionState: Equatable {
    let isEnabled: Bool

    init(result: HighQualityJobResult, isRunning: Bool) {
        isEnabled = result.manifest.schemaVersion >= 3 && !isRunning
    }
}

struct HighQualityJobView: View {
    @State private var workspace = HighQualityProjectWorkspace()
    @State private var includeJapaneseTranscript = true
    @State private var includeEnglishTranscript = false
    @State private var includeEnglishSubtitles = false
    @State private var readableSubtitleBeta = HighQualityReadableSubtitleBetaControls()
    @State private var speakerBeta = HighQualitySpeakerBetaControls()
    @State private var backend: HighQualityASRBackend? = .productDefault
    @State private var translator: HighQualityTranslator = .productDefault
    @State private var progress = HighQualityJobProgress(
        stage: .validating,
        fraction: 0,
        message: "Choose a local audio or video file."
    )
    @State private var resultPresentation = HighQualityJobResultPresentation()
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var customSpeakerLabels: [String: String] = [:]
    @State private var projectName = ""
    @State private var isRenamingProject = false
    @State private var showsProjectConfirmation = false
    @State private var speakerReanalysisID: UUID?

    private var isRunning: Bool { task != nil }
    private var result: HighQualityJobResult? { resultPresentation.visibleResult }
    private var canStart: Bool {
        workspace.selectedSourceURL != nil
            && (includeJapaneseTranscript || includeEnglishTranscript || includeEnglishSubtitles)
            && backend != nil
            && !isRunning
            && (workspace.selectedProjectID == nil || selectedProject != nil)
            && selectedProject?.folderRelocationMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("High-quality transcript")
                .font(.title2.bold())

            HStack {
                Picker("Project", selection: Binding(
                    get: { workspace.selectedProjectID },
                    set: selectProject
                )) {
                    Text("Standalone").tag(nil as UUID?)
                    ForEach(projectEntries) { entry in
                        Text(entry.errorMessage == nil
                            ? entry.name
                            : "\(entry.name) — \(entry.canLocateFolder ? "Locate Folder" : "Invalid")")
                            .tag(Optional(entry.id))
                    }
                }
                .disabled(isRunning)
                .accessibilityIdentifier("high-quality-project")

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
                        if let entry = selectedProjectEntry {
                            Button("Locate Folder…") { locateFolder(for: entry) }
                        }
                        Divider()
                        Button("Reset Project…", role: .destructive) {
                            requestProjectAction(.reset)
                        }
                        .accessibilityIdentifier("high-quality-reset-project")
                        Button("Delete Project…", role: .destructive) {
                            requestProjectAction(.delete)
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
                        if let entry = selectedProjectEntry {
                            Button("Locate Project Folder…") { locateFolder(for: entry) }
                                .accessibilityIdentifier("high-quality-locate-project-folder")
                        }
                    }
                }
            }

            if let entry = selectedProjectEntry, let message = entry.errorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if entry.canLocateFolder {
                        Button("Locate Project Folder…") { locateFolder(for: entry) }
                            .accessibilityIdentifier("high-quality-locate-invalid-project-folder")
                    }
                }
            } else if let message = workspace.projectStorageError {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !savedResults.isEmpty {
                Picker("Saved result", selection: Binding(
                    get: { workspace.selectedSavedResultID },
                    set: reopenSavedResult
                )) {
                    Text("New High-quality job").tag(nil as UUID?)
                    ForEach(savedResults) { saved in
                        Text(saved.sourceURL.lastPathComponent).tag(Optional(saved.id))
                    }
                }
                .disabled(isRunning)
                .accessibilityIdentifier("high-quality-saved-result")
            }

            sourcePicker

            TextField("Public YouTube video URL", text: Binding(
                get: { youtubeURL },
                set: selectYouTube
            ))
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)

            Toggle("Japanese transcript", isOn: $includeJapaneseTranscript)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("English translation transcript", isOn: $includeEnglishTranscript)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("English WebVTT and SRT subtitles", isOn: $includeEnglishSubtitles)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
                .onChange(of: includeEnglishSubtitles) { _, value in
                    readableSubtitleBeta.reconcile(hasEnglishSubtitles: value)
                }
            if readableSubtitleBeta.isVisible(hasEnglishSubtitles: includeEnglishSubtitles) {
                Toggle("Sous-titres plus lisibles (Bêta)", isOn: $readableSubtitleBeta.enabled)
                    .toggleStyle(.checkbox)
                    .disabled(isRunning)
                    .accessibilityIdentifier("readable-subtitles-beta")
                    .accessibilityHint(
                        "Redistribue les lignes et les repères après traduction."
                    )
                Text("Améliore le découpage après traduction. Coût supplémentaire négligeable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Speaker labels", isOn: $speakerBeta.includeLabels)
                .toggleStyle(.checkbox)
                .disabled(isRunning || workspace.selectedSavedResultID != nil)

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
                    if let saved = selectedSavedResult,
                       let state = speakerReanalysisActionState,
                       state.isVisible {
                        Button("Reanalyze Speakers") { rerunSpeakers(saved) }
                            .disabled(!state.isEnabled)
                            .accessibilityIdentifier("high-quality-rerun-speakers")
                            .accessibilityHint(
                                "Runs SpeakerKit only and keeps the previous result until completion."
                            )
                    }
                    Button("Open Results Folder") {
                        NSWorkspace.shared.open(result.directory)
                    }
                }
            }

            if let explanation = speakerReanalysisActionState?.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("high-quality-rerun-speakers-reason")
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
                            .disabled(isRunning)
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
        .onAppear { workspace.refresh() }
        .onDisappear { task?.cancel() }
        .alert("Rename Project", isPresented: $isRenamingProject) {
            TextField("Project name", text: $projectName)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: renameProject)
        }
        .confirmationDialog(
            "Confirm Project Action",
            isPresented: $showsProjectConfirmation,
            titleVisibility: .visible,
            presenting: workspace.pendingProjectAction
        ) { action in
            switch action {
            case .reset:
                Button("Reset Project", role: .destructive, action: performProjectAction)
            case .delete:
                Button("Delete Project", role: .destructive, action: performProjectAction)
            }
            Button("Cancel", role: .cancel) { workspace.cancelProjectAction() }
        } message: { action in
            Text(action == .reset
                ? "This clears only this Project's results, metadata, glossary, voice profiles "
                    + "and history. Its folder and source media stay in place."
                : "This removes only this Project and its saved data. Source media is not deleted.")
        }
    }

    private var sourceURL: URL? { workspace.sourceURL }
    private var youtubeURL: String { workspace.youtubeURL }
    private var projectEntries: [HighQualityProjectEntry] { workspace.projectEntries }
    private var savedResults: [HighQualitySavedResult] { workspace.savedResults }
    private var selectedProject: HighQualityProject? {
        workspace.selectedProject
    }

    private var selectedProjectEntry: HighQualityProjectEntry? {
        workspace.selectedProjectEntry
    }

    private var selectedSavedResult: HighQualitySavedResult? {
        workspace.selectedSavedResult
    }

    private var speakerReanalysisActionState: HighQualitySpeakerReanalysisActionState? {
        guard let result, let saved = selectedSavedResult else { return nil }
        return .init(
            result: result,
            saved: saved,
            isRunning: isRunning,
            includeLabels: speakerBeta.includeLabels
        )
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
        workspace.selectLocalSource(url)
        errorMessage = nil
    }

    private func selectYouTube(_ value: String) {
        workspace.selectYouTube(value)
        guard !value.isEmpty else { return }
        errorMessage = nil
    }

    private func start() {
        var deliverables: Set<HighQualityDeliverable> = []
        if includeJapaneseTranscript { deliverables.insert(.japaneseTranscript) }
        if includeEnglishTranscript { deliverables.insert(.englishTranslationTranscript) }
        if includeEnglishSubtitles { deliverables.insert(.englishSubtitles) }
        guard workspace.selectedSourceURL != nil, let backend, !deliverables.isEmpty else {
            errorMessage = "Select a source and at least one Deliverable."
            return
        }
        errorMessage = nil
        progress = .init(stage: .validating, fraction: 0, message: "Starting…")
        task = Task {
            do {
                let completed = try await workspace.runSelectedJob(
                    deliverables: deliverables,
                    backend: backend,
                    translator: translator,
                    speakerLabels: speakerBeta.includeLabels,
                    readableSubtitles: readableSubtitleBeta.enabled,
                    speakerConfiguration: speakerBeta.configuration,
                    translationContextPolicy: .productDefault
                ) { update in
                    Task { @MainActor in progress = update }
                }
                resultPresentation.publish(completed)
                customSpeakerLabels = initialCustomSpeakerLabels(for: completed)
                workspace.refresh()
                workspace.selectSavedResult(completed.manifest.jobID)
            } catch let error as HighQualityJobError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }

    private func selectProject(_ id: UUID?) {
        guard !isRunning else { return }
        workspace.selectProject(id)
        resultPresentation.clear()
        errorMessage = nil
        customSpeakerLabels = [:]
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
                _ = try workspace.createProject(
                    named: folder.lastPathComponent,
                    folder: folder
                )
                resultPresentation.clear()
                customSpeakerLabels = [:]
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
        do {
            _ = try workspace.renameSelectedProject(to: projectName)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateFolder(for entry: HighQualityProjectEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Locate Project Folder"
        if let project = entry.project, project.folderRelocationMessage == nil {
            panel.directoryURL = project.folderURL
        }
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                _ = try workspace.relocateSelectedProject(to: folder)
                resultPresentation.clear()
                customSpeakerLabels = [:]
                errorMessage = nil
                progress = .init(
                    stage: .validating,
                    fraction: 0,
                    message: "Project folder located. Choose a source or saved result."
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestProjectAction(_ action: HighQualityProjectDestructiveAction) {
        workspace.requestProjectAction(action)
        showsProjectConfirmation = workspace.pendingProjectAction != nil
    }

    private func performProjectAction() {
        task = Task {
            do {
                var updatedWorkspace = workspace
                let action = try await updatedWorkspace.confirmProjectAction()
                workspace = updatedWorkspace
                resultPresentation.clear()
                customSpeakerLabels = [:]
                errorMessage = nil
                progress = .init(
                    stage: .validating,
                    fraction: 0,
                    message: action == .reset ? "Project reset" : "Project deleted"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }

    private func reopenSavedResult(_ id: UUID?) {
        workspace.selectSavedResult(id)
        guard let id else {
            guard !isRunning else { return }
            resultPresentation.clear()
            errorMessage = nil
            customSpeakerLabels = [:]
            return
        }
        guard let saved = workspace.selectedSavedResult, saved.id == id else { return }
        do {
            try showSavedResult(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func locateSource(for saved: HighQualitySavedResult) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard task == nil else { return }
            task = Task {
                do {
                    let relocated = try await HighQualityJob().relocateSource(saved, to: url)
                    workspace.refresh()
                    workspace.selectSavedResult(relocated.id)
                    try showSavedResult(
                        workspace.selectedSavedResult ?? relocated
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
                task = nil
            }
        }
    }

    private func showSavedResult(_ saved: HighQualitySavedResult) throws {
        let reopened = try HighQualityJob.reopen(saved)
        let deliverables = Set(reopened.manifest.deliverables)
        workspace.selectSavedResult(saved.id)
        includeJapaneseTranscript = deliverables.contains(.japaneseTranscript)
        includeEnglishTranscript = deliverables.contains(.englishTranslationTranscript)
        includeEnglishSubtitles = deliverables.contains(.englishSubtitles)
        readableSubtitleBeta.enabled = reopened.manifest.readableSubtitles == true
        speakerBeta.includeLabels = reopened.manifest.speakerLabels
        let configuration = reopened.manifest.speakerConfiguration ?? .standard
        speakerBeta.enhancedPrecision = configuration.enhancedPrecision
        speakerBeta.sensitiveDetection = configuration.sensitiveDetection
        switch configuration.countPolicy.mode {
        case .automatic:
            speakerBeta.knowsSpeakerCount = false
        case .expected:
            speakerBeta.knowsSpeakerCount = true
            if let count = configuration.countPolicy.expectedCount,
               HighQualitySpeakerCountPolicy.validExpectedCounts.contains(count) {
                speakerBeta.expectedSpeakerCount = count
            }
        }
        backend = reopened.manifest.selectedBackend
        if let savedTranslator = reopened.manifest.translationModel?.translator {
            translator = savedTranslator
        }
        resultPresentation.publish(reopened)
        errorMessage = reopened.speakerReanalysisCompletion?.auditError
        progress = .init(stage: .completed, fraction: 1, message: "Saved result reopened")
        customSpeakerLabels = initialCustomSpeakerLabels(for: reopened)
    }

    private func rerunSpeakers(_ saved: HighQualitySavedResult) {
        errorMessage = nil
        progress = .init(
            stage: .validating,
            fraction: 0,
            message: "Starting SpeakerKit reanalysis…"
        )
        let configuration = speakerBeta.configuration
        let operationID = UUID()
        speakerReanalysisID = operationID
        let job = HighQualityJob()
        task = Task {
            do {
                let updated = try await job.rerunSpeakers(
                    saved,
                    configuration: configuration
                ) { update in
                    Task { @MainActor in
                        guard HighQualityJobProgress.accepts(
                            operationID,
                            while: speakerReanalysisID
                        ) else { return }
                        progress = update
                    }
                }
                speakerReanalysisID = nil
                progress = .init(
                    stage: .completed,
                    fraction: 1,
                    message: "Speakers reanalyzed"
                )
                resultPresentation.publish(updated)
                customSpeakerLabels = initialCustomSpeakerLabels(for: updated)
                workspace.refresh()
                workspace.selectSavedResult(updated.manifest.jobID)
            } catch {
                speakerReanalysisID = nil
                progress = .terminal(for: error)
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }

    private func initialCustomSpeakerLabels(
        for result: HighQualityJobResult
    ) -> [String: String] {
        result.editableSpeakerNames
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
        let speakerLabels = result.editableSpeakerLabels
        let speakerNames = result.editableSpeakerNames
        let actionState = HighQualitySpeakerLabelActionState(
            result: result,
            isRunning: isRunning
        )
        Text("Results").font(.headline)
        if let reanalysis = result.evidence.speakerReanalyses?.last {
            let completion = result.speakerReanalysisCompletion
            Text(
                "Last SpeakerKit reanalysis "
                    + (completion == nil ? "payload prepared" : "completed") + ": "
                    + String(
                        format: "%.1f s",
                        completion?.wallTime ?? reanalysis.preCommitWallTime
                    )
                    + " · peak " + memory(reanalysis.peakMemoryBytes)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("high-quality-speaker-reanalysis-evidence")
        }
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
                        if result.manifest.schemaVersion >= 3,
                           !speakerLabels.isEmpty,
                           turn.speakerLabel == nil || speakerLabels.count > 1 {
                            Picker(
                                "Speaker for \(turn.id)",
                                selection: Binding<String?>(
                                    get: { turn.speakerLabel },
                                    set: { label in
                                        guard let label else { return }
                                        applySpeakerEdit(
                                            .reassign(turnID: turn.id, to: label),
                                            to: result
                                        )
                                    }
                                )
                            ) {
                                if turn.speakerLabel == nil {
                                    Text("Unassigned").tag(String?.none)
                                }
                                ForEach(speakerLabels, id: \.self) { label in
                                    Text(speakerNames[label] ?? label).tag(String?.some(label))
                                }
                            }
                            .labelsHidden()
                            .disabled(!actionState.isEnabled)
                            .accessibilityLabel("Speaker for transcript turn \(turn.id)")
                        } else {
                            Text(turn.speakerName ?? turn.speakerLabel ?? "—")
                        }
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
                    .accessibilityLabel("Name for \(label)")
                }
                Button("Regenerate Deliverables") {
                    do {
                        resultPresentation.publish(try HighQualityJob.renameSpeakers(
                            in: result,
                            names: customSpeakerLabels
                        ))
                        if let updated = self.result {
                            customSpeakerLabels = initialCustomSpeakerLabels(for: updated)
                        }
                        errorMessage = nil
                        workspace.refresh()
                        workspace.selectSavedResult(result.manifest.jobID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("high-quality-regenerate-deliverables")
                .disabled(!actionState.isEnabled)
            }
            HStack {
                if speakerLabels.count > 1 {
                    Menu("Merge Speakers…") {
                        ForEach(speakerLabels, id: \.self) { source in
                            Menu(speakerNames[source] ?? source) {
                                ForEach(speakerLabels.filter { $0 != source }, id: \.self) { target in
                                    Button("Into \(speakerNames[target] ?? target)") {
                                        applySpeakerEdit(
                                            .merge(source, into: target),
                                            to: result
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("high-quality-merge-speakers")
                }

                Button("Reset Speaker Edits", role: .destructive) {
                    applySpeakerEdit(.reset(), to: result)
                }
                .accessibilityIdentifier("high-quality-reset-speaker-edits")
                .accessibilityHint("Restores the immutable automatic SpeakerKit assignments.")

                Button("Undo Last Speaker Edit") {
                    do {
                        let updated = try HighQualityJob.undoLastSpeakerEdit(in: result)
                        resultPresentation.publish(updated)
                        customSpeakerLabels = initialCustomSpeakerLabels(for: updated)
                        errorMessage = nil
                        workspace.refresh()
                        workspace.selectSavedResult(updated.manifest.jobID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("high-quality-undo-speaker-edit")
                .accessibilityHint("Restores the saved state before the last Speaker edit.")
                .disabled(!result.canUndoLastSpeakerEdit)

            }
            .disabled(!actionState.isEnabled)
            Text("Speaker edits only regenerate saved Deliverables; no model is loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if result.manifest.schemaVersion < 3 {
                Text("Speaker label edits require a result saved with the current schema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if result.canRestorePreviousSpeakerEdits {
            Button("Restore Previous Speaker Edits") {
                do {
                    let updated = try HighQualityJob.restorePreviousSpeakerEdits(in: result)
                    resultPresentation.publish(updated)
                    customSpeakerLabels = initialCustomSpeakerLabels(for: updated)
                    errorMessage = nil
                    workspace.refresh()
                    workspace.selectSavedResult(updated.manifest.jobID)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .accessibilityIdentifier("high-quality-restore-previous-speaker-edits")
            .accessibilityHint("Restores edits archived by the latest compatible reanalysis.")
            .disabled(!actionState.isEnabled)
        } else if result.shouldExplainIncompatibleArchivedSpeakerEdits {
            Text("Previous Speaker edits remain archived but cannot be safely restored to the current Speaker state.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("high-quality-previous-speaker-edits-incompatible")
        }
        if result.hasDuplicateSpeakerBetaEvidence {
            VStack(alignment: .leading, spacing: 4) {
                Text("Similar Voices (Bêta)").font(.headline)
                Text(HighQualityDuplicateSpeakerSuggestion.betaDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if result.duplicateSpeakerSuggestions.isEmpty {
                    Text("No reliable suggestion; weak or ambiguous matches remain Unknown.")
                } else {
                    ForEach(
                        Array(result.duplicateSpeakerSuggestions.enumerated()),
                        id: \.offset
                    ) { _, suggestion in
                        Text(
                            "\(suggestion.firstSpeakerLabel) and "
                                + "\(suggestion.secondSpeakerLabel) may be duplicate labels."
                        )
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("duplicate-speaker-beta")
        }
    }

    private func applySpeakerEdit(
        _ edit: HighQualitySpeakerEdit,
        to result: HighQualityJobResult
    ) {
        do {
            let updated = try HighQualityJob.editSpeakers(
                in: result,
                names: edit.kind == .reset ? [:] : customSpeakerLabels,
                edit: edit
            )
            resultPresentation.publish(updated)
            customSpeakerLabels = initialCustomSpeakerLabels(for: updated)
            errorMessage = nil
            workspace.refresh()
            workspace.selectSavedResult(updated.manifest.jobID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func time(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
        guard let start, let end else { return "—" }
        return "\(SubtitleTimecode.webVTT(start))–\(SubtitleTimecode.webVTT(end))"
    }

    private func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .memory
        )
    }
}
