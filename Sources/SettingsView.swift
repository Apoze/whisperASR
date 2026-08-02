import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("transcriptFontSize") private var transcriptFontSize = TranscriptFontSize.normal.rawValue
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("targetLanguage") private var targetLanguage = ""
    @AppStorage("translationEndpoint") private var translationEndpoint = ""
    @AppStorage("translationAPIKey") private var translationAPIKey = ""
    @AppStorage("translationModel") private var translationModel = ""
    @State private var japaneseContextLibrary = JapaneseContextLibrary.stored()
    @State private var editedJapaneseContextProfileID = JapaneseContextLibrary.generalID
    @State private var pendingContextProfileDeletion: JapaneseContextProfile?

    // Local OpenAI-compatible API server
    @AppStorage(APIServer.enabledKey) private var apiServerEnabled = false
    @AppStorage(APIServer.portKey) private var apiServerPort = 8080
    @AppStorage(APIServer.tokenKey) private var apiServerToken = ""
    @AppStorage(APIServer.allowLANKey) private var apiServerAllowLAN = false
    @AppStorage(APIServer.verboseLogKey) private var apiServerVerboseLog = false
    @State private var apiServer = APIServer.shared

    @State private var verifyInFlight = false
    @State private var verifyResult: VerifyResult? = nil

    // Backup & restore
    @State private var backupStatus: BackupStatus? = nil
    @State private var pendingRestore: BackupService.BackupFile? = nil
    @State private var showRestoreConfirm = false

    private enum VerifyResult {
        case success(String)
        case failure(String)
    }

    private enum BackupStatus {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Transcript Font Size", selection: $transcriptFontSize) {
                    ForEach(TranscriptFontSize.allCases, id: \.rawValue) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Translation") {
                Picker("Target Language", selection: $targetLanguage) {
                    Text("Off").tag("")
                    ForEach(TargetLanguage.available) { lang in
                        Text(lang.nativeName).tag(lang.id)
                    }
                }
                Text("Translate live transcription to this language using an OpenAI-compatible API configured below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI Translation API") {
                TextField("API Endpoint", text: $translationEndpoint,
                          prompt: Text("https://api.openai.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationEndpoint) { _, _ in verifyResult = nil }
                SecureField("API Key", text: $translationAPIKey,
                            prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationAPIKey) { _, _ in verifyResult = nil }
                TextField("Model", text: $translationModel,
                          prompt: Text("gpt-4o-mini"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: translationModel) { _, _ in verifyResult = nil }
                Text("Only API Key is required. Endpoint defaults to OpenAI, model defaults to gpt-4o-mini.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        verifyConnection()
                    } label: {
                        if verifyInFlight {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify Connection")
                        }
                    }
                    .disabled(verifyInFlight || translationAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    switch verifyResult {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    case .none:
                        EmptyView()
                    }
                    Spacer()
                }
            }

            Section("Speech Recognition Models") {
                ForEach(ModelCatalog.all) { model in
                    ModelRowView(model: model)
                }
                Text("Local English captions use these models only for source transcription; Apple Translation produces the English. Turbo is recommended for the Whisper source option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Japanese glossary profiles") {
                Picker("Profile to edit", selection: $editedJapaneseContextProfileID) {
                    ForEach(japaneseContextLibrary.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .accessibilityIdentifier("japanese-context-profile-editor-picker")

                HStack {
                    Button {
                        let profile = JapaneseContextProfile(
                            id: UUID().uuidString,
                            name: "New profile",
                            terms: [JapaneseContextTerm()]
                        )
                        japaneseContextLibrary.profiles.append(profile)
                        editedJapaneseContextProfileID = profile.id
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }

                    Button(role: .destructive) {
                        pendingContextProfileDeletion = japaneseContextLibrary.profiles.first {
                            $0.id == editedJapaneseContextProfileID
                        }
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                    }
                    .disabled(editedJapaneseContextProfileID == JapaneseContextLibrary.generalID)
                    Spacer()
                }

                if let index = japaneseContextLibrary.profiles.firstIndex(where: {
                    $0.id == editedJapaneseContextProfileID
                }) {
                    JapaneseContextProfileEditor(
                        profile: $japaneseContextLibrary.profiles[index],
                        activeTermCount: activeTermCount(
                            for: japaneseContextLibrary.profiles[index]
                        )
                    )
                }

                Text("Variants are corrected only on the Japanese copy sent to Apple Translation; the raw transcript is preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Model") {
                HStack {
                    TextField("GGML model file", text: $modelPath,
                              prompt: Text("Path to a custom ggml model"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseModel() }
                }
                Text("Used only when no model is selected above. Leave empty otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local API Server (OpenAI-compatible)") {
                Toggle("Run transcription API server", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, on in
                        if on { apiServer.start() } else { apiServer.stop() }
                    }

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("8080", value: $apiServerPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .disabled(apiServer.isRunning)
                }

                SecureField("API Key (optional)", text: $apiServerToken,
                            prompt: Text("Leave empty to allow any client"))
                    .textFieldStyle(.roundedBorder)

                Toggle("Allow access from other devices on your network", isOn: $apiServerAllowLAN)
                    .disabled(apiServer.isRunning)

                Toggle("Verbose request logging (for troubleshooting)", isOn: $apiServerVerboseLog)

                if apiServer.isRunning, let base = apiServer.baseURL {
                    HStack(spacing: 8) {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(base)/v1")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(base)/v1", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy base URL")
                        Spacer()
                    }
                } else if let err = apiServer.lastError {
                    Label(err, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }

                Text("Point any OpenAI-compatible client at the address above (base_url). Endpoints: POST /v1/audio/transcriptions and /v1/audio/translations (multipart with a `file`; response_format supports json, verbose_json, text, srt, vtt). Requests use your currently selected model. Changing the port or network setting takes effect after toggling the server off and on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backup & Restore") {
                HStack(spacing: 10) {
                    Button("Export Backup…") { exportBackup() }
                    Button("Restore from Backup…") { pickRestoreFile() }
                    Spacer()
                }

                switch backupStatus {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                case .none:
                    EmptyView()
                }

                Text("Saves your settings (model choice, translation API config, font size, recent apps) to one file. On a new Mac, copy your Recordings and Transcriptions folders into ~/Library/Application Support/WhisperASR/ — transcripts load from there and audio links repair automatically — then restore your settings here. The file includes your translation API key, so keep it private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        .onAppear {
            ModelManager.shared.refresh()
            japaneseContextLibrary = JapaneseContextLibrary.stored()
            if !japaneseContextLibrary.profiles.contains(where: {
                $0.id == editedJapaneseContextProfileID
            }) {
                editedJapaneseContextProfileID = JapaneseContextLibrary.generalID
            }
        }
        .onChange(of: japaneseContextLibrary) { _, library in
            library.store()
        }
        .confirmationDialog(
            "Delete \(pendingContextProfileDeletion?.name ?? "profile")?",
            isPresented: Binding(
                get: { pendingContextProfileDeletion != nil },
                set: { if !$0 { pendingContextProfileDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                guard let profile = pendingContextProfileDeletion,
                      profile.id != JapaneseContextLibrary.generalID else { return }
                japaneseContextLibrary.profiles.removeAll { $0.id == profile.id }
                editedJapaneseContextProfileID = JapaneseContextLibrary.generalID
                pendingContextProfileDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingContextProfileDeletion = nil }
        }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Restore") { performRestore() }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("This overwrites your current settings (model choice, translation API config, font size, recent apps) with the values from the backup. Your transcriptions are not affected.")
        }
    }

    private func verifyConnection() {
        verifyInFlight = true
        verifyResult = nil
        let lang = targetLanguage.isEmpty ? "en" : targetLanguage
        Task {
            do {
                let translations = try await TranslationService.translateSegmentsWithOpenAI(
                    segmentTexts: ["Hello, world."],
                    targetLanguage: lang
                )
                await MainActor.run {
                    verifyInFlight = false
                    let sample = translations.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if sample.isEmpty {
                        verifyResult = .failure("Empty response")
                    } else {
                        verifyResult = .success("OK — \(sample)")
                    }
                }
            } catch {
                await MainActor.run {
                    verifyInFlight = false
                    verifyResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                modelPath = url.path
            }
        }
    }

    // MARK: - Backup & Restore

    private static func backupDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func exportBackup() {
        let backup = BackupService.makeBackup()
        guard let data = try? BackupService.encode(backup) else {
            backupStatus = .failure("Couldn't create backup data.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WhisperASR Backup \(Self.backupDateString()).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                backupStatus = .success("Settings exported.")
            } catch {
                backupStatus = .failure("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                pendingRestore = try BackupService.decode(data)
                showRestoreConfirm = true
            } catch {
                backupStatus = .failure("Couldn't read backup: \(error.localizedDescription)")
            }
        }
    }

    private func performRestore() {
        guard let backup = pendingRestore else { return }
        BackupService.restore(backup)
        japaneseContextLibrary = JapaneseContextLibrary.stored()
        editedJapaneseContextProfileID = JapaneseContextLibrary.generalID
        backupStatus = .success("Settings restored.")
        pendingRestore = nil
    }

    private func activeTermCount(for profile: JapaneseContextProfile) -> Int {
        let generalCount = japaneseContextLibrary.generalProfile?.terms
            .filter { !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count ?? 0
        let profileCount = profile.terms
            .filter { !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        return profile.id == JapaneseContextLibrary.generalID
            ? generalCount : generalCount + profileCount
    }
}

private struct JapaneseContextProfileEditor: View {
    @Binding var profile: JapaneseContextProfile
    let activeTermCount: Int

    var body: some View {
        if profile.id != JapaneseContextLibrary.generalID {
            TextField("Profile name", text: $profile.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("japanese-context-profile-name")
        }

        HStack {
            Text("Canonical").frame(maxWidth: .infinity, alignment: .leading)
            Text("Reading").frame(maxWidth: .infinity, alignment: .leading)
            Text("Variants (comma-separated)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach(Array(profile.terms.enumerated()), id: \.element.id) { index, term in
            HStack {
                TextField("甘結もか", text: $profile.terms[index].canonical)
                    .accessibilityIdentifier("japanese-context-canonical-\(index)")
                TextField("あまゆい もか", text: $profile.terms[index].reading)
                TextField("甘いモカ", text: aliasesBinding(at: index))
                Button(role: .destructive) {
                    profile.terms.removeAll { $0.id == term.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove term")
            }
        }

        HStack {
            Button {
                profile.terms.append(JapaneseContextTerm())
            } label: {
                Label("Add Term", systemImage: "plus")
            }
            Spacer()
            Text("\(activeTermCount) active term\(activeTermCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func aliasesBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { profile.terms[index].aliases.joined(separator: ", ") },
            set: { value in
                profile.terms[index].aliases = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

// MARK: - Model Row

private struct ModelRowView: View {
    let model: WhisperModelInfo
    @State private var manager = ModelManager.shared
    @State private var confirmDelete = false

    private var downloader: ModelDownloader { manager.downloader(for: model) }
    private var isDownloaded: Bool { manager.isDownloaded(model) }
    private var isSelected: Bool { manager.selectedFileName == model.fileName }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                manager.selectedFileName = model.fileName
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isDownloaded)
            .help(isDownloaded ? "Use this model for transcription" : "Download the model first")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.detail) · \(model.approxSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloaded {
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete downloaded model")
            } else if downloader.state == .downloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    downloader.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            } else {
                if case .failed = downloader.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Download failed — click Download to retry")
                }
                Button(downloader.hasResumeData ? "Resume" : "Download") {
                    downloader.startDownload()
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete", role: .destructive) {
                manager.delete(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model file (\(model.approxSizeText)) will be removed from disk. You can download it again later.")
        }
    }
}
