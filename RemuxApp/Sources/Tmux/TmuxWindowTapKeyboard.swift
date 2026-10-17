import Foundation

/// Window options survive reattachment and renaming, and disappear with the
/// window. This avoids reusing a local preference when a tmux server restarts.
enum TmuxWindowTapKeyboard {
    static let optionName = "@remux-dev-tap-keyboard"
    static let query = "list-windows -F '#{window_id} #{\(optionName)}'"

    static func command(windowID: TmuxWindowID, behavior: WindowTapKeyboardBehavior) -> String {
        if behavior == .useDefault {
            return "set-option -w -u -t @\(windowID.rawValue) \(optionName)"
        }
        return "set-option -w -t @\(windowID.rawValue) \(optionName) \(behavior.rawValue)"
    }

    static func settings(from reply: String) -> [TmuxWindowID: WindowTapKeyboardBehavior] {
        var settings: [TmuxWindowID: WindowTapKeyboardBehavior] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0].first == "@",
                  let id = UInt64(fields[0].dropFirst()),
                  let behavior = WindowTapKeyboardBehavior(rawValue: String(fields[1])),
                  behavior != .useDefault else { continue }
            settings[TmuxWindowID(id)] = behavior
        }
        return settings
    }
}
