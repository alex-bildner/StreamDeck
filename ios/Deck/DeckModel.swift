import Foundation
import UIKit

@MainActor
final class DeckModel: ObservableObject {
    @Published var slots: [DeckSlot]
    @Published var links: [LinkSlot]
    @Published var connection: Connection
    @Published var apps: [DeckAppInfo] = []
    @Published var appsLoading = false
    @Published var appsError: String?
    @Published var icons: [String: UIImage] = [:]
    @Published var customIcons: [String: UIImage] = [:]
    @Published var banner: String?
    @Published var lifting = false

    private let store = DeckStore()
    private let api = CompanionClient()
    private var endpoint: Endpoint?
    private var revision: Int
    private var dirty = false
    private var seenStamp: Int?
    private var syncTask: Task<Void, Never>?

    init() {
        let saved = store.load()
        endpoint = saved.endpoint
        slots = saved.slots
        links = saved.links
        revision = saved.revision
        connection = saved.endpoint == nil ? .noHost : .checking
        slots.forEach { loadCustom($0.key); if let id = $0.app?.id { requestIcon(id) } }
        links.forEach { loadCustom($0.key) }
        syncTask = Task { await syncLoop() }
        if endpoint != nil { Task { await refreshConnection() } }
    }

    func refreshConnection() async {
        guard let endpoint else {
            connection = .noHost
            return
        }
        connection = .checking
        switch await api.health(endpoint) {
        case .ok(let value):
            connection = .online(value.0)
            noteStamp(value.1)
        case .fail(let message):
            connection = .offline(message)
        }
    }

    func connect(address: String, token: String) async -> String? {
        guard let parsed = parseAddress(address) else {
            return "Informe o endereço, por exemplo 192.168.0.10:8765."
        }
        let code = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.count < 4 { return "Informe o código mostrado no notebook." }
        let candidate = Endpoint(host: parsed.0, port: parsed.1, token: code)
        connection = .checking
        switch await api.health(candidate) {
        case .ok(let value):
            endpoint = candidate
            connection = .online(value.0)
            noteStamp(value.1)
            dirty = true
            persist()
            await push()
            slots.compactMap { $0.app?.id }.forEach { requestIcon($0) }
            return nil
        case .fail(let message):
            connection = endpoint == nil ? .noHost : .offline(message)
            return message
        }
    }

    func loadApps() async {
        guard let endpoint else {
            apps = []
            appsError = "Conecte ao notebook primeiro."
            return
        }
        appsLoading = true
        appsError = nil
        switch await api.apps(endpoint) {
        case .ok(let list):
            apps = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .fail(let message):
            apps = []
            appsError = message
        }
        appsLoading = false
    }

    func launch(_ index: Int) {
        guard let app = slots[safe: index]?.app else { return }
        guard let endpoint else {
            banner = "Conecte ao notebook para abrir o app."
            return
        }
        Task {
            if case .fail(let message) = await api.launch(endpoint, id: app.id) {
                banner = message
            }
        }
    }

    func openLink(_ index: Int) {
        guard let url = links[safe: index]?.link?.url else { return }
        guard let endpoint else {
            banner = "Conecte ao notebook para abrir o link."
            return
        }
        Task {
            if case .fail(let message) = await api.openURL(endpoint, url: url) {
                banner = message
            }
        }
    }

    func assign(_ index: Int, app: DeckAppInfo) async -> String? {
        guard let endpoint else { return "Conecte ao notebook primeiro." }
        guard slots.indices.contains(index) else { return "Botão inválido." }
        let file = store.iconFile(app.id)
        if !FileManager.default.fileExists(atPath: file.path) {
            switch await api.downloadIcon(endpoint, id: app.id) {
            case .ok(let data):
                try? data.write(to: file, options: .atomic)
                if let image = UIImage(data: data) { setIcon(app.id, image) }
            case .fail(let message):
                return message
            }
        } else if let image = UIImage(contentsOfFile: file.path) {
            setIcon(app.id, image)
        }
        slots[index].app = app
        dirty = true
        persist()
        await push()
        return nil
    }

