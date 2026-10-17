import Foundation

enum TmuxWindowFontSize {
    static let optionName = "@remux-dev-font-size"
    static let query = "list-windows -F '#{window_id} #{\(optionName)}'"

    static func validated(_ size: Float32?) -> Float32? {
        guard let size, size.isFinite,
              (TerminalSettings.minimumFontSize...TerminalSettings.maximumFontSize).contains(size) else { return nil }
        return size
    }

    static func command(windowID: TmuxWindowID, size: Float32?) -> String {
        guard let size = validated(size) else {
            return "set-option -w -u -t @\(windowID.rawValue) \(optionName)"
        }
        return "set-option -w -t @\(windowID.rawValue) \(optionName) \(size)"
    }

    static func settings(from reply: String) -> [TmuxWindowID: Float32] {
        var settings: [TmuxWindowID: Float32] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0].first == "@",
                  let id = UInt64(fields[0].dropFirst()),
                  let size = validated(Float32(fields[1])) else { continue }
            settings[TmuxWindowID(id)] = size
        }
        return settings
    }
}

/// Separates the immediately visible choice from acknowledged saves. A late
/// read or failed earlier write must not replace a more recent window choice.
struct TmuxWindowFontSizeState {
    private(set) var revision: UInt64 = 0
    private var values: [TmuxWindowID: Float32] = [:]
    private var confirmed: [TmuxWindowID: Float32] = [:]
    private var mutations: [TmuxWindowID: UInt64] = [:]
    private var confirmations: [TmuxWindowID: UInt64] = [:]

    func value(for windowID: TmuxWindowID) -> Float32? { values[windowID] }

    mutating func apply(_ snapshot: [TmuxWindowID: Float32], windows: [TmuxWindowID], readRevision: UInt64) {
        for id in windows where (mutations[id] ?? 0) <= readRevision {
            values[id] = snapshot[id]
            confirmed[id] = snapshot[id]
            confirmations[id] = max(confirmations[id] ?? 0, readRevision)
        }
    }

    mutating func change(_ size: Float32?, in windowID: TmuxWindowID) -> UInt64 {
        revision &+= 1
        mutations[windowID] = revision
        values[windowID] = TmuxWindowFontSize.validated(size)
        return revision
    }

    /// Returns true only when the latest visible save failed and was reverted.
    mutating func complete(_ size: Float32?, in windowID: TmuxWindowID, revision: UInt64, succeeded: Bool) -> Bool {
        if succeeded {
            guard revision >= (confirmations[windowID] ?? 0) else { return false }
            confirmations[windowID] = revision
            confirmed[windowID] = TmuxWindowFontSize.validated(size)
            if (mutations[windowID] ?? 0) <= revision {
                values[windowID] = confirmed[windowID]
                mutations[windowID] = revision
            }
        } else if mutations[windowID] == revision {
            values[windowID] = confirmed[windowID]
            mutations[windowID] = confirmations[windowID] ?? 0
            return true
        }
        return false
    }
}
