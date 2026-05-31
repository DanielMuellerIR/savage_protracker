import SwiftUI

public enum PlayerTheme: String, CaseIterable, Identifiable {
    case workbench = "Retro Workbench 1.3"
    case cyber = "Cyber Charcoal (Modern)"
    
    public var id: String { self.rawValue }
}

public extension Color {
    // Amiga Workbench 1.3 Colors
    static let amigaBlue = Color(red: 0.0, green: 0.333, blue: 0.667)       // #0055AA
    static let amigaWhite = Color(red: 0.949, green: 0.949, blue: 0.949)    // #F2F2F2
    static let amigaOrange = Color(red: 1.0, green: 0.333, blue: 0.0)       // #FF5500
    static let amigaDarkBlue = Color(red: 0.0, green: 0.133, blue: 0.267)   // #002244
    static let amigaGrey = Color(red: 0.667, green: 0.667, blue: 0.667)     // #AAAAAA
    
    // Premium Cyber Charcoal Colors (No Purple/Lila!)
    static let spaceBackground = Color(red: 0.05, green: 0.05, blue: 0.06)   // #0D0D10 Deep obsidian black
    static let spaceSurface = Color(red: 0.09, green: 0.10, blue: 0.12)      // #171A1F Sleek steel charcoal
    static let spaceSurfaceHover = Color(red: 0.14, green: 0.16, blue: 0.19) // #242930
    static let spaceAccent = Color(red: 0.00, green: 0.85, blue: 1.00)       // #00D8FF Neon Cyber Cyan
    static let spaceAccentGlow = Color(red: 0.00, green: 0.60, blue: 0.90)   // #0096E6 Cool Ocean Blue
    
    // Note Color Coding
    static let codeNote = Color(red: 0.063, green: 0.725, blue: 0.506)       // #10B981 Emerald Green
    static let codeInstrument = Color(red: 0.024, green: 0.714, blue: 0.831) // #06B6D4 Cyan
    static let codeEffect = Color(red: 0.851, green: 0.275, blue: 0.937)     // #D946EF Magenta
    static let codeDim = Color(red: 0.247, green: 0.247, blue: 0.275)        // #3F3F46 Muted Grey
    
    static let spaceTextPrimary = Color.white
    static let spaceTextSecondary = Color(red: 0.612, green: 0.639, blue: 0.722) // #9C9FB8
}

// MARK: - Premium Glassmorphic & Retro Visual Assets

#if os(macOS)
public struct VisualEffectView: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    
    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#endif

public struct CRTScanlinesOverlay: View {
    public init() {}
    
    public var body: some View {
        GeometryReader { geo in
            Path { path in
                let height = geo.size.height
                let width = geo.size.width
                var y: CGFloat = 0
                while y < height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                    y += 3.0 // Step size of scanlines
                }
            }
            .stroke(Color.black.opacity(0.12), lineWidth: 1.0)
        }
        .allowsHitTesting(false)
    }
}

public struct CRTVignetteOverlay: View {
    public init() {}
    
    public var body: some View {
        RadialGradient(
            gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.25)]),
            center: .center,
            startRadius: 100,
            endRadius: 500
        )
        .allowsHitTesting(false)
    }
}

public struct PremiumHoverButtonStyle: ButtonStyle {
    let theme: PlayerTheme
    
    public init(theme: PlayerTheme) {
        self.theme = theme
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        if theme == .workbench {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1.0)
        } else {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
                .brightness(configuration.isPressed ? -0.05 : 0.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}


