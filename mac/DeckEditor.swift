import AppKit
import SwiftUI

struct PhoneSlot: Identifiable, Equatable {
    var key: String
    var appId: String
    var name: String
    var url: String
    var title: String
    var custom: Bool

    var id: String { key }

    var displayName: String {
        if !name.isEmpty { return name }
        if !title.isEmpty { return title }
        if !url.isEmpty { return url }
        return "Vazio"
    }

    var filled: Bool { !appId.isEmpty || !url.isEmpty || !title.isEmpty }
}

struct DeckDocument {
    var revision: Int
    var updated: TimeInterval
    var slots: [PhoneSlot]
    var links: [PhoneSlot]
}

struct DeckBoard: View {
    @EnvironmentObject private var model: CompanionModel

    private var phoneIsLive: Bool {
        Date().timeIntervalSince(model.phoneSeen) < 20
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.08), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ATALHOS DO CELULAR")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(phoneIsLive ? "Celular conectado" : "Aguardando o celular aplicar")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    if !model.deckMessage.isEmpty {
                        Text(model.deckMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 280, alignment: .trailing)
                    }
                    Button(model.savingDeck ? "Salvando…" : "Salvar") {
                        model.savePhoneDeck()
                    }
                    .buttonStyle(DeckButtonStyle(prominent: true))
                    .disabled(!model.dirty || model.savingDeck)
                }
                HStack(alignment: .top, spacing: 22) {
                    ShortcutPage(title: "1  Apps", slots: model.appSlots)
                    ShortcutPage(title: "2  Links", slots: model.linkSlots)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .sheet(isPresented: Binding(
            get: { model.editingKey != nil },
            set: { if !$0 { model.editingKey = nil } }
        )) {
            if let key = model.editingKey {
                ShortcutEditor(slotKey: key, appsPage: model.appSlots.contains { $0.key == key })
                    .environmentObject(model)
            }
        }
        .onAppear { model.loadApps() }
    }
}

struct ShortcutPage: View {
    @EnvironmentObject private var model: CompanionModel
    let title: String
    let slots: [PhoneSlot]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(slots) { slot in
                    Button {
                        model.editingKey = slot.key
                    } label: {
                        ShortcutTile(slot: slot, image: model.picture(for: slot))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ShortcutTile: View {
    let slot: PhoneSlot
    let image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Text(slot.filled ? String(slot.displayName.prefix(1)).uppercased() : "+")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(slot.filled ? 0.9 : 0.35))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(slot.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
    }
}

struct ShortcutEditor: View {
    @EnvironmentObject private var model: CompanionModel
    @Environment(\.dismiss) private var dismiss
    let slotKey: String
    let appsPage: Bool
    @State private var query = ""
    @State private var title = ""
    @State private var url = ""
    @State private var primed = false

    private var slot: PhoneSlot? {
        (appsPage ? model.appSlots : model.linkSlots).first { $0.key == slotKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(appsPage ? "Editar app" : "Editar link")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(.borderless)
            }
            if let slot {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.06))
                        if let image = model.picture(for: slot) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(10)
                        }
                    }
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Trocar ícone") { model.pickIcon(key: slotKey, apps: appsPage) }
                            .buttonStyle(DeckButtonStyle(prominent: false))
                        Button("Ícone padrão") { model.restoreIcon(key: slotKey, apps: appsPage) }
                            .buttonStyle(DeckButtonStyle(prominent: false))
                            .disabled(appsPage ? slot.appId.isEmpty : !slot.custom)
                    }
                }
                if appsPage {
                    TextField("Buscar app", text: $query)
                        .textFieldStyle(.roundedBorder)
                    List(filteredApps) { app in
                        Button {
                            model.chooseApp(slotKey, app: app)
                        } label: {
                            HStack {
                                Text(app.name)
                                Spacer()
                                if app.id == slot.appId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: 240)
                } else {
                    TextField("Nome", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: title) { _ in
                            guard primed else { return }
                            model.updateLink(key: slotKey, title: title, url: url)
                        }
                    TextField("https://exemplo.com", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: url) { _ in
                            guard primed else { return }
                            model.updateLink(key: slotKey, title: title, url: url)
                        }
                }
                Button("Remover atalho") {
                    model.clearShortcut(key: slotKey, apps: appsPage)
                }
                .foregroundStyle(.red)
                Text("Toque em Salvar na janela principal para mandar isso ao celular.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: appsPage ? 560 : 360)
        .onAppear {
            title = slot?.title.isEmpty == false ? slot?.title ?? "" : slot?.name ?? ""
            url = slot?.url ?? ""
            DispatchQueue.main.async { primed = true }
        }
    }

    private var filteredApps: [ListedApp] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = model.apps
        if text.isEmpty { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
}
