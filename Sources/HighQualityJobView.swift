import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HighQualityJobView: View {
    @State private var sourceURL: URL?
    @State private var youtubeURL = ""
    @State private var includeJapaneseTranscript = true
    @State private var backend: HighQualityASRBackend?
    @State private var progress = HighQualityJobProgress(
        stage: .validating,
        fraction: 0,
        message: "Choose a local audio or video file."
    )
    @State private var result: HighQualityJobResult?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var isDropTargeted = false

    private var isRunning: Bool { task != nil }
    private var canStart: Bool {
        (sourceURL != nil || !youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && includeJapaneseTranscript
            && backend != nil
            && !isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("High-quality Japanese transcript")
                .font(.title2.bold())

            sourcePicker

            TextField("Public YouTube video URL", text: $youtubeURL)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
                .onChange(of: youtubeURL) { _, value in
                    guard !value.isEmpty else { return }
                    sourceURL = nil
                    result = nil
                    errorMessage = nil
                }

            Toggle("Japanese transcript", isOn: $includeJapaneseTranscript)
                .toggleStyle(.checkbox)
                .disabled(isRunning)

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

            if let result {
                Divider()
                Text("Japanese result")
                    .font(.headline)
                ScrollView {
                    Text(result.japaneseTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .onDisappear { task?.cancel() }
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
        sourceURL = url
        youtubeURL = ""
        result = nil
        errorMessage = nil
    }

    private func start() {
        let value = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSource = value.isEmpty ? sourceURL : URL(string: value)
        guard let selectedSource, let backend, includeJapaneseTranscript else {
            errorMessage = "Select a source and at least one Deliverable."
            return
        }
        result = nil
        errorMessage = nil
        progress = .init(stage: .validating, fraction: 0, message: "Starting…")
        let job = HighQualityJob()
        task = Task {
            do {
                let completed = try await job.run(.init(
                    sourceURL: selectedSource,
                    deliverables: [.japaneseTranscript],
                    backend: backend,
                    speakerLabels: false
                )) { update in
                    Task { @MainActor in progress = update }
                }
                result = completed
            } catch let error as HighQualityJobError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            task = nil
        }
    }
}
