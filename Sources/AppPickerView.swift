import SwiftUI
import ScreenCaptureKit

struct AppPickerView: View {
    @Environment(AppState.self) var appState
    @Environment(AudioRecorder.self) var recorder
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow
    @State private var searchText = ""
    @State private var modelManager = ModelManager.shared
    @AppStorage(LiveCaptionMode.storageKey) private var captionModeRaw = LiveCaptionMode.original.rawValue
    @AppStorage(LiveCaptionMode.keepOriginalKey) private var keepOriginalTranscript = false
    @AppStorage(LocalEnglishEngine.storageKey) private var localEnglishEngineRaw = LocalEnglishEngine.whisperTurboApple.rawValue
    @AppStorage(LocalSpeechEngine.sourceLocaleKey) private var localSourceLocale = ""
    @AppStorage(AppleTranslationMode.storageKey) private var appleTranslationModeRaw = AppleTranslationMode.adaptive.rawValue
    @AppStorage("targetLanguage") private var targetLanguage = ""

    private var captionMode: LiveCaptionMode {
        LiveCaptionMode(rawValue: captionModeRaw) ?? .original
    }

    private var captionModeBinding: Binding<LiveCaptionMode> {
        Binding(
            get: { captionMode },
            set: { mode in
                captionModeRaw = mode.rawValue
                if mode == .api, targetLanguage.isEmpty { targetLanguage = "en" }
            }
        )
    }

    private var localEnglishEngine: LocalEnglishEngine {
        LocalEnglishEngine(rawValue: localEnglishEngineRaw) ?? .whisperTurboApple
    }

    private var appleTranslationMode: AppleTranslationMode {
        AppleTranslationMode(rawValue: appleTranslationModeRaw) ?? .adaptive
    }

    private var availableTranslationModes: [AppleTranslationMode] {
        localEnglishEngine.producesDirectEnglish
            ? [.adaptive, .highFidelityOnly]
            : AppleTranslationMode.allCases
    }

