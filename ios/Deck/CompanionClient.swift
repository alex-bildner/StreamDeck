import Foundation
import UIKit

enum Net<T> {
    case ok(T)
    case fail(String)
}

private let invalidAddress = "Endereço do notebook inválido. Use o IP, por exemplo 192.168.0.10."

struct CompanionClient {
    func health(_ endpoint: Endpoint) async -> Net<(String, Int)> {
        switch await call(endpoint, "/api/health") {
        case .fail(let message):
            return .fail(message)
        case .ok(let data):
            guard let root = jsonObject(data),
                  let name = root["hostname"] as? String, !name.isEmpty else {
                return .fail("Resposta inválida do notebook.")
            }
            let stamp = root["iconStamp"] as? Int ?? Int(root["iconStamp"] as? Double ?? 0)
            return .ok((name, stamp))
        }
    }

    func apps(_ endpoint: Endpoint) async -> Net<[DeckAppInfo]> {
        switch await call(endpoint, "/api/apps") {
        case .fail(let message):
            return .fail(message)
        case .ok(let data):
            guard let rows = jsonArray(data) else { return .fail("A lista de apps veio incompleta.") }
            let apps = rows.compactMap { item -> DeckAppInfo? in
                guard let id = item["id"] as? String, let name = item["name"] as? String,
                      !id.isEmpty, !name.isEmpty else { return nil }
                return DeckAppInfo(id: id, name: name)
            }
            return .ok(apps)
        }
    }

    func launch(_ endpoint: Endpoint, id: String) async -> Net<Void> {
        switch await call(endpoint, "/api/launch", ["id": id]) {
        case .fail(let message): return .fail(message)
        case .ok: return .ok(())
        }
    }

    func openURL(_ endpoint: Endpoint, url: String) async -> Net<Void> {
        switch await call(endpoint, "/api/open-url", ["url": url]) {
        case .fail(let message): return .fail(message)
        case .ok: return .ok(())
        }
    }

    func fetchDeck(_ endpoint: Endpoint) async -> Net<RemoteDeck> {
        switch await call(endpoint, "/api/deck") {
        case .fail(let message):
            return .fail(message)
        case .ok(let data):
            guard let deck = parseDeck(data) else { return .fail("O deck do celular veio incompleto.") }
            return .ok(deck)
        }
    }

    func pushDeck(_ endpoint: Endpoint, base: Int, slots: [DeckSlot], links: [LinkSlot], custom: Set<String>) async -> Net<Int> {
        let body: [String: Any] = [
            "base": base,
            "slots": slots.map { slot -> [String: Any] in
                var row: [String: Any] = ["key": slot.key, "custom": custom.contains(slot.key)]
                if let app = slot.app {
                    row["id"] = app.id
                    row["name"] = app.name
                }
                return row
            },
            "links": links.map { slot -> [String: Any] in
                var row: [String: Any] = ["key": slot.key, "custom": custom.contains(slot.key)]
                if let link = slot.link {
                    row["title"] = link.title
                    row["url"] = link.url
                }
                return row
            },
        ]
        switch await send(endpoint, "/api/deck", body) {
        case .fail(let message):
            return .fail(message)
        case .ok(let data):
            let revision = (jsonObject(data)?["revision"] as? Int) ?? Int(jsonObject(data)?["revision"] as? Double ?? -1)
            return revision < 0 ? .fail("Resposta inválida do notebook.") : .ok(revision)
        }
    }

    func uploadPhoneIcon(_ endpoint: Endpoint, key: String, png: Data) async -> Net<Void> {
        let path = "/api/phone-icon/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)"
        guard var request = authorized(endpoint, path) else { return .fail(invalidAddress) }
        request.httpMethod = "POST"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = png
        return await result(request).map { _ in () }
    }

    func downloadPhoneIcon(_ endpoint: Endpoint, key: String) async -> Net<Data> {
        let path = "/api/phone-icon/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)"
        return await image(endpoint, path)
    }

    func downloadIcon(_ endpoint: Endpoint, id: String) async -> Net<Data> {
        let path = "/api/icons/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        return await image(endpoint, path)
    }

