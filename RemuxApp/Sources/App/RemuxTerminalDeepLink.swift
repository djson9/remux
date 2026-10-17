import Foundation

/// A saved SSH connection and a tmux-style session:window.pane address.
struct RemuxTerminalDeepLink: Equatable, Sendable {
    let server: String
    let target: String

    var sessionName: String {
        let name = String(target.prefix { $0 != ":" })
        return name.hasPrefix("=") ? String(name.dropFirst()) : name
    }

    init(server: String, target: String) {
        self.server = server
        self.target = target
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "remuxdev", parts.host?.lowercased() == "open",
              parts.path.isEmpty || parts.path == "/",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "server" }).count == 1,
              items.filter({ $0.name == "target" }).count == 1,
              let server = items.first(where: { $0.name == "server" })?.value, !server.isEmpty,
              let target = items.first(where: { $0.name == "target" })?.value,
              let colon = target.firstIndex(of: ":"), colon != target.startIndex,
              target.index(after: colon) != target.endIndex,
              !server.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !target.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        self.init(server: server, target: target)
        guard !sessionName.isEmpty else { return nil }
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "remuxdev"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "target", value: target)]
        return parts.url!
    }

    enum OpenError: LocalizedError {
        case savedServer, ambiguousServer, missingSession, missingPane, busy, connection, timeout

        var errorDescription: String? {
            switch self {
            case .savedServer: "This link’s server is not saved in Remux Dev."
            case .ambiguousServer: "More than one saved connection matches this server. Use a link copied from Panes."
            case .missingSession: "This tmux session is no longer available."
            case .missingPane: "This window or pane is no longer available."
            case .busy: "Finish the current connection setup or send, then open the link again."
            case .connection: "Couldn’t connect to this link’s session. Check the connection in Remux Dev."
            case .timeout: "The link’s pane did not become ready. Check the connection and try again."
            }
        }
    }
}

struct TmuxResolvedPaneTarget: Equatable, Sendable {
    let sessionName: String
    let windowID: TmuxWindowID
    let paneID: TmuxPaneID

    init?(reply: String) {
        let fields = reply.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[0].isEmpty, fields[1].hasPrefix("@"), fields[2].hasPrefix("%"),
              let window = UInt64(fields[1].dropFirst()), let pane = UInt64(fields[2].dropFirst()) else { return nil }
        sessionName = String(fields[0])
        windowID = TmuxWindowID(window)
        paneID = TmuxPaneID(pane)
    }

    static func resolve(reply: String, target: String) -> Self? {
        let address = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
        let selector: Substring?
        if let dot = address.lastIndex(of: ".") {
            selector = address[address.index(after: dot)...]
        } else {
            selector = address.hasPrefix("%") ? address : nil
        }
        for line in reply.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5 else { continue }
            let matches: Bool
            if let selector {
                matches = selector.hasPrefix("%") ? fields[2] == selector
                    : UInt64(selector).map { UInt64(fields[3]) == $0 } == true
            } else {
                matches = fields[4] == "1"
            }
            if matches {
                return Self(reply: fields.prefix(3).joined(separator: "\t"))
            }
        }
        return nil
    }
}
