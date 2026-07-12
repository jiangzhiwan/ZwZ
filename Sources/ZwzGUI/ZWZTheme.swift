import SwiftUI
import AppKit

// MARK: - Theme Colors

extension Color {
    static let zwzBlue = Color(red: 0.35, green: 0.68, blue: 0.98)
    static let zwzPink = Color(red: 0.98, green: 0.56, blue: 0.72)
    static let zwzGreen = Color(red: 0.30, green: 0.80, blue: 0.56)
    static let zwzOrange = Color(red: 0.98, green: 0.70, blue: 0.40)
    static let zwzCardBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1)
            : NSColor.white
    })
    static let zwzBackgroundBlue = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.145, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1)
    })
    static let zwzBackgroundPink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.145, green: 0.085, blue: 0.115, alpha: 1)
            : NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.97, alpha: 1)
    })
}

// MARK: - Gradients

extension LinearGradient {
    static var zwzBluePink: LinearGradient {
        LinearGradient(colors: [.zwzBlue, .zwzPink], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var zwzBlueGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.30, green: 0.64, blue: 0.96), Color(red: 0.40, green: 0.72, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var zwzPinkGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.98, green: 0.52, blue: 0.68), Color(red: 1.0, green: 0.64, blue: 0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var zwzBackground: LinearGradient {
        LinearGradient(
            colors: [.zwzBackgroundBlue, .zwzBackgroundPink],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Card Shadow

struct ZWZShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    func zwzCardShadow(_ shadow: ZWZShadow = ZWZShadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

// MARK: - Gradient Text Label (solid color for now)

struct ZWZGradientLabel: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight

    init(text: String, gradient: LinearGradient = .zwzBluePink, fontSize: CGFloat = 24, weight: Font.Weight = .bold) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .foregroundColor(.zwzBlue)
    }
}

// MARK: - App Logo

struct ZWZLogoView: View {
    let size: CGFloat

    init(size: CGFloat = 40) {
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient.zwzBluePink)

            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: max(1, size * 0.035))

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: size * 0.54, height: size * 0.54)
                .offset(x: -size * 0.22, y: -size * 0.22)

            Text("Z")
                .font(.system(size: size * 0.58, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)

            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: size * 0.26, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .offset(x: size * 0.22, y: size * 0.24)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.zwzBlue.opacity(0.18), radius: size * 0.16, x: 0, y: size * 0.06)
        .accessibilityLabel("ZwZ")
    }
}
