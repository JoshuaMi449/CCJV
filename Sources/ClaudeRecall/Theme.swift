import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum Theme {
    static var isDark: Bool {
        UserDefaults.standard.object(forKey: AppSettings.darkKey) as? Bool ?? false
    }

    static var accentTheme: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: AppSettings.accentKey) ?? "") ?? .blue
    }

    // MARK: Accent

    static var accent: Color { accentTheme.primary }
    static var accentDeep: Color { accentTheme.deep }
    static var accentLight: Color { accentTheme.light }
    static var accentSoft: Color { accent.opacity(isDark ? 0.16 : 0.10) }
    static var accentLine: Color { accent.opacity(isDark ? 0.30 : 0.22) }

    static var accentInk: Color {
        switch accentTheme {
        case .orange: return Color(hex: 0x2A1305)
        case .blue: return Color(hex: 0x06121F)
        case .green: return Color(hex: 0x062019)
        case .purple: return Color(hex: 0x1B0C31)
        }
    }

    // MARK: Surfaces

    static var bg: Color { isDark ? Color(hex: 0x080D14) : Color(hex: 0xEDF0F7) }
    static var bgLift: Color { isDark ? Color(hex: 0x0D1621) : Color(hex: 0xE5EAF4) }
    static var shellTint: Color { isDark ? Color.white.opacity(0.035) : Color.white.opacity(0.86) }
    static var sidebarTint: Color { isDark ? Color.white.opacity(0.018) : Color.white.opacity(0.24) }
    static var sidebarOpaque: Color { isDark ? Color(hex: 0x14191F) : Color(hex: 0xF9FAFC) }

    static var panel: Color { isDark ? Color(hex: 0x101822) : Color.white.opacity(0.86) }
    static var panelLift: Color { isDark ? Color(hex: 0x17212E) : Color.white.opacity(0.97) }
    static var panelSoft: Color { isDark ? Color(hex: 0x1E2B3A) : Color(hex: 0xEEF2F7) }
    static var promptFill: Color { isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.72) }
    static var paletteFill: Color { isDark ? Color(hex: 0x121B26) : Color.white }
    static var screen: Color { isDark ? Color(hex: 0x11161D) : Color(hex: 0xF7F8FB) }
    static var chassisEdge: Color { Color.white.opacity(isDark ? 0.10 : 0.20) }
    static var insetShadow: Color { Color.black.opacity(isDark ? 0.60 : 0.35) }
    static var screenHighlight: Color { Color.white.opacity(isDark ? 0.07 : 0.65) }

    static var chassis: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color(hex: 0x1A1D22), Color(hex: 0x0B0D11)]
                : [Color(hex: 0x3C3D42), Color(hex: 0x25262B)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var stroke: Color { divider }
    static var strokeStrong: Color { isDark ? Color.white.opacity(0.14) : Color(hex: 0xC6D2E0).opacity(0.72) }
    static var divider: Color { isDark ? Color.white.opacity(0.075) : Color(hex: 0xDDE4ED).opacity(0.62) }
    static var glassBorder: Color { isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.86) }
    static var subtleFill: Color { isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.58) }
    static var sunken: Color { isDark ? Color.black.opacity(0.20) : Color(hex: 0xEEF2F7).opacity(0.72) }

    // MARK: Text

    static var text: Color { isDark ? Color(hex: 0xE9F0F8) : Color(hex: 0x0E1620) }
    static var textSoft: Color { isDark ? Color(hex: 0xB6C8DA) : Color(hex: 0x46586D) }
    static var muted: Color { isDark ? Color(hex: 0x8BA0B5) : Color(hex: 0x6B7D92) }
    static var faint: Color { isDark ? Color(hex: 0x64788D) : Color(hex: 0x9AA9BB) }

    static var searchHighlight: Color { accent.opacity(isDark ? 0.28 : 0.16) }

    static var green: Color { isDark ? Color(hex: 0x2FBF8F) : Color(hex: 0x12855F) }
    static var blue: Color { isDark ? Color(hex: 0x7DB8FF) : Color(hex: 0x1F6FEB) }
    static var red: Color { isDark ? Color(hex: 0xFF7A6B) : Color(hex: 0xC0392B) }

    // MARK: Legacy accent aliases

    static var orange: Color { accent }
    static var orangeDeep: Color { accentDeep }
    static var amber: Color { accentLight }

    static let radiusXL: CGFloat = 32
    static let radiusL: CGFloat = 24
    static let radiusM: CGFloat = 18
    static let radiusS: CGFloat = 12

    static var orangeGradient: LinearGradient {
        LinearGradient(
            colors: [accentLight, accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var warmGradient: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [accent.opacity(0.18), Color.white.opacity(0.03)]
                : [accent.opacity(0.075), Color.white.opacity(0.50)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var glow: RadialGradient {
        RadialGradient(
            colors: [accent.opacity(isDark ? 0.12 : 0.16), .clear],
            center: .topTrailing,
            startRadius: 10,
            endRadius: 720
        )
    }

    // MARK: Shadows

    static var softShadow: Color {
        isDark ? Color.black.opacity(0.42) : Color(hex: 0x1E40AF).opacity(0.10)
    }

    static var cardShadow: Color {
        isDark ? Color.black.opacity(0.30) : Color(hex: 0x1E40AF).opacity(0.055)
    }
}

// MARK: - Ground

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.bg, Theme.bgLift],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Theme.accent.opacity(Theme.isDark ? 0.13 : 0.20), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 760
            )

            RadialGradient(
                colors: [Color(hex: 0xC4B5FD).opacity(Theme.isDark ? 0.10 : 0.18), .clear],
                center: UnitPoint(x: 0.94, y: 0.06),
                startRadius: 0,
                endRadius: 780
            )

            RadialGradient(
                colors: [Color(hex: 0xFFD6CC).opacity(Theme.isDark ? 0.05 : 0.15), .clear],
                center: UnitPoint(x: 0.62, y: 1.04),
                startRadius: 0,
                endRadius: 640
            )
        }
        .ignoresSafeArea()
    }
}

