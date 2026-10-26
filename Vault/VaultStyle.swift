import SwiftUI
import AppKit

/// Shared colors respect light appearance and the system accessibility settings.
enum VaultStyle {
    static func fileSymbol(_ type: String) -> String {
        switch type.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": "photo"
        case "mp4", "mov": "film"
        case "mp3", "wav", "m4a": "waveform"
        case "csv", "xls", "xlsx": "tablecells"
        case "ppt", "pptx": "rectangle.on.rectangle"
        case "zip", "tar", "gz": "archivebox"
        default: "doc.text"
        }
    }
    static let lavender = adaptive(dark: (0.69, 0.64, 0.98), light: (0.37, 0.29, 0.68))
    static let teal = adaptive(dark: (0.31, 0.74, 0.71), light: (0.12, 0.40, 0.39))
    static let amber = adaptive(dark: (0.83, 0.64, 0.38), light: (0.48, 0.33, 0.12))
    private static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: values.0, green: values.1, blue: values.2, alpha: 1)
        })
    }
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.055, green: 0.062, blue: 0.085) : Color(red: 0.94, green: 0.945, blue: 0.96)
    }
    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.11, blue: 0.14) : Color(red: 0.98, green: 0.98, blue: 0.99)
    }
}

struct ObservatoryBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var windowState
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @State private var drifting = false
    var grid = true
    private var moving: Bool { cinematicMotion && !reducedMotion && contrast != .increased && scenePhase == .active && windowState != .inactive }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VaultStyle.background(scheme)
                if contrast != .increased { lighting(size: geometry.size) }
                if grid { guide }
            }
        }
        .animation(moving ? .easeInOut(duration: 22).repeatForever(autoreverses: true) : nil, value: drifting)
        .onAppear { drifting = moving }
        .onChange(of: moving) { _, enabled in drifting = enabled }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func lighting(size: CGSize) -> some View {
        ZStack {
            RadialGradient(colors: [VaultStyle.lavender.opacity(scheme == .dark ? 0.17 : 0.07), .clear], center: .init(x: drifting ? 0.58 : 0.40, y: drifting ? 0.46 : 0.33), startRadius: 10, endRadius: max(size.width, size.height) * 0.74)
            RadialGradient(colors: [VaultStyle.teal.opacity(scheme == .dark ? 0.085 : 0.04), .clear], center: .init(x: drifting ? 0.82 : 0.95, y: drifting ? 0.86 : 0.64), startRadius: 0, endRadius: 460)
            LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.025 : 0.12), .clear, .black.opacity(scheme == .dark ? 0.13 : 0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    private var guide: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(18), to: size.width, by: 34) {
                for y in stride(from: CGFloat(18), to: size.height, by: 34) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Color.primary.opacity(contrast == .increased ? 0.12 : 0.055)))
                }
            }
        }
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var radius: CGFloat = 12
    var tint: Color = .clear
    func body(content: Content) -> some View {
        content.background { surface }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 0.8))
            .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.06), radius: 14, y: 5)
    }
    private var surface: some View {
        ZStack {
            if opaque || contrast == .increased {
                RoundedRectangle(cornerRadius: radius).fill(VaultStyle.panel(scheme))
            } else {
                RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: radius).fill(VaultStyle.panel(scheme).opacity(scheme == .dark ? 0.45 : 0.28))
            }
            RoundedRectangle(cornerRadius: radius).fill(tint.opacity(contrast == .increased ? 0.06 : 0.12))
            if !opaque && contrast != .increased {
                RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.075 : 0.45), .clear, .white.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.allowsHitTesting(false)
    }
    private var border: LinearGradient {
        LinearGradient(colors: [Color.primary.opacity(contrast == .increased ? 0.45 : 0.18), Color.primary.opacity(contrast == .increased ? 0.35 : 0.045), Color.primary.opacity(contrast == .increased ? 0.40 : 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
struct QuietPanel: ViewModifier {
    func body(content: Content) -> some View { content.modifier(GlassSurface()) }
}
extension View {
    func quietPanel() -> some View { modifier(QuietPanel()) }
    func glassSurface(radius: CGFloat = 12, tint: Color = .clear) -> some View { modifier(GlassSurface(radius: radius, tint: tint)) }
}

struct CinematicButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        CinematicButtonSurface(configuration: configuration, prominent: prominent)
    }
}
private struct CinematicButtonSurface: View {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("cinematicMotion") private var cinematicMotion = true
    @State private var hovered = false
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    private var tint: Color {
        if configuration.role == .destructive { return .red }
        return prominent || hovered ? VaultStyle.lavender : .clear
    }
    var body: some View {
        configuration.label
            .padding(.horizontal, controlSize == .mini ? 7 : 11)
            .padding(.vertical, controlSize == .mini ? 3 : controlSize == .small ? 5 : 7)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .glassSurface(radius: 8, tint: tint)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VaultStyle.lavender.opacity(enabled && hovered ? 0.45 : 0), lineWidth: 1))
            .scaleEffect(enabled && cinematicMotion && !reducedMotion && configuration.isPressed ? 0.975 : 1)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reducedMotion || !cinematicMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }
}
