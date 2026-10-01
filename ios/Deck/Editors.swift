import PhotosUI
import SwiftUI

struct ConnectSheet: View {
    var discovered: [DiscoveredMac]
    var onConnect: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.11).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("Conectar ao notebook")
                    .font(.system(size: 22, weight: .semibold))
                Text("Abra o Deck no Mac, na mesma rede, e digite o código. O toque no celular abre o app ou o link no notebook.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
                if !discovered.isEmpty {
                    ForEach(discovered.filter { !$0.host.isEmpty }) { mac in
                        Button {
                            address = mac.address
                        } label: {
                            HStack {
                                Text(mac.name)
                                Spacer()
                                Text(mac.address).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                TextField("192.168.0.10", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Código", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(.red)
                }
                Button(loading ? "Conectando…" : "Conectar") {
                    Task {
                        loading = true
                        error = nil
                        let message = await onConnect(address, token)
                        loading = false
                        if let message { error = message } else { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(loading)
                Spacer()
            }
            .padding(22)
            .foregroundStyle(.white)
        }
        .onAppear {
            if address.isEmpty, discovered.filter({ !$0.host.isEmpty }).count == 1 {
                address = discovered.first { !$0.host.isEmpty }?.address ?? ""
            }
        }
    }
}

struct AppPickerSheet: View {
    @EnvironmentObject private var model: DeckModel
    var current: DeckAppInfo?
    var onPick: (DeckAppInfo) async -> String?
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(filtered) { app in
                Button {
                    Task {
                        error = await onPick(app)
                        if error == nil { dismiss() }
                    }
                } label: {
                    HStack {
                        if let image = model.icons[app.id] {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                        }
                        Text(app.name)
                        Spacer()
                        if app.id == current?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "Buscar app")
            .navigationTitle("Escolher app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                if current != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Remover") {
                            onClear()
                            dismiss()
                        }
                    }
                }
            }
            .overlay {
                if model.appsLoading { ProgressView() }
                if let message = model.appsError ?? error {
                    Text(message).padding()
                }
            }
        }
        .task { await model.loadApps() }
    }

    private var filtered: [DeckAppInfo] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
}

struct LinkEditorSheet: View {
    var initialTitle: String
    var initialURL: String
    var canRemove: Bool
    var onSave: (String, String) -> String?
    var onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome", text: $title)
                TextField("https://exemplo.com", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                Text("O toque abre este endereço no navegador do Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        if let message = onSave(title, url) {
                            error = message
                        } else {
                            dismiss()
                        }
                    }
                }
                if canRemove {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Remover link", role: .destructive) {
                            onRemove()
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            title = initialTitle
            url = initialURL
        }
    }
}

struct IconEditSheet: View {
    var hasCustom: Bool
    var onImage: (UIImage) -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Editar ícone")
                .font(.system(size: 22, weight: .semibold))
            Text("A imagem fica neste atalho. O app ou o link continuam os mesmos.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
            PhotosPicker(selection: $photo, matching: .images) {
                Text("Escolher imagem")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
            if hasCustom {
                Button("Ícone padrão") {
                    onClear()
                    dismiss()
                }
                .foregroundStyle(.red)
            }
            Button("Agora não") { dismiss() }
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.1, green: 0.1, blue: 0.11))
        .foregroundStyle(.white)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onImage(image)
                    dismiss()
                }
            }
        }
    }
}
