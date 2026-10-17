import AppIntents
import Combine
import Foundation

/// Retains a foreground request while the app loads its saved sessions.
@MainActor
final class RemuxVoiceComposerEntry: ObservableObject {
    static let shared = RemuxVoiceComposerEntry()
    @Published private(set) var pendingRequestID: UUID?

    func request() {
        guard pendingRequestID == nil else { return }
        pendingRequestID = UUID()
    }

    func consume(_ id: UUID) {
        guard pendingRequestID == id else { return }
        pendingRequestID = nil
    }

    func cancel() {
        pendingRequestID = nil
    }

    nonisolated static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "remuxdev"
            && url.host?.lowercased() == "record"
            && (url.path.isEmpty || url.path == "/")
            && url.query == nil && url.fragment == nil
    }
}

struct RecordInRemuxComposerIntent: AppIntent {
    static let title: LocalizedStringResource = "Record in Composer"
    static let description = IntentDescription(
        "Opens the Remux Dev composer and starts dictation, or stops an active recording and keeps the transcript."
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        RemuxVoiceComposerEntry.shared.request()
        return .result()
    }
}

@available(iOS 26.0, *)
extension RecordInRemuxComposerIntent {
    static var supportedModes: IntentModes { .foreground }
}

@available(iOS, introduced: 18.0, deprecated: 26.0, message: "Uses supportedModes on iOS 26 and later.")
extension RecordInRemuxComposerIntent {
    static var openAppWhenRun: Bool { true }
}

struct RemuxDevAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordInRemuxComposerIntent(),
            phrases: ["Record in \(.applicationName)"],
            shortTitle: "Record in Composer",
            systemImageName: "mic.fill"
        )
    }
}