    func deleteCustomIcon(_ endpoint: Endpoint, id: String) async {
        let path = "/api/custom-icon/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        guard var request = authorized(endpoint, path) else { return }
        request.httpMethod = "DELETE"
        _ = await result(request)
    }

    private func image(_ endpoint: Endpoint, _ path: String) async -> Net<Data> {
        guard var request = authorized(endpoint, path) else { return .fail(invalidAddress) }
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        switch await result(request) {
        case .fail(let message):
            return .fail(message)
        case .ok(let data):
            guard data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                return .fail("Ícone inválido.")
            }
            return .ok(data)
        }
    }

    private func call(_ endpoint: Endpoint, _ path: String, _ body: [String: Any]? = nil) async -> Net<Data> {
        if let body { return await send(endpoint, path, body) }
        guard let request = authorized(endpoint, path) else { return .fail(invalidAddress) }
        return await result(request)
    }

    private func send(_ endpoint: Endpoint, _ path: String, _ body: [String: Any]) async -> Net<Data> {
        guard var request = authorized(endpoint, path) else { return .fail(invalidAddress) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await result(request)
    }

    private func authorized(_ endpoint: Endpoint, _ path: String) -> URLRequest? {
        var parts = URLComponents()
        parts.scheme = "http"
        let host = stripInterface(endpoint.host).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = endpoint.port
        parts.path = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(endpoint.token, forHTTPHeaderField: "X-Deck-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func result(_ request: URLRequest) async -> Net<Data> {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .fail("Código incorreto.") }
            if code == 409 { return .fail("conflito") }
            if !(200..<300).contains(code) {
                let message = (jsonObject(data)?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .fail(message ?? "O notebook respondeu com erro (\(code)).")
            }
            return .ok(data)
        } catch {
            return .fail("Não encontrei o Mac. Confira o Wi-Fi e se o app Deck está aberto nele.")
        }
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func jsonArray(_ data: Data) -> [[String: Any]]? {
        try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    private func parseDeck(_ data: Data) -> RemoteDeck? {
        guard let root = jsonObject(data) else { return nil }
        let revision = root["revision"] as? Int ?? Int(root["revision"] as? Double ?? 0)
        return RemoteDeck(
            revision: revision,
            slots: parseRemoteSlots(root["slots"]),
            links: parseRemoteLinks(root["links"]),
            customKeys: customKeys(root["slots"]) .union(customKeys(root["links"]))
        )
    }

    private func customKeys(_ raw: Any?) -> Set<String> {
        var keys = Set<String>()
        for item in raw as? [[String: Any]] ?? [] {
            if (item["custom"] as? Bool) == true, let key = item["key"] as? String, !key.isEmpty {
                keys.insert(key)
            }
        }
        return keys
    }

    private func parseRemoteSlots(_ raw: Any?) -> [DeckSlot] {
        var parsed: [DeckSlot] = []
        for item in raw as? [[String: Any]] ?? [] {
            guard let key = item["key"] as? String, !key.isEmpty else { continue }
            let id = item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let app = id.isEmpty ? nil : DeckAppInfo(id: id, name: name.isEmpty ? id : name)
            parsed.append(DeckSlot(key: key, app: app))
        }
        return Array((parsed + freshSlots()).prefix(slotCount))
    }

    private func parseRemoteLinks(_ raw: Any?) -> [LinkSlot] {
        var parsed: [LinkSlot] = []
        for item in raw as? [[String: Any]] ?? [] {
            guard let key = item["key"] as? String, !key.isEmpty else { continue }
            let url = item["url"] as? String ?? ""
            let title = item["title"] as? String ?? ""
            let link = url.isEmpty ? nil : BrowserLink(title: title.isEmpty ? url : title, url: url)
            parsed.append(LinkSlot(key: key, link: link))
        }
        return Array((parsed + freshLinks()).prefix(slotCount))
    }
}

private extension Net where T == Data {
    func map<U>(_ transform: (Data) -> U) -> Net<U> {
        switch self {
        case .ok(let data): return .ok(transform(data))
        case .fail(let message): return .fail(message)
        }
    }
}
