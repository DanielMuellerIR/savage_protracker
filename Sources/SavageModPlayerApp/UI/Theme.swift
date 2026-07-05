import SwiftUI

public enum PlayerTheme: String, CaseIterable, Identifiable {
    case workbench = "Light"
    case cyber = "Dark"
    
    public var id: String { self.rawValue }
}

public extension Color {
    // Light Theme: macOS-nah, ruhig, hoher Textkontrast.
    static let amigaBlue = Color(red: 0.965, green: 0.970, blue: 0.980)       // #F6F7FA
    static let amigaWhite = Color(red: 0.075, green: 0.090, blue: 0.115)      // #13171D
    static let amigaOrange = Color(red: 0.000, green: 0.333, blue: 0.710)     // #0055B5
    static let amigaDarkBlue = Color(red: 0.930, green: 0.940, blue: 0.955)   // #EDF0F4
    static let amigaGrey = Color(red: 0.340, green: 0.380, blue: 0.440)       // #576170
    
    // Dark Theme: Schwarz/Graphit mit gedämpften Akzenten, keine Neonfarben.
    static let spaceBackground = Color(red: 0.020, green: 0.024, blue: 0.030)   // #050608
    static let spaceSurface = Color(red: 0.075, green: 0.082, blue: 0.095)      // #131518
    static let spaceSurfaceHover = Color(red: 0.125, green: 0.137, blue: 0.155) // #202328
    static let spaceAccent = Color(red: 0.360, green: 0.700, blue: 0.760)       // #5CB3C2
    static let spaceAccentGlow = Color(red: 0.620, green: 0.700, blue: 0.760)   // #9EB3C2
    
    // Tracker-Spalten: lesbar, klassisch codiert, bewusst gedämpft.
    static let codeNote = Color(red: 0.660, green: 0.820, blue: 0.720)       // #A8D1B8
    static let codeInstrument = Color(red: 0.890, green: 0.760, blue: 0.420) // #E3C26B
    static let codeEffect = Color(red: 0.520, green: 0.700, blue: 0.840)     // #85B3D6
    static let codeDim = Color(red: 0.245, green: 0.290, blue: 0.300)        // #3E4A4D
    
    static let spaceTextPrimary = Color(red: 0.925, green: 0.930, blue: 0.940) // #ECEEF0
    static let spaceTextSecondary = Color(red: 0.620, green: 0.660, blue: 0.690) // #9EA8B0
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
