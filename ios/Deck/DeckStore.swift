import Foundation

struct DeckSnapshot {
    var endpoint: Endpoint?
    var slots: [DeckSlot]
    var links: [LinkSlot]
    var revision: Int
}

final class DeckStore {
    private let folder: URL
    private let file: URL
    let iconDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Deck", isDirectory: true)
        file = folder.appendingPathComponent("deck.json")
        iconDir = folder.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
    }

    func load() -> DeckSnapshot {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DeckSnapshot(endpoint: nil, slots: freshSlots(), links: freshLinks(), revision: 0)
        }
        let host = (root["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = root["port"] as? Int ?? 8765
        let token = (root["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let endpoint = (!host.isEmpty && !token.isEmpty && (1...65535).contains(port))
            ? Endpoint(host: host, port: port, token: token) : nil
        let revision = root["revision"] as? Int ?? Int(root["revision"] as? Double ?? 0)
        return DeckSnapshot(
            endpoint: endpoint,
            slots: parseSlots(root["slots"]),
            links: parseLinks(root["links"]),
            revision: revision
        )
    }

    func save(_ snapshot: DeckSnapshot) {
        var slots: [[String: Any]] = []
        for slot in snapshot.slots {
            var item: [String: Any] = ["key": slot.key]
            if let app = slot.app {
                item["id"] = app.id
                item["name"] = app.name
            }
            slots.append(item)
        }
        var links: [[String: Any]] = []
        for slot in snapshot.links {
            var item: [String: Any] = ["key": slot.key]
            if let link = slot.link {
                item["title"] = link.title
                item["url"] = link.url
            }
            links.append(item)
        }
        let root: [String: Any] = [
            "host": snapshot.endpoint?.host ?? "",
            "port": snapshot.endpoint?.port ?? 8765,
            "token": snapshot.endpoint?.token ?? "",
            "slots": slots,
            "links": links,
            "revision": snapshot.revision,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func iconFile(_ appId: String) -> URL {
        iconDir.appendingPathComponent(safe(appId) + ".png")
    }

    func customIconFile(_ key: String) -> URL {
        iconDir.appendingPathComponent("custom_" + safe(key) + ".png")
    }

    private func safe(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            let ok = CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
            return ok ? Character(scalar) : "_"
        }
        return String(cleaned.prefix(180))
    }

    private func parseSlots(_ raw: Any?) -> [DeckSlot] {
        var parsed: [DeckSlot] = []
        for item in (raw as? [[String: Any]] ?? []) {
            let key = (item["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let id = item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let app = id.isEmpty ? nil : DeckAppInfo(id: id, name: name.isEmpty ? id : name)
            parsed.append(DeckSlot(key: key, app: app))
        }
        return Array((parsed + freshSlots()).prefix(slotCount))
    }

    private func parseLinks(_ raw: Any?) -> [LinkSlot] {
        var parsed: [LinkSlot] = []
        for item in (raw as? [[String: Any]] ?? []) {
            let key = (item["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let url = item["url"] as? String ?? ""
            let title = item["title"] as? String ?? ""
            let link = url.isEmpty ? nil : BrowserLink(title: title.isEmpty ? url : title, url: url)
            parsed.append(LinkSlot(key: key, link: link))
        }
        return Array((parsed + freshLinks()).prefix(slotCount))
    }
}
