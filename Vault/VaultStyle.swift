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
    var grid = true
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VaultStyle.background(scheme)
                if contrast != .increased {
                    RadialGradient(colors: [VaultStyle.lavender.opacity(scheme == .dark ? 0.10 : 0.06), .clear], center: .init(x: 0.48, y: 0.42), startRadius: 20, endRadius: max(geometry.size.width, geometry.size.height) * 0.7)
                    RadialGradient(colors: [VaultStyle.teal.opacity(0.045), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 460)
                }
                if grid {
                    Canvas { context, size in
                        for x in stride(from: CGFloat(18), to: size.width, by: 34) {
                            for y in stride(from: CGFloat(18), to: size.height, by: 34) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(Color.primary.opacity(contrast == .increased ? 0.12 : 0.055)))
                            }
                        }
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct QuietPanel: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        content.background(VaultStyle.panel(scheme).opacity(opaque ? 1 : 0.94), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.085)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.15 : 0.04), radius: 14, y: 5)
    }
}
extension View {
    func quietPanel() -> some View { modifier(QuietPanel()) }
}
