import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ListedApp: Identifiable, Decodable {
    let id: String
    let name: String
    var replaced: Bool

    init(id: String, name: String, replaced: Bool = false) {
        self.id = id
        self.name = name
        self.replaced = replaced
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        replaced = try container.decodeIfPresent(Bool.self, forKey: .replaced) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, replaced
    }
}

final class DeckDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CompanionModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompanionModel.shared.stopOwnedProcess()
    }
}

@MainActor
final class CompanionModel: ObservableObject {
    static let shared = CompanionModel()

    @Published var code = "------"
    @Published var addresses: [String] = []
    @Published var status = "Iniciando…"
    @Published var detail = ""
    @Published var running = false
    @Published var apps: [ListedApp] = []
    @Published var appsMessage = ""
    @Published var launchAtLogin = true
    @Published var appSlots: [PhoneSlot] = []
    @Published var linkSlots: [PhoneSlot] = []
    @Published var images: [String: NSImage] = [:]
    @Published var phoneReady = false
    @Published var awaitingPhone = false
    @Published var dirty = false
    @Published var savingDeck = false
    @Published var deckMessage = ""
    @Published var phoneSeen = Date.distantPast
    @Published var editingKey: String?

    private var deckRevision = 0
    private var pendingIcons: [String: Data] = [:]
    private var watcher: Task<Void, Never>?
    private var process: Process?
    private var ownsProcess = false
    private var service: NetService?
    private var serverURL: URL?
    private let port = 8765
    private let agentLabel = "com.deck.companion"

