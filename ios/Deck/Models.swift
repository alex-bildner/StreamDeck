import Foundation

let slotCount = 10

struct DeckAppInfo: Identifiable, Equatable, Codable {
    var id: String
    var name: String
}

struct DeckSlot: Identifiable, Equatable {
    var key: String
    var app: DeckAppInfo?
    var id: String { key }
}

struct BrowserLink: Equatable {
    var title: String
    var url: String
}

struct LinkSlot: Identifiable, Equatable {
    var key: String
    var link: BrowserLink?
    var id: String { key }
}

struct Endpoint: Equatable {
    var host: String
    var port: Int
    var token: String

    var address: String {
        port == 8765 ? host : "\(host):\(port)"
    }
}

struct DiscoveredMac: Identifiable, Equatable {
    var name: String
    var host: String
    var port: Int
    var id: String { "\(name)|\(host)|\(port)" }
    var address: String { port == 8765 ? host : "\(host):\(port)" }
}

enum Connection: Equatable {
    case noHost
    case checking
    case online(String)
    case offline(String)
}

struct RemoteDeck {
    var revision: Int
    var slots: [DeckSlot]
    var links: [LinkSlot]
    var customKeys: Set<String>
}

func freshSlots() -> [DeckSlot] {
    (0..<slotCount).map { _ in DeckSlot(key: UUID().uuidString) }
}

func freshLinks() -> [LinkSlot] {
    (0..<slotCount).map { _ in LinkSlot(key: UUID().uuidString) }
}

func normalizeWebURL(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if !text.contains("://") { text = "https://\(text)" }
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty else { return nil }
    return url.absoluteString
}

func parseAddress(_ raw: String) -> (String, Int)? {
    let text = stripInterface(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    if text.isEmpty { return nil }
    if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
        let host = String(text[..<colon])
        let port = Int(text[text.index(after: colon)...]) ?? 0
        if host.isEmpty || !(1...65535).contains(port) { return nil }
        return (host, port)
    }
    return (text, 8765)
}

func stripInterface(_ raw: String) -> String {
    guard let zone = raw.range(of: #"%[A-Za-z0-9._-]+"#, options: .regularExpression) else { return raw }
    return raw.replacingCharacters(in: zone, with: "")
}