struct CornerPanelShape: Shape {
    var corner: CGFloat = 30
    var socketCenter: CGPoint = CGPoint(x: 28, y: 28)
    var socketRadius: CGFloat = 32
    var shoulder: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(corner, min(rect.width, rect.height) / 2)
        let socket = CGPoint(x: rect.minX + socketCenter.x, y: rect.minY + socketCenter.y)
        let s = socketRadius
        let f = shoulder

        func point(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }

        func appendArc(_ center: CGPoint, _ radius: CGFloat, from a0: CGFloat, to a1: CGFloat) {
            let steps = 36
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = point(center, radius, a0 + (a1 - a0) * t)
                if path.isEmpty {
                    path.move(to: p)
                } else {
                    path.addLine(to: p)
                }
            }
        }

        func angle(_ from: CGPoint, _ to: CGPoint) -> CGFloat {
            atan2(to.y - from.y, to.x - from.x) * 180 / .pi
        }

        func tangentPoint(on filletCenter: CGPoint, toward socketCenter: CGPoint) -> CGPoint {
            let dx = socketCenter.x - filletCenter.x
            let dy = socketCenter.y - filletCenter.y
            let length = hypot(dx, dy)
            return CGPoint(x: filletCenter.x + dx / length * f, y: filletCenter.y + dy / length * f)
        }

        // Shoulder fillet circles sit tangent to both the panel edge and the socket.
        let dyTop = socket.y - (rect.minY + f)
        let topFillet = CGPoint(
            x: socket.x + sqrt(max(0, pow(s + f, 2) - pow(dyTop, 2))),
            y: rect.minY + f
        )
        let dxLeft = socket.x - (rect.minX + f)
        let leftFillet = CGPoint(
            x: rect.minX + f,
            y: socket.y + sqrt(max(0, pow(s + f, 2) - pow(dxLeft, 2)))
        )

        let socketTop = tangentPoint(on: topFillet, toward: socket)
        let socketLeft = tangentPoint(on: leftFillet, toward: socket)

        path.move(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        appendArc(CGPoint(x: rect.maxX - r, y: rect.minY + r), r, from: -90, to: 0)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        appendArc(CGPoint(x: rect.maxX - r, y: rect.maxY - r), r, from: 0, to: 90)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        appendArc(CGPoint(x: rect.minX + r, y: rect.maxY - r), r, from: 90, to: 180)
        path.addLine(to: CGPoint(x: rect.minX, y: leftFillet.y))

        let leftExit = angle(leftFillet, socketLeft)
        appendArc(leftFillet, f, from: 180, to: leftExit < 0 ? leftExit + 360 : leftExit)
        appendArc(socket, s, from: angle(socket, socketLeft), to: angle(socket, socketTop))

        let topEntry = angle(topFillet, socketTop)
        appendArc(topFillet, f, from: topEntry < 0 ? topEntry + 360 : topEntry, to: 270)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

struct CornerPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = CornerPanelShape()

        ZStack {
            shape.fill(Theme.screen)

            content
                .mask(shape.fill(Color.white))
        }
    }
}