    func start() {
        launchAtLogin = storedLaunchAtLogin()
        guard let server = locateServer() else {
            status = "Não encontrei o companion"
            detail = "Escolha o arquivo server.py da pasta companion."
            return
        }
        serverURL = server
        addresses = localIPv4()
        guard let python = pythonExecutable() else {
            status = "Python 3 não encontrado"
            detail = "Instale o Python 3 para o Deck iniciar a conexão."
            return
        }
        Task { await bringUp(server: server, python: python) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        UserDefaults.standard.set(enabled, forKey: "deck.launchAtLogin")
        guard let server = serverURL ?? locateServer(), let python = pythonExecutable() else { return }
        Task { await bringUp(server: server, python: python) }
    }

    func stopOwnedProcess() {
        service?.stop()
        service = nil
        if ownsProcess {
            process?.terminate()
        }
        process = nil
        ownsProcess = false
    }

    private func bringUp(server: URL, python: URL) async {
        if launchAtLogin {
            if ownsProcess {
                stopOwnedProcess()
                for _ in 0..<10 {
                    if !portOpen(port) { break }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            installAgent(python: python, server: server)
        } else {
            removeAgent()
        }
        var ready = portOpen(port)
        if launchAtLogin && !ready {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if portOpen(port) {
                    ready = true
                    break
                }
            }
        }
        if !ready {
            spawnInProcess(python: python, server: server)
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                loadToken(beside: server)
                if portOpen(port) { break }
            }
        }
        loadToken(beside: server)
        if await deckStatus() == 404 {
            await replaceStaleCompanion(python: python, server: server)
        }
        addresses = localIPv4()
        publish()
        let listening = portOpen(port)
        running = listening
        if listening && launchAtLogin && agentIsRunning() {
            status = "Conectado em segundo plano"
            detail = "Pode fechar esta janela e o Terminal. O celular continua conectado, inclusive depois de reiniciar o Mac."
        } else if listening && launchAtLogin {
            status = "Conectado"
            detail = "Feche o Terminal se o Deck ainda estiver aberto nele e abra este app outra vez. Depois pode fechar tudo."
        } else if listening {
            status = "Conectado"
            detail = "Pode fechar esta janela. A conexão fica ativa enquanto o Deck não for encerrado."
        } else {
            status = "Não consegui iniciar"
            detail = "Feche o Terminal se o Deck ainda estiver aberto nele e abra este app de novo."
        }
        if listening {
            beginWatching()
        }
    }

    private func spawnInProcess(python: URL, server: URL) {
        if ownsProcess { return }
        let process = Process()
        process.executableURL = python
        process.arguments = [server.path]
        process.currentDirectoryURL = server.deletingLastPathComponent()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("deck-companion.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            self.process = process
            ownsProcess = true
        } catch {
            status = "Não consegui iniciar"
            detail = error.localizedDescription
        }
    }

    private func installAgent(python: URL, server: URL) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = folder.appendingPathComponent("\(agentLabel).plist")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(python.path))</string>
                <string>\(xmlEscape(server.path))</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(xmlEscape(server.deletingLastPathComponent().path))</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """
        try? xml.write(to: plist, atomically: true, encoding: .utf8)
        let domain = "gui/\(getuid())"
        runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
        runLaunchctl(["bootstrap", domain, plist.path])
        runLaunchctl(["enable", "\(domain)/\(agentLabel)"])
    }

    private func removeAgent() {
        let domain = "gui/\(getuid())"
        runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
    }

    private func storedLaunchAtLogin() -> Bool {
        if UserDefaults.standard.object(forKey: "deck.launchAtLogin") == nil { return true }
        return UserDefaults.standard.bool(forKey: "deck.launchAtLogin")
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        _ = launchctlOutput(arguments)
        return 0
    }

    private func agentIsRunning() -> Bool {
        launchctlOutput(["print", "gui/\(getuid())/\(agentLabel)"]).contains("state = running")
    }

    private func launchctlOutput(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func chooseCompanion() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pythonScript, .data]
        panel.message = "Escolha companion/server.py"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "deck.serverPath")
        stopOwnedProcess()
        start()
    }

    func loadApps() {
        appsMessage = ""
        guard let request = authorizedRequest(path: "/api/apps") else {
            appsMessage = "O companion ainda não está pronto."
            return
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            let parsed = data.flatMap { try? JSONDecoder().decode([ListedApp].self, from: $0) }
            Task { @MainActor in
                if http?.statusCode == 200, let parsed {
                    self.apps = parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.appsMessage = parsed.isEmpty ? "Nenhum app encontrado." : ""
                } else {
                    self.appsMessage = "Não consegui ler os apps do Mac."
                }
            }
        }.resume()
    }

    func beginWatching() {
        watcher?.cancel()
        watcher = Task {
            while !Task.isCancelled {
                await refreshPhoneDeck()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refreshPhoneDeck() async {
        guard !savingDeck, let document = await loadDeckDocument() else { return }
        if document.revision > 0 {
            phoneSeen = Date(timeIntervalSince1970: document.updated)
        }
        if document.revision == 0 {
            awaitingPhone = true
            return
        }
        awaitingPhone = false
        if dirty && document.revision != deckRevision {
            deckMessage = "O celular mudou os atalhos. Salve para substituir essa versão, ou feche sem salvar."
            return
        }
        if dirty || document.revision == deckRevision {
            return
        }
        apply(document)
        await loadImages()
    }

    func savePhoneDeck() {
        Task { await savePhoneDeckNow() }
    }

    func chooseApp(_ key: String, app: ListedApp) {
        mutate(key, apps: true) { slot in
            slot.appId = app.id
            slot.name = app.name
        }
        Task { await loadAppImage(app.id) }
    }

    func updateLink(key: String, title: String, url: String) {
        mutate(key, apps: false) { slot in
            slot.title = title
            slot.url = url
            slot.name = title
        }
    }

    func clearShortcut(key: String, apps: Bool) {
        pendingIcons[key] = nil
        mutate(key, apps: apps) { slot in
            slot.appId = ""
            slot.name = ""
            slot.title = ""
            slot.url = ""
            slot.custom = false
        }
        images[key] = nil
    }

    func restoreIcon(key: String, apps: Bool) {
        pendingIcons[key] = nil
        let appId = (apps ? appSlots : linkSlots).first { $0.key == key }?.appId ?? ""
        mutate(key, apps: apps) { slot in
            slot.custom = false
        }
        images[key] = nil
        guard apps, !appId.isEmpty else { return }
        images["app:" + appId] = nil
        Task {
            await clearReplacedIcon(appId)
            await loadAppImage(appId)
        }
    }

    func pickIcon(key: String, apps: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        panel.message = "Escolha o ícone deste atalho"
        guard panel.runModal() == .OK, let source = panel.url, let data = pngData(from: source) else { return }
        pendingIcons[key] = data
        if let image = NSImage(data: data) {
            images[key] = image
        }
        mutate(key, apps: apps) { slot in
            slot.custom = true
        }
    }

    private func savePhoneDeckNow() async {
        guard !savingDeck else { return }
        savingDeck = true
        deckMessage = "Salvando no celular…"
        for (key, data) in pendingIcons {
            let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            guard var request = authorizedRequest(path: "/api/phone-icon/\(encoded)", method: "POST") else {
                savingDeck = false
                deckMessage = "Não consegui enviar um ícone."
                return
            }
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            let result = try? await URLSession.shared.data(for: request)
            let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                savingDeck = false
                deckMessage = "Não consegui enviar um ícone."
                return
            }
        }
        let payload = deckPayload(base: deckRevision)
        guard var request = authorizedRequest(path: "/api/deck", method: "POST") else {
            savingDeck = false
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let result = try? await URLSession.shared.data(for: request)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
        let body = result?.0 ?? Data()
        savingDeck = false
        if status == 409 {
            if let document = parseDeck(body) {
                pendingIcons = [:]
                dirty = false
                apply(document)
                await loadImages()
            }
            deckMessage = "O celular atualizou os atalhos agora. Abri essa versão."
            return
        }
        guard status == 200, let document = parseDeck(body) else {
            deckMessage = "Não consegui salvar. O celular está na mesma rede?"
            return
        }
        pendingIcons = [:]
        dirty = false
        apply(document)
        deckMessage = "Salvo no celular."
    }

    private func loadDeckDocument() async -> DeckDocument? {
        guard let request = authorizedRequest(path: "/api/deck") else { return nil }
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return nil }
        return parseDeck(result.0)
    }

    private func apply(_ document: DeckDocument) {
        deckRevision = document.revision
        appSlots = document.slots
        linkSlots = document.links
        phoneReady = document.revision > 0
        awaitingPhone = false
        phoneSeen = Date(timeIntervalSince1970: document.updated)
    }

    private func loadImages() async {
        for slot in appSlots + linkSlots {
            if slot.custom {
                await loadPhoneImage(slot.key)
            } else if !slot.appId.isEmpty {
                await loadAppImage(slot.appId)
            }
        }
    }

    private func loadPhoneImage(_ key: String) async {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let request = authorizedRequest(path: "/api/phone-icon/\(encoded)") else { return }
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: result.0) else { return }
        images[key] = image
    }

    private func clearReplacedIcon(_ appId: String) async {
        let encoded = appId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appId
        guard let request = authorizedRequest(path: "/api/custom-icon/\(encoded)", method: "DELETE") else { return }
        _ = try? await URLSession.shared.data(for: request)
        if let index = apps.firstIndex(where: { $0.id == appId }) {
            apps[index].replaced = false
        }
    }

    private func loadAppImage(_ appId: String) async {
        if images["app:" + appId] != nil { return }
        let encoded = appId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appId
        guard let request = authorizedRequest(path: "/api/icons/\(encoded)") else { return }
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: result.0) else { return }
        images["app:" + appId] = image
    }

    private func mutate(_ key: String, apps: Bool, _ change: (inout PhoneSlot) -> Void) {
        var list = apps ? appSlots : linkSlots
        guard let index = list.firstIndex(where: { $0.key == key }) else { return }
        change(&list[index])
        if apps {
            appSlots = list
        } else {
            linkSlots = list
        }
        dirty = true
        deckMessage = "Alterações ainda não salvas."
    }

    private func deckPayload(base: Int) -> Data {
        func item(_ slot: PhoneSlot, app: Bool) -> [String: Any] {
            var row: [String: Any] = ["key": slot.key, "custom": slot.custom]
            if app {
                row["id"] = slot.appId
                row["name"] = slot.name
            } else {
                var url = slot.url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty && !url.contains("://") {
                    url = "https://\(url)"
                }
                row["title"] = slot.title.isEmpty ? slot.name : slot.title
                row["url"] = url
            }
            return row
        }
        let body: [String: Any] = [
            "base": base,
            "slots": appSlots.map { item($0, app: true) },
            "links": linkSlots.map { item($0, app: false) },
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func parseDeck(_ data: Data) -> DeckDocument? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let revision = root["revision"] as? Int ?? Int(root["revision"] as? Double ?? 0)
        let updated = root["updated"] as? Double ?? 0
        return DeckDocument(
            revision: revision,
            updated: updated,
            slots: parseSlots(root["slots"]),
            links: parseSlots(root["links"])
        )
    }

    func picture(for slot: PhoneSlot) -> NSImage? {
        if slot.custom, let image = images[slot.key] { return image }
        if !slot.appId.isEmpty, let image = images["app:" + slot.appId] { return image }
        return images[slot.key]
    }

    private func parseSlots(_ raw: Any?) -> [PhoneSlot] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, !key.isEmpty else { return nil }
            return PhoneSlot(
                key: key,
                appId: row["id"] as? String ?? "",
                name: row["name"] as? String ?? "",
                url: row["url"] as? String ?? "",
                title: row["title"] as? String ?? "",
                custom: row["custom"] as? Bool ?? false
            )
        }
    }

    private func pngData(from source: URL) -> Data? {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        convert.arguments = ["-s", "format", "png", "-Z", "512", source.path, "--out", png.path]
        do {
            try convert.run()
            convert.waitUntilExit()
        } catch {
            return nil
        }
        guard convert.terminationStatus == 0,
              let data = try? Data(contentsOf: png),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        try? FileManager.default.removeItem(at: png)
        return data
    }

    private func authorizedRequest(path: String, method: String = "GET") -> URLRequest? {
        guard code.count >= 4, var parts = URLComponents(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        parts.scheme = "http"
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(code, forHTTPHeaderField: "X-Deck-Token")
        request.timeoutInterval = 20
        return request
    }

    private func loadToken(beside server: URL) {
        let file = server.deletingLastPathComponent().appendingPathComponent("token.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if token.count == 6 {
            code = token
        }
    }

    private func publish() {
        let name = Host.current().localizedName ?? "Deck"
        let service = NetService(domain: "local.", type: "_deck._tcp.", name: name, port: Int32(port))
        service.includesPeerToPeer = false
        service.publish()
        self.service = service
    }

    private func locateServer() -> URL? {
        if let saved = UserDefaults.standard.string(forKey: "deck.serverPath") {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let baked = Bundle.main.url(forResource: "companion", withExtension: "path"),
           let text = try? String(contentsOf: baked, encoding: .utf8) {
            let url = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let bundle = Bundle.main.bundleURL
        let project = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = project.appendingPathComponent("companion/server.py")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    private func pythonExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func deckStatus() async -> Int? {
        guard code.count == 6, !code.contains("-"),
              let request = authorizedRequest(path: "/api/deck") else { return nil }
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        return (result.1 as? HTTPURLResponse)?.statusCode
    }

    private func replaceStaleCompanion(python: URL, server: URL) async {
        stopPortListener()
        for _ in 0..<20 {
            if !portOpen(port) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        if launchAtLogin {
            installAgent(python: python, server: server)
        } else if !portOpen(port) {
            spawnInProcess(python: python, server: server)
        }
        for _ in 0..<25 {
            if portOpen(port) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func stopPortListener() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return
        }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            kill(pid, SIGTERM)
        }
    }

    private func portOpen(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        if descriptor < 0 { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func localIPv4() -> [String] {
        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    current.pointee.ifa_addr,
                    socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254."), !result.contains(ip) {
                    result.append(ip)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return result
    }
}

enum DeckMarks {
    static let menuBar: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let keys: [(CGFloat, CGFloat, CGFloat)] = [
                (1, 10, 1), (7, 10, 1), (13, 10, 1),
                (1, 4, 1), (7, 4, 1), (13, 4, 0.7),
            ]
            for (x, y, alpha) in keys {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: 4, height: 4),
                    xRadius: 1,
                    yRadius: 1
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@main
struct DeckMacApp: App {
    @NSApplicationDelegateAdaptor(DeckDelegate.self) var delegate
    @StateObject private var model = CompanionModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(nsImage: DeckMarks.menuBar)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Abrir Deck") { openWindow(id: "main") }
        Button("Copiar código") { model.copyCode() }
            .disabled(model.code == "------")
        Divider()
        Toggle("Iniciar com o Mac", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("Sair") { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        if model.phoneReady {
            DeckBoard()
        } else {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.08), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("DECK")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.7))
                Text(model.status)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("CÓDIGO")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.45))
                    Text(model.code)
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(.white)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                if model.addresses.isEmpty {
                    Text("Conecte este Mac ao Wi-Fi.")
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(model.addresses.map { "\($0):8765" }.joined(separator: "   "))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(model.awaitingPhone
                     ? "O celular ainda não enviou os atalhos. Abra o Deck nele, na mesma rede, com este código."
                     : "No celular, abra o Deck na mesma rede. O Mac aparece na lista. Digite este código. Não precisa deixar o Terminal aberto.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Iniciar com o Mac", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .tint(.white)
                Button("Copiar código") { model.copyCode() }
                    .buttonStyle(DeckButtonStyle(prominent: true))
                    .disabled(model.code == "------")
                if model.status.contains("Não encontrei") {
                    Button("Escolher server.py") { model.chooseCompanion() }
                        .buttonStyle(DeckButtonStyle(prominent: false))
                }
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        }
    }
}

struct DeckButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(
                prominent ? Color.white : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