    func clearApp(_ index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index].app = nil
        dirty = true
        persist()
        Task { await push() }
    }

    func setLink(_ index: Int, title: String, url: String) -> String? {
        guard let normalized = normalizeWebURL(url) else { return "Use um endereço http ou https." }
        guard links.indices.contains(index) else { return "Botão inválido." }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        links[index].link = BrowserLink(title: name.isEmpty ? normalized : name, url: normalized)
        dirty = true
        persist()
        Task { await push() }
        return nil
    }

    func clearLink(_ index: Int) {
        guard links.indices.contains(index) else { return }
        links[index].link = nil
        dirty = true
        persist()
        Task { await push() }
    }

    func moveApps(from: Int, to: Int) {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to) else { return }
        let item = slots.remove(at: from)
        slots.insert(item, at: to)
    }

    func moveLinks(from: Int, to: Int) {
        guard from != to, links.indices.contains(from), links.indices.contains(to) else { return }
        let item = links.remove(at: from)
        links.insert(item, at: to)
    }

    func finishReorder() {
        lifting = false
        dirty = true
        persist()
        Task { await push() }
    }

    func setSlotIcon(page: Int, index: Int, image: UIImage) {
        guard let key = key(page, index), let png = image.pngData() else {
            banner = "Não consegui ler essa imagem."
            return
        }
        let file = store.customIconFile(key)
        try? png.write(to: file, options: .atomic)
        var next = customIcons
        next[key] = image
        customIcons = next
        dirty = true
        persist()
        Task { await push() }
    }

    func clearSlotIcon(page: Int, index: Int) {
        guard let key = key(page, index) else { return }
        try? FileManager.default.removeItem(at: store.customIconFile(key))
        var next = customIcons
        next.removeValue(forKey: key)
        customIcons = next
        dirty = true
        if page == 0, let id = slots[safe: index]?.app?.id, let endpoint {
            Task {
                await api.deleteCustomIcon(endpoint, id: id)
                await reloadIcon(id)
            }
        }
        persist()
        Task { await push() }
    }

    func hasCustom(page: Int, index: Int) -> Bool {
        guard let key = key(page, index) else { return false }
        return customIcons[key] != nil
    }

    private func key(_ page: Int, _ index: Int) -> String? {
        page == 0 ? slots[safe: index]?.key : links[safe: index]?.key
    }

    private func requestIcon(_ id: String) {
        if icons[id] != nil { return }
        let file = store.iconFile(id)
        if let image = UIImage(contentsOfFile: file.path) {
            setIcon(id, image)
            return
        }
        guard let endpoint else { return }
        Task {
            if case .ok(let data) = await api.downloadIcon(endpoint, id: id) {
                try? data.write(to: file, options: .atomic)
                if let image = UIImage(data: data) { setIcon(id, image) }
            }
        }
    }

    private func reloadIcon(_ id: String) async {
        var next = icons
        next.removeValue(forKey: id)
        icons = next
        try? FileManager.default.removeItem(at: store.iconFile(id))
        requestIcon(id)
    }

    private func setIcon(_ id: String, _ image: UIImage) {
        var next = icons
        next[id] = image
        icons = next
    }

    private func loadCustom(_ key: String) {
        guard let image = UIImage(contentsOfFile: store.customIconFile(key).path) else { return }
        var next = customIcons
        next[key] = image
        customIcons = next
    }

    private func persist() {
        store.save(DeckSnapshot(endpoint: endpoint, slots: slots, links: links, revision: revision))
    }

    private func customKeySet() -> Set<String> {
        Set((slots.map(\.key) + links.map(\.key)).filter {
            FileManager.default.fileExists(atPath: store.customIconFile($0).path)
        })
    }

    private func syncLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await syncOnce()
        }
    }

    private func syncOnce() async {
        guard let endpoint else { return }
        if case .ok(let health) = await api.health(endpoint) {
            if connection != .online(health.0) { connection = .online(health.0) }
            noteStamp(health.1)
        }
        guard case .ok(let remote) = await api.fetchDeck(endpoint) else { return }
        if remote.revision == 0 || dirty {
            await push()
            return
        }
        if remote.revision > revision {
            await apply(remote)
        }
    }

    private func push() async {
        guard let endpoint, dirty else { return }
        let keys = customKeySet()
        for key in keys {
            guard let data = try? Data(contentsOf: store.customIconFile(key)) else { continue }
            if case .fail = await api.uploadPhoneIcon(endpoint, key: key, png: data) { return }
        }
        switch await api.pushDeck(endpoint, base: revision, slots: slots, links: links, custom: keys) {
        case .ok(let value):
            revision = value
            dirty = false
            persist()
        case .fail(let message):
            if message == "conflito", case .ok(let remote) = await api.fetchDeck(endpoint), remote.revision > 0 {
                await apply(remote)
            }
        }
    }

    private func apply(_ remote: RemoteDeck) async {
        revision = remote.revision
        if !remote.slots.isEmpty { slots = remote.slots }
        if !remote.links.isEmpty { links = remote.links }
        dirty = false
        persist()
        guard let endpoint else { return }
        for slot in slots + links.map({ DeckSlot(key: $0.key, app: nil) }) {
            let file = store.customIconFile(slot.key)
            if remote.customKeys.contains(slot.key) {
                if case .ok(let data) = await api.downloadPhoneIcon(endpoint, key: slot.key) {
                    try? data.write(to: file, options: .atomic)
                    if let image = UIImage(data: data) {
                        var next = customIcons
                        next[slot.key] = image
                        customIcons = next
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: file)
                var next = customIcons
                next.removeValue(forKey: slot.key)
                customIcons = next
            }
        }
        slots.compactMap { $0.app?.id }.forEach { requestIcon($0) }
    }

    private func noteStamp(_ stamp: Int) {
        let previous = seenStamp
        if previous == stamp { return }
        seenStamp = stamp
        if previous != nil || stamp > 0 {
            for id in Set(slots.compactMap { $0.app?.id }) {
                Task { await reloadIcon(id) }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