    var body: some View {
        @Bindable var appState = appState
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            switch recorder.state {
            case .idle, .loading:
                loadingContent
            case .ready:
                pickerContent
            case .permissionDenied:
                permissionDeniedContent
            default:
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(
            minWidth: 360, idealWidth: 420, maxWidth: .infinity,
            minHeight: 460, idealHeight: 460, maxHeight: .infinity
        )
        .background(WindowPositioner())
        .background { translationPreparation }
        .onAppear {
            if recorder.state == .idle {
                recorder.loadAvailableApps()
            }
            captionModeRaw = LiveCaptionMode.stored().rawValue
            localEnglishEngineRaw = LocalEnglishEngine.stored().rawValue
            appleTranslationModeRaw = AppleTranslationMode.stored().rawValue
            if localEnglishEngine.producesDirectEnglish,
               appleTranslationMode == .lowLatencyOnly {
                appleTranslationModeRaw = AppleTranslationMode.adaptive.rawValue
            }
            if captionMode == .api, targetLanguage.isEmpty { targetLanguage = "en" }
            if captionMode == .localEnglish { appState.loadLocalEnglishCapabilities() }
        }
        .onChange(of: captionModeRaw) { _, _ in
            if captionMode == .localEnglish {
                appState.loadLocalEnglishCapabilities()
            } else {
                appState.deactivateLocalEnglishResources()
            }
        }
        .onChange(of: appState.enableLiveTranscription) { _, enabled in
            if enabled, captionMode == .localEnglish {
                appState.loadLocalEnglishCapabilities()
            } else if !enabled {
                appState.deactivateLocalEnglishResources()
            }
        }
        .onChange(of: modelManager.selectedFileName) { _, _ in
            if captionMode == .localEnglish, localEnglishEngine.usesWhisperFinal {
                appState.prepareLiveTranslationModel()
            }
        }
        .onChange(of: localEnglishEngineRaw) { _, _ in
            if localEnglishEngine.producesDirectEnglish,
               appleTranslationMode == .lowLatencyOnly {
                appleTranslationModeRaw = AppleTranslationMode.adaptive.rawValue
            }
            appState.resetAppleTranslationPreparation()
            appState.reloadLocalEnglishCapabilities()
        }
        .onChange(of: localSourceLocale) { _, _ in
            appState.resetAppleTranslationPreparation()
            appState.prepareLocalEnglishResources()
        }
        .onChange(of: appleTranslationModeRaw) { _, _ in
            appState.resetAppleTranslationPreparation()
            appState.reloadLocalEnglishCapabilities()
        }
    }

    // MARK: - Loading

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading applications...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Picker

    private var pickerContent: some View {
        @Bindable var appState = appState
        @Bindable var recorder = recorder
        return VStack(spacing: 0) {
            if let error = recorder.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            List(filteredApps, id: \.bundleIdentifier, selection: Binding(
                get: { recorder.selectedApp?.bundleIdentifier },
                set: { id in
                    recorder.selectedApp = recorder.availableApps.first { $0.bundleIdentifier == id }
                }
            )) { app in
                HStack(spacing: 10) {
                    appIcon(for: app)
                        .frame(width: 24, height: 24)
                    Text(app.applicationName)
                        .lineLimit(1)
                }
                .tag(app.bundleIdentifier)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Toggle("Microphone", isOn: $recorder.includeMicrophone)
                    Toggle("Live captions", isOn: $appState.enableLiveTranscription)
                }
                .toggleStyle(.checkbox)

                if appState.enableLiveTranscription {
                    Picker("Captions", selection: captionModeBinding) {
                        ForEach(availableCaptionModes) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    if captionMode == .api {
                        Picker("API target", selection: $targetLanguage) {
                            ForEach(TargetLanguage.available) { language in
                                Text(language.nativeName).tag(language.id)
                            }
                        }
                    }

                    if captionMode == .localEnglish {
                        Picker("Local English engine", selection: $localEnglishEngineRaw) {
                            ForEach(LocalEnglishEngine.allCases) { engine in
                                Text(engine.label).tag(engine.rawValue)
                            }
                        }

                        Picker("Spoken language", selection: $localSourceLocale) {
                            Text("Choose a language…").tag("")
                            ForEach(appState.localSourceLocales) { locale in
                                Text(locale.label).tag(locale.id)
                            }
                        }

                        Picker("Subtitle timing", selection: $appleTranslationModeRaw) {
                            ForEach(availableTranslationModes) { mode in
                                Text(translationModeLabel(mode)).tag(mode.rawValue)
                            }
                        }

                        if let modelID = localEnglishEngine.whisperModelID,
                           let model = ModelCatalog.model(id: modelID) {
                            LabeledContent("Whisper model", value: model.displayName)
                        }

                        LabeledContent(
                            "Translation",
                            value: localEnglishEngine.producesDirectEnglish
                                ? (appleTranslationMode.showsPreview
                                    ? "Apple live preview → direct final"
                                    : "Direct model final")
                                : appleTranslationMode.label
                        )

                        localEnglishStatus
                    }

                    if captionMode != .original,
                       captionMode != .localEnglish || !localEnglishEngine.producesDirectEnglish {
                        Toggle("Keep original transcript", isOn: $keepOriginalTranscript)
                            .toggleStyle(.checkbox)
                    }

                    Text(captionModeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack {
                Button("Cancel") {
                    if captionMode == .localEnglish {
                        appState.deactivateLocalEnglishResources()
                    }
                    recorder.state = .idle
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Recording") {
                    if let app = recorder.selectedApp {
                        recorder.startRecording(app: app)
                        openWindow(id: "recording")
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    recorder.selectedApp == nil
                        || appState.isLiveTranscribing
                        || appState.hasUnresolvedLiveRecovery
                        || (captionMode == .localEnglish && !appState.isLocalEnglishReady)
                )
            }
            .padding(12)
        }
    }

    // MARK: - Permission Denied

    private var permissionDeniedContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text("WhisperASR needs Screen Recording permission to capture audio from other applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    recorder.openSystemPreferences()
                }
                .buttonStyle(.borderedProminent)

                Button("Try Again") {
                    recorder.loadAvailableApps()
                }
            }

            Spacer()

            Button("Cancel") {
                recorder.state = .idle
                dismiss()
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var captionModeDescription: String {
        switch captionMode {
        case .original:
            return "Transcribes locally in the detected spoken language."
        case .localEnglish:
            if localEnglishEngine.usesContinuousVoxtral {
                switch appleTranslationMode {
                case .adaptive:
                    return "Voxtral continuously transcribes the source. Apple low-latency revises the live English line; Apple high-fidelity replaces it with the saved final. Everything stays on this Mac."
                case .highFidelityOnly:
                    return "Voxtral continuously transcribes the source. Apple high-fidelity displays and saves only stable English clauses. Everything stays on this Mac."
                case .lowLatencyOnly:
                    return "Voxtral continuously transcribes the source. Apple low-latency revises the live English line and produces the saved final. Everything stays on this Mac."
                }
            }
            if appleTranslationMode.showsPreview {
                let previewSource = localEnglishEngine.usesAppleSpeechPreview
                    ? "Apple Speech supplies source text for one revisable Apple-translated preview"
                    : "Voxtral supplies source text for one revisable Apple-translated preview"
                return localEnglishEngine.detail + " \(previewSource); only the selected engine's final is saved. Everything stays on this Mac."
            }
            return localEnglishEngine.detail + " Only stable English is shown; everything stays on this Mac."
        case .api:
            return "Whisper transcribes locally, then the configured OpenAI-compatible API translates to the selected language."
        }
    }

    @ViewBuilder
    private var localEnglishStatus: some View {
        if localSourceLocale.isEmpty {
            Label("Choose the spoken language.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if appState.isPreparingLocalResources
                    || (localEnglishEngine.usesWhisperFinal && appState.isPreparingLiveModel) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(modelPreparationMessage)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let error = appState.localResourceError
                    ?? appState.appleTranslationPreparationError
                    ?? appState.liveModelPreparationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        } else if appState.isLocalEnglishReady {
            VStack(alignment: .leading, spacing: 3) {
                Label(readyMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let warning = appState.localModelManager.memoryWarning {
                    Label(warning, systemImage: "memorychip")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
        } else if case .failed(let error) = appState.localModelManager.phase(for: localEnglishEngine) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var modelPreparationMessage: String {
        switch appState.localModelManager.phase(for: localEnglishEngine) {
        case .downloading(let progress, let message):
            return "\(message) \(Int(progress * 100))%"
        case .loading(let message):
            return message
        default:
            return "Preparing the selected local pipeline…"
        }
    }

    private var readyMessage: String {
        if case .ready(let bytes) = appState.localModelManager.phase(for: localEnglishEngine) {
            return "Ready — process using \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))"
        }
        return "Ready for local English subtitles"
    }

    private var availableCaptionModes: [LiveCaptionMode] {
        if #available(macOS 26.4, *) { return LiveCaptionMode.allCases }
        return LiveCaptionMode.allCases.filter { $0 != .localEnglish }
    }

    @ViewBuilder
    private var translationPreparation: some View {
        if captionMode == .localEnglish,
           !localSourceLocale.isEmpty,
           let preparationMode = applePreparationMode {
            let capturedEngine = localEnglishEngine
            let capturedMode = appleTranslationMode
            let capturedSourceLocale = localSourceLocale
            let capturedGeneration = appState.localPreparationGeneration
            if #available(macOS 26.4, *) {
                AppleTranslationPreparationView(
                    sourceLocale: capturedSourceLocale,
                    mode: preparationMode
                ) { highFidelity, ready, error in
                    appState.reportAppleTranslationPreparation(
                        highFidelity: highFidelity,
                        ready: ready,
                        error: error,
                        engine: capturedEngine,
                        translationMode: capturedMode,
                        sourceLocale: capturedSourceLocale,
                        generation: capturedGeneration
                    )
                }
                .id("\(capturedSourceLocale)|\(capturedMode.rawValue)|\(capturedEngine.rawValue)|\(capturedGeneration)")
            }
        }
    }

    private var applePreparationMode: AppleTranslationMode? {
        guard localEnglishEngine.producesDirectEnglish else {
            return appleTranslationMode
        }
        return appleTranslationMode.showsPreview ? .lowLatencyOnly : nil
    }

    private func translationModeLabel(_ mode: AppleTranslationMode) -> String {
        guard localEnglishEngine.producesDirectEnglish else { return mode.label }
        return mode.showsPreview
            ? "Live preview → direct final"
            : "Stable direct final only"
    }

    private var filteredApps: [SCRunningApplication] {
        guard !searchText.isEmpty else { return sortedApps }
        return sortedApps.filter {
            $0.applicationName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sortedApps: [SCRunningApplication] {
        let recent = recorder.recentAppBundleIDs
        return recorder.availableApps.sorted { a, b in
            let aIdx = recent.firstIndex(of: a.bundleIdentifier)
            let bIdx = recent.firstIndex(of: b.bundleIdentifier)
            switch (aIdx, bIdx) {
            case let (.some(ai), .some(bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.applicationName < b.applicationName
            }
        }
    }

    private func appIcon(for app: SCRunningApplication) -> some View {
        Group {
            if let nsApp = NSRunningApplication(processIdentifier: app.processID),
               let icon = nsApp.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Window Positioner

/// Centers this window on the main WhisperASR window each time it becomes key,
/// synchronously (before any drawing) so there is no visible jump.
private struct WindowPositioner: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { PositionView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    class PositionView: NSView {
        let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, coordinator.window == nil {
                coordinator.observe(window)
            }
        }
    }

    class Coordinator: NSObject {
        weak var window: NSWindow?

        func observe(_ window: NSWindow) {
            self.window = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }

        @objc func windowDidBecomeKey(_ notification: Notification) {
            guard let window = notification.object as? NSWindow,
                  let mainWindow = NSApplication.shared.windows.first(where: {
                      $0 !== window && $0.isVisible && $0.title != "Recording"
                  }) else { return }
            let mf = mainWindow.frame
            let wf = window.frame
            window.setFrameOrigin(NSPoint(x: mf.midX - wf.width / 2, y: mf.midY - wf.height / 2))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
