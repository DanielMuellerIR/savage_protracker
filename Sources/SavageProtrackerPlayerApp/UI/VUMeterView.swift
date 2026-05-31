import SwiftUI

struct VUMeterView: View {
    let value: Float // 0..1.0
    let theme: PlayerTheme
    
    var body: some View {
        GeometryReader { geo in
            if theme == .workbench {
                // Classic Amiga flat block design with double border
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .amigaOrange, location: 0.8),
                                    .init(color: .amigaWhite, location: 0.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: geo.size.height * CGFloat(min(1.0, max(0.0, value))))
                }
                .background(Color.amigaDarkBlue)
                .border(Color.amigaWhite, width: 2)
                .padding(2)
                .border(Color.amigaBlue, width: 1)
            } else {
                // Space Indigo: Glowing Segmented LED Peak Meter
                VStack(spacing: 2) {
                    ForEach((0..<12).reversed(), id: \.self) { idx in
                        let threshold = Float(idx) / 12.0
                        let isActive = value >= threshold
                        
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isActive ? ledColor(for: threshold) : Color.white.opacity(0.04))
                            .shadow(color: isActive ? ledColor(for: threshold).opacity(0.5) : Color.clear, radius: 4)
                            .frame(height: (geo.size.height - 22) / 12)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
    
    private func ledColor(for threshold: Float) -> Color {
        if threshold > 0.85 {
            return .red
        } else if threshold > 0.65 {
            return .orange
        } else if threshold > 0.4 {
            return .spaceAccentGlow
        } else {
            return .spaceAccent
        }
    }
}
