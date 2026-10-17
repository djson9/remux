import SwiftUI

struct RemuxDictationSettingsView: View {
    @AppStorage(RemuxDictationEngine.preferenceKey) private var engine = RemuxDictationEngine.apple.rawValue
    @State private var status = RemuxParakeetStatus.missing

    var body: some View {
        Form {
            Section {
                Picker("Dictation engine", selection: $engine) {
                    ForEach(RemuxDictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("dictation.engine")
            } footer: {
                Text("Used by the composer microphone and Action Button. Changes apply to your next recording.")
            }

            if engine == RemuxDictationEngine.parakeet.rawValue {
                Section {
                    LabeledContent("Model", value: "Parakeet TDT v2 · INT8")
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("dictation.model")
                        .accessibilityValue("Parakeet TDT v2 · INT8")
                    statusView
                    if !status.isPreparing && status != .ready {
                        Button("Download / Load Parakeet") {
                            Task { try? await RemuxParakeetModel.shared.prepare(allowDownload: true) }
                        }
                        .accessibilityIdentifier("dictation.prepare-parakeet")
                    }
                } header: {
                    Text("Parakeet")
                } footer: {
                    Text("English dictation, using the same model as ACP Web. Downloads about 487 MB once, then works offline. Each app keeps its own download. Stop recording to see the transcript.")
                }
            } else {
                Section {
                    Text("Apple’s on-device speech recognition uses your current language.")
                }
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for await value in await RemuxParakeetModel.shared.updates() { status = value }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .missing: Text("Model not downloaded")
        case .downloaded: Text("Downloaded · Ready to load")
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%") }
        case .loading: ProgressView("Loading Parakeet…")
        case .ready: Label("Ready · On device", systemImage: "checkmark.circle")
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}
