import SwiftUI
import UIKit

enum MobileTheme {
    static let canvas = adaptive(0xF5F6F8, 0x1B1B1B)
    static let surface = adaptive(0xFFFFFF, 0x222222)
    static let control = adaptive(0xEBEBEE, 0x292929)
    static let line = adaptive(0xE4E7EC, 0x444444)
    static let ink = adaptive(0x20242C, 0xF2F2F2)
    static let secondary = adaptive(0x414955, 0xBDBDBD)
    static let muted = adaptive(0x667180, 0xB0B0B0)
    static let accent = adaptive(0x246BFD, 0x246BFD)
    static let link = adaptive(0x1954D1, 0xA6C2FF)
    static let selection = adaptive(0xEDF3FF, 0x353535)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func aedrovaScreen(_ color: Color = MobileTheme.canvas) -> some View {
        foregroundStyle(MobileTheme.ink)
            .background { color.ignoresSafeArea() }
            .toolbarBackground(color, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    func aedrovaPanelRows() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .tint(MobileTheme.link)
            .aedrovaScreen()
    }
}

struct AedrovaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.08 : 0.14),
                       value: configuration.isPressed)
    }
}

struct AedrovaLockup: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("AedrovaMark").resizable().scaledToFit().frame(width: 25, height: 25)
            Image("AedrovaWordmark").resizable().scaledToFit().frame(width: 90)
        }
        .foregroundStyle(MobileTheme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aedrova")
    }
}

struct AedrovaGlyph: View {
    let symbol: String
    var size: CGFloat = 38
    var highlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(highlighted ? MobileTheme.link : MobileTheme.secondary)
            .frame(width: size, height: size)
            .background(highlighted ? MobileTheme.selection : MobileTheme.control,
                        in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct AedrovaInitials: View {
    let name: String
    var size: CGFloat = 38
    var emphasized = false

    var body: some View {
        let initials = name.split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.35, weight: .semibold))
            .foregroundStyle(emphasized ? MobileTheme.link : MobileTheme.secondary)
            .frame(width: size, height: size)
            .background(emphasized ? MobileTheme.selection : MobileTheme.control,
                        in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct AedrovaState: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AedrovaGlyph(symbol: symbol, size: 40)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(MobileTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AedrovaTextAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MobileTheme.link)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(MobileTheme.selection, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}


struct AedrovaActivityDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.045, paused: reduceMotion || scene != .active)) { time in
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    let phase = time.date.timeIntervalSinceReferenceDate * 7 - Double(index) * 1.1
                    let lift = reduceMotion ? 0 : max(0, sin(phase))
                    Circle()
                        .fill(MobileTheme.muted)
                        .frame(width: 4, height: 4)
                        .offset(y: -CGFloat(lift) * 3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
