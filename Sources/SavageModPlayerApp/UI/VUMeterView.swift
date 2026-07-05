import SwiftUI

struct VUMeterView: View {
    let value: Float // 0..1.0
    let theme: PlayerTheme
    
    var body: some View {
        GeometryReader { geo in
            // Segmentierter LED-Peak-Meter in beiden Themes — der frühere
            // flache Block im Light-Mode wirkte im Vergleich altbacken. Die
            // Farben sind pro Theme gewählt: Light nutzt den Blau-Akzent und
            // helle inaktive Segmente, Dark bleibt beim Glow-Cyan.
            VStack(spacing: 2) {
                ForEach((0..<12).reversed(), id: \.self) { idx in
                    let threshold = Float(idx) / 12.0
                    let isActive = value >= threshold

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isActive ? ledColor(for: threshold) : inactiveColor)
                        .shadow(color: isActive ? ledColor(for: threshold).opacity(theme == .workbench ? 0.3 : 0.5) : Color.clear, radius: theme == .workbench ? 2 : 4)
                        .frame(height: (geo.size.height - 22) / 12)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var inactiveColor: Color {
        theme == .workbench ? Color.black.opacity(0.07) : Color.white.opacity(0.04)
    }

    private func ledColor(for threshold: Float) -> Color {
        if threshold > 0.85 {
            return .red
        } else if threshold > 0.65 {
            return .orange
        } else if threshold > 0.4 {
            // Light: kraeftiger Blau-Akzent; Dark: helles Glow-Cyan
            return theme == .workbench ? .amigaOrange : .spaceAccentGlow
        } else {
            return theme == .workbench ? Color.amigaOrange.opacity(0.65) : .spaceAccent
        }
    }
}
