import SwiftUI

struct DeckScreen: View {
    @EnvironmentObject private var model: DeckModel
    @StateObject private var discovery = MacBrowser()
    @State private var page = 0
    @State private var drag: CGFloat = 0
    @State private var draggingPage = false
    @State private var calendarPaging = false
    @State private var editingIcons = false
    @State private var showConnect = false
    @State private var askedConnect = false
    @State private var linkIndex: Int?
    @State private var browserIndex: Int?
    @State private var iconEdit: (page: Int, index: Int)?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                background
                    .ignoresSafeArea()
                let menuHeight: CGFloat = page == 2 ? 0 : 46
                let pageHeight = max(geo.size.height - menuHeight, 1)
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<3, id: \.self) { index in
                            Group {
                                if index == 2 {
                                    ClockView(blocksPage: $calendarPaging, active: page == 2)
                                } else {
                                    grid(page: index, width: width)
                                }
                            }
                            .frame(width: width, height: pageHeight, alignment: .topLeading)
                            .offset(x: CGFloat(index - page) * width + drag)
                            .allowsHitTesting(index == page && !draggingPage)
                        }
                    }
                    .frame(width: width, height: pageHeight, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(pageGesture(width: width))
                    if page != 2 {
                        pageMenu
                            .frame(width: width)
                            .padding(.bottom, 6)
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .top)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onAppear {
            discovery.start()
            if case .noHost = model.connection, !askedConnect {
                askedConnect = true
                showConnect = true
            }
        }
        .onDisappear { discovery.stop() }
        .onChange(of: calendarPaging) { active in
            if active {
                draggingPage = false
                drag = 0
            }
        }
        .onChange(of: model.lifting) { lifting in
            if lifting {
                draggingPage = false
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { drag = 0 }
            }
        }
        .onChange(of: model.connection) { value in
            if case .noHost = value, !askedConnect {
                askedConnect = true
                showConnect = true
            }
        }
        .alert("Deck", isPresented: Binding(
            get: { model.banner != nil },
            set: { if !$0 { model.banner = nil } }
        )) {
            Button("Ok", role: .cancel) { model.banner = nil }
        } message: {
            Text(model.banner ?? "")
        }
        .sheet(isPresented: $showConnect) {
            ConnectSheet(discovered: discovery.found) { address, token in
                await model.connect(address: address, token: token)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: appSheet) { index in
            AppPickerSheet(current: model.slots[index.value].app) { app in
                await model.assign(index.value, app: app)
            } onClear: {
                model.clearApp(index.value)
            }
        }
        .sheet(item: linkSheet) { index in
            LinkEditorSheet(
                initialTitle: model.links[index.value].link?.title ?? "",
                initialURL: model.links[index.value].link?.url ?? "",
                canRemove: model.links[index.value].link != nil,
                onSave: { title, url in model.setLink(index.value, title: title, url: url) },
                onRemove: { model.clearLink(index.value) }
            )
        }
        .sheet(item: iconSheet) { target in
            IconEditSheet(hasCustom: model.hasCustom(page: target.page, index: target.index)) { image in
                model.setSlotIcon(page: target.page, index: target.index, image: image)
            } onClear: {
                model.clearSlotIcon(page: target.page, index: target.index)
            }
        }
    }

    private var background: some View {
        Group {
            if page == 2 {
                Color.black
            } else {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.07, blue: 0.08), Color(red: 0.02, green: 0.02, blue: 0.024), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    private func grid(page index: Int, width: CGFloat) -> some View {
        DeckGrid(
            apps: index == 0,
            editingIcons: editingIcons,
            lifting: $model.lifting,
            onTap: { slot in
                if editingIcons {
                    iconEdit = (index, slot)
                } else if index == 0 {
                    model.launch(slot)
                } else {
                    model.openLink(slot)
                }
            },
            onPlus: { slot in
                if index == 0 { linkIndex = slot } else { browserIndex = slot }
            },
            onMove: { from, to in
                if index == 0 { model.moveApps(from: from, to: to) } else { model.moveLinks(from: from, to: to) }
            },
            onDrop: { model.finishReorder() }
        )
        .frame(width: width)
        .padding(.horizontal, index == page ? 0 : 0)
    }

    private var pageMenu: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(page == index ? 0.95 : 0.32))
                        .frame(width: page == index ? 8 : 5, height: page == index ? 8 : 5)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(pageSpring) {
                                drag = 0
                                page = index
                            }
                        }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Button {
                    showConnect = true
                } label: {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(connectionLabel)
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(editingIcons ? 1 : 0.55))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .onTapGesture { editingIcons.toggle() }
            }
        }
        .frame(height: 40)
    }

    private var connectionLabel: String {
        switch model.connection {
        case .online: return "Conectado ao notebook"
        case .checking: return "Conectando ao notebook"
        default: return "Desconectado do notebook"
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .online: return Color(red: 0.24, green: 0.86, blue: 0.52)
        case .checking: return Color(red: 1, green: 0.78, blue: 0.34)
        default: return Color(red: 1, green: 0.36, blue: 0.36)
        }
    }

    private func pageGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                guard !model.lifting, !calendarPaging else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if !draggingPage {
                    guard abs(dx) > 18, abs(dx) > abs(dy) else { return }
                    draggingPage = true
                }
                drag = resisted(dx, width: width)
            }
            .onEnded { value in
                let wasDragging = draggingPage
                draggingPage = false
                guard wasDragging, !model.lifting, !calendarPaging else {
                    withAnimation(pageSpring) { drag = 0 }
                    return
                }
                let travel = value.translation.width
                let projected = value.predictedEndTranslation.width
                let current = page
                var next = current
                if travel < -12, page < 2, travel <= -width / 2 || projected <= -width / 2 {
                    next = current + 1
                } else if travel > 12, page > 0, travel >= width / 2 || projected >= width / 2 {
                    next = current - 1
                }
                withAnimation(pageSpring) {
                    page = next
                    drag = 0
                }
                if next != current {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }

    private var pageSpring: Animation {
        .spring(response: 0.34, dampingFraction: 0.9)
    }

    private func resisted(_ dx: CGFloat, width: CGFloat) -> CGFloat {
        if page == 0, dx > 0 { return rubber(dx, limit: width) }
        if page == 2, dx < 0 { return -rubber(-dx, limit: width) }
        return dx
    }

    private func rubber(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        let stretched = distance * 0.45
        return limit * (1 - exp(-stretched / limit)) * 0.35
    }

    private var appSheet: Binding<IndexBox?> {
        Binding(
            get: { linkIndex.map(IndexBox.init) },
            set: { linkIndex = $0?.value }
        )
    }

    private var linkSheet: Binding<IndexBox?> {
        Binding(
            get: { browserIndex.map(IndexBox.init) },
            set: { browserIndex = $0?.value }
        )
    }

    private var iconSheet: Binding<IconTarget?> {
        Binding(
            get: { iconEdit.map { IconTarget(page: $0.page, index: $0.index) } },
            set: { iconEdit = $0.map { ($0.page, $0.index) } }
        )
    }
}

struct IndexBox: Identifiable {
    var value: Int
    var id: Int { value }
}

struct IconTarget: Identifiable {
    var page: Int
    var index: Int
    var id: String { "\(page)-\(index)" }
}
