import SwiftUI

struct DeckGrid: View {
    @EnvironmentObject private var model: DeckModel
    var apps: Bool
    var editingIcons: Bool
    @Binding var lifting: Bool
    var onTap: (Int) -> Void
    var onPlus: (Int) -> Void
    var onMove: (Int, Int) -> Void
    var onDrop: () -> Void

    @State private var dragIndex: Int?
    @State private var translation = CGSize.zero
    @State private var carry = CGSize.zero
    @State private var suppressTap = false

    var body: some View {
        GeometryReader { geo in
            grid(size: geo.size)
        }
        .padding(.top, 8)
    }

    private func grid(size: CGSize) -> some View {
        let landscape = size.width > size.height
        let cols = landscape ? 5 : 2
        let rows = Int((Double(slotCount) / Double(cols)).rounded(.up))
        let gap: CGFloat = 10
        let cell = min(
            (size.width - 24 - gap * CGFloat(cols - 1)) / CGFloat(cols),
            (size.height - 16 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        )
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
        let origin = CGPoint(x: (size.width - gridW) / 2, y: (size.height - gridH) / 2)
        return SlotLayout(
            cols: cols,
            cell: cell,
            gap: gap,
            origin: origin,
            dragIndex: dragIndex,
            translation: translation
        ) {
            ForEach(0..<slotCount, id: \.self) { index in
                tile(index, cols: cols, cell: cell, gap: gap, origin: origin)
            }
        }
    }

    private func tile(_ index: Int, cols: Int, cell: CGFloat, gap: CGFloat, origin: CGPoint) -> some View {
        key(index, cell: cell)
            .contentShape(RoundedRectangle(cornerRadius: cell * 0.16, style: .continuous))
            .onTapGesture {
                guard !suppressTap else { return }
                onTap(index)
            }
            .simultaneousGesture(keyGesture(index: index, cols: cols, cell: cell, gap: gap, origin: origin))
            .zIndex(dragIndex == index ? 1 : 0)
    }

    private func key(_ index: Int, cell: CGFloat) -> some View {
        let slot = apps ? model.slots[index] : nil
        let link = apps ? nil : model.links[index]
        let name = slot?.app?.name ?? link?.link?.title ?? ""
        let key = slot?.key ?? link?.key ?? ""
        let image = model.customIcons[key] ?? slot?.app.flatMap { model.icons[$0.id] }
        let radius = cell * 0.16
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let nameRow: CGFloat = name.isEmpty ? 0 : 16
        let iconSide = max(1, min(cell - 16, cell - 19 - nameRow))
        return ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 5) {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: iconSide, height: iconSide)
                            .clipShape(shape)
                    } else if !name.isEmpty {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: min(28, iconSide * 0.45), weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: iconSide, height: iconSide)
                    }
                }
                .frame(width: iconSide, height: iconSide)
                if !name.isEmpty {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(width: cell, height: cell)
            Button {
                onPlus(index)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(red: 0.1, green: 0.1, blue: 0.11), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: cell, height: cell)
        .background(Color(red: 0.063, green: 0.063, blue: 0.071), in: shape)
        .overlay(shape.stroke(Color.white.opacity(editingIcons ? 0.42 : 0.08), lineWidth: 1))
        .clipShape(shape)
        .contentShape(shape)
        .scaleEffect(dragIndex == index ? 1.06 : 1)
    }

    private func keyGesture(index: Int, cols: Int, cell: CGFloat, gap: CGFloat, origin: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: 0.7, maximumDistance: 16)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if dragIndex == nil {
                        dragIndex = index
                        suppressTap = true
                        lifting = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    let delta = drag?.translation ?? .zero
                    translation = CGSize(width: delta.width + carry.width, height: delta.height + carry.height)
                    let current = dragIndex ?? index
                    let home = position(current, cols: cols, cell: cell, gap: gap, origin: origin)
                    let center = CGPoint(x: home.x + cell / 2 + translation.width, y: home.y + cell / 2 + translation.height)
                    let target = indexAt(center, cols: cols, cell: cell, gap: gap, origin: origin)
                    if target != current {
                        let nextHome = position(target, cols: cols, cell: cell, gap: gap, origin: origin)
                        carry.width -= nextHome.x - home.x
                        carry.height -= nextHome.y - home.y
                        translation = CGSize(width: delta.width + carry.width, height: delta.height + carry.height)
                        onMove(current, target)
                        dragIndex = target
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                let moved = dragIndex != nil
                if moved {
                    dragIndex = nil
                    translation = .zero
                    carry = .zero
                    lifting = false
                    onDrop()
                }
                if suppressTap {
                    DispatchQueue.main.async { suppressTap = false }
                }
            }
    }

    private func position(_ index: Int, cols: Int, cell: CGFloat, gap: CGFloat, origin: CGPoint) -> CGPoint {
        let col = index % cols
        let row = index / cols
        return CGPoint(
            x: origin.x + CGFloat(col) * (cell + gap),
            y: origin.y + CGFloat(row) * (cell + gap)
        )
    }

    private func indexAt(_ point: CGPoint, cols: Int, cell: CGFloat, gap: CGFloat, origin: CGPoint) -> Int {
        let stride = cell + gap
        let rows = Int((Double(slotCount) / Double(cols)).rounded(.up))
        let col = Int((point.x - origin.x) / stride).clamped(0, cols - 1)
        let row = Int((point.y - origin.y) / stride).clamped(0, rows - 1)
        return min(row * cols + col, slotCount - 1)
    }
}

private struct SlotLayout: Layout {
    var cols: Int
    var cell: CGFloat
    var gap: CGFloat
    var origin: CGPoint
    var dragIndex: Int?
    var translation: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let child = ProposedViewSize(width: cell, height: cell)
        for index in subviews.indices {
            let col = index % cols
            let row = index / cols
            var x = bounds.minX + origin.x + CGFloat(col) * (cell + gap)
            var y = bounds.minY + origin.y + CGFloat(row) * (cell + gap)
            if dragIndex == index {
                x += translation.width
                y += translation.height
            }
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: child)
        }
    }
}

private extension Int {
    func clamped(_ lower: Int, _ upper: Int) -> Int {
        Swift.min(Swift.max(self, lower), upper)
    }
}
