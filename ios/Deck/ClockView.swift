import SwiftUI
import UIKit

struct ClockView: View {
    @Binding var blocksPage: Bool
    var active: Bool
    @AppStorage("deck-clock-color") private var colorIndex = 2
    @State private var moment = ClockMoment.now
    @State private var picking = false
    @State private var shownYear = Calendar.current.component(.year, from: Date())
    @State private var shownMonth = Calendar.current.component(.month, from: Date())
    @State private var monthDrag: CGFloat = 0
    @State private var monthDragging = false
    @State private var calendarWidth: CGFloat = 1
    private let colors: [Color] = [
        Color(red: 1, green: 0.27, blue: 0.23),
        Color(red: 1, green: 0.42, blue: 0),
        Color(red: 1, green: 0.62, blue: 0.04),
        Color(red: 1, green: 0.84, blue: 0.04),
        Color(red: 0.77, green: 0.96, blue: 0.40),
        Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 0.39, green: 0.90, blue: 0.75),
        Color(red: 0.35, green: 0.78, blue: 0.96),
        Color(red: 0.04, green: 0.52, blue: 1),
        Color(red: 0.37, green: 0.36, blue: 0.90),
        Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 1, green: 0.22, blue: 0.37),
        Color(red: 1, green: 0.54, blue: 0.85),
        .white,
    ]

    var body: some View {
        let accent = colors[min(max(colorIndex, 0), colors.count - 1)]
        ZStack {
            Color.black
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    HStack(spacing: 0) {
                        solar(accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                        calendar(accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        solar(accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                        calendar(accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            if picking {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture { picking = false }
                colorSheet(accent)
            }
        }
        .onAppear {
            moment = .now
            if !active { resetMonth() }
        }
        .onChange(of: active) { isActive in
            if !isActive { resetMonth() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            let next = ClockMoment.now
            if next.time != moment.time || next.date != moment.date { moment = next }
        }
    }

    private func solar(_ accent: Color) -> some View {
        let hour24 = !uses12Hour
        let stamp = String(format: "%02d%02d", displayedHour(moment.time.hour, hour24: hour24), moment.time.minute)
        let palette = solarDigits(accent)
        return GeometryReader { geo in
            let digit = min(geo.size.height * 0.62, geo.size.width / 4.3)
            HStack(spacing: -digit * 0.03) {
                RollingDigit(char: stamp[stamp.startIndex], color: palette[0], size: digit)
                RollingDigit(char: stamp[stamp.index(stamp.startIndex, offsetBy: 1)], color: palette[1], size: digit)
                colon(digit * 0.1)
                RollingDigit(char: stamp[stamp.index(stamp.startIndex, offsetBy: 2)], color: palette[2], size: digit)
                RollingDigit(char: stamp[stamp.index(stamp.startIndex, offsetBy: 3)], color: palette[3], size: digit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { picking = true }
        }
    }

    private func colon(_ size: CGFloat) -> some View {
        VStack(spacing: size * 0.85) {
            Circle().fill(Color.white.opacity(0.86)).frame(width: size, height: size)
            Circle().fill(Color.white.opacity(0.86)).frame(width: size, height: size)
        }
        .padding(.horizontal, size * 0.7)
    }

    private func resetMonth() {
        let now = Date()
        shownYear = Calendar.current.component(.year, from: now)
        shownMonth = Calendar.current.component(.month, from: now)
        monthDrag = 0
        monthDragging = false
        blocksPage = false
    }

    private func calendar(_ accent: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return GeometryReader { geo in
            let width = max(geo.size.width, 1)
            HStack(spacing: 0) {
                monthCard(shift: -1, accent: accent, width: width, height: geo.size.height)
                monthCard(shift: 0, accent: accent, width: width, height: geo.size.height)
                monthCard(shift: 1, accent: accent, width: width, height: geo.size.height)
            }
            .offset(x: -width + monthDrag)
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .onAppear { calendarWidth = width }
            .onChange(of: width) { calendarWidth = $0 }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.16), lineWidth: 1))
        .contentShape(shape)
        .highPriorityGesture(monthGesture)
    }

    private var monthGesture: some Gesture {
        let width = max(calendarWidth, 1)
        return DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !monthDragging {
                    guard abs(dx) > 8, abs(dx) > abs(dy) else { return }
                    monthDragging = true
                    blocksPage = true
                }
                monthDrag = dx
            }
            .onEnded { value in
                let wasDragging = monthDragging
                monthDragging = false
                blocksPage = false
                guard wasDragging else { return }
                let travel = value.translation.width
                let projected = value.predictedEndTranslation.width
                let distance = min(width * 0.18, 56 as CGFloat)
                let goNext = travel <= -distance || (travel < -12 && projected <= -distance)
                let goBack = travel >= distance || (travel > 12 && projected >= distance)
                let target: CGFloat = goNext ? -width : (goBack ? width : 0)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    monthDrag = target
                } completion: {
                    guard goNext || goBack else { return }
                    let step = goNext ? 1 : -1
                    let next = shiftedMonth(shownYear, shownMonth, by: step)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        shownYear = next.year
                        shownMonth = next.month
                        monthDrag = 0
                    }
                }
            }
    }

    private func monthCard(shift: Int, accent: Color, width: CGFloat, height: CGFloat) -> some View {
        let parts = shiftedMonth(shownYear, shownMonth, by: shift)
        let titleDate = Calendar.current.date(from: DateComponents(year: parts.year, month: parts.month, day: 1)) ?? Date()
        let title = titleDate.formatted(.dateTime.month(.wide)).uppercased()
        let weeks = monthWeeks(year: parts.year, month: parts.month)
        let headers = weekdayLabels()
        let cell = min(width / 7.6, height / 8.8)
        let today = moment.date
        let showsToday = parts.year == today.year && parts.month == today.month
        return VStack(spacing: cell * 0.08) {
            Text(title)
                .font(.system(size: cell * 0.38, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(accent)
                .padding(.bottom, cell * 0.15)
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: cell * 0.28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: cell, height: cell * 0.7)
                }
            }
            ForEach(weeks.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let day = weeks[row][column]
                        let marked = showsToday && day == today.day
                        ZStack {
                            if let day {
                                if marked {
                                    Circle().fill(accent).frame(width: cell * 0.72, height: cell * 0.72)
                                }
                                Text("\(day)")
                                    .font(.system(size: cell * 0.34, weight: marked ? .semibold : .regular))
                                    .foregroundStyle(marked ? textOn(accent) : .white.opacity(0.92))
                            }
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func colorSheet(_ accent: Color) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Text("Cor")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Spacer()
                    Button { picking = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(colors.indices, id: \.self) { index in
                        let chosen = index == colorIndex
                        Circle()
                            .fill(colors[index])
                            .frame(width: chosen ? 26 : 22, height: chosen ? 26 : 22)
                            .padding(4)
                            .overlay(Circle().stroke(Color.white, lineWidth: chosen ? 2 : 0))
                            .onTapGesture { colorIndex = index }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var uses12Hour: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return format.contains("a")
    }
}

private struct RollingDigit: View {
    var char: Character
    var color: Color
    var size: CGFloat

    var body: some View {
        Text(String(char))
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(color)
            .id(char)
            .transition(.asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .animation(.easeOut(duration: 0.24), value: char)
    }
}

private struct ClockMoment: Equatable {
    var time: (hour: Int, minute: Int)
    var date: (year: Int, month: Int, day: Int)

    static var now: ClockMoment {
        let date = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return ClockMoment(
            time: (parts.hour ?? 0, parts.minute ?? 0),
            date: (parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
        )
    }

    static func == (lhs: ClockMoment, rhs: ClockMoment) -> Bool {
        lhs.time == rhs.time && lhs.date == rhs.date
    }
}

private func displayedHour(_ hour: Int, hour24: Bool) -> Int {
    if hour24 { return hour }
    let wrapped = hour % 12
    return wrapped == 0 ? 12 : wrapped
}

private func weekdayLabels() -> [String] {
    let calendar = Calendar.current
    let symbols = calendar.veryShortWeekdaySymbols
    let first = calendar.firstWeekday - 1
    return (0..<7).map { symbols[($0 + first) % 7].prefix(1).uppercased() }
}

private func shiftedMonth(_ year: Int, _ month: Int, by delta: Int) -> (year: Int, month: Int) {
    let first = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    let moved = Calendar.current.date(byAdding: .month, value: delta, to: first) ?? first
    let parts = Calendar.current.dateComponents([.year, .month], from: moved)
    return (parts.year ?? year, parts.month ?? month)
}

private func monthWeeks(year: Int, month: Int) -> [[Int?]] {
    var calendar = Calendar.current
    let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    let range = calendar.range(of: .day, in: .month, for: first) ?? 1..<31
    let weekday = calendar.component(.weekday, from: first)
    let lead = (weekday - calendar.firstWeekday + 7) % 7
    var cells: [Int?] = Array(repeating: nil, count: lead)
    cells.append(contentsOf: range.map { Optional($0) })
    while cells.count % 7 != 0 { cells.append(nil) }
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
}

private func solarDigits(_ base: Color) -> [Color] {
    let ui = UIColor(base)
    var hue: CGFloat = 0
    var sat: CGFloat = 0
    var bri: CGFloat = 0
    var alpha: CGFloat = 0
    ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
    if sat < 0.08 {
        return [
            Color(red: 1, green: 0.54, blue: 0.24),
            Color(red: 0.56, green: 0.83, blue: 1),
            Color(red: 0.24, green: 0.49, blue: 1),
            Color(red: 1, green: 0.48, blue: 0.18),
        ]
    }
    return [
        shift(base, 0, max(sat, 0.55), 1),
        shift(base, 0.46, 0.38, 1),
        shift(base, 0.57, 0.62, 1),
        shift(base, 0.06, min(max(sat, 0.5), 0.85), 1),
    ]
}

private func shift(_ color: Color, _ hueDelta: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> Color {
    let ui = UIColor(color)
    var hue: CGFloat = 0
    var sat: CGFloat = 0
    var bri: CGFloat = 0
    var alpha: CGFloat = 0
    ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
    return Color(hue: (hue + hueDelta).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness)
}

private func textOn(_ color: Color) -> Color {
    let ui = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    ui.getRed(&red, green: &green, blue: &blue, alpha: nil)
    return red * 0.299 + green * 0.587 + blue * 0.114 > 0.72 ? .black : .white
}
