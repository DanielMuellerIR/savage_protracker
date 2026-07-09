import SwiftUI
import SavageModPlayerCore

// Subviews, die den hochfrequenten (30 Hz) `VisualizerState` beobachten — bewusst
// AUS `MainView` herausgezogen. Weil sie ein SEPARATES ObservableObject beobachten
// (nicht den Coordinator), stößt ein 30-Hz-Update NUR diese Views an, nicht die
// große `MainView.body`. Das war die zentrale CPU-Optimierung (2026-07-09).

// Spielzeit als mm:ss (frei, damit die Zeit-Subviews es ohne MainView nutzen können).
func formatPlaybackTime(_ sec: Double) -> String {
    guard sec.isFinite, sec >= 0 else { return "00:00" }
    let total = Int(sec)
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// Adaptive Kanal-Oszilloskop-/VU-Leiste. Beobachtet den visualizerState; der
// Coordinator wird als schlichte Referenz für Mute/Solo + Kanalzahl durchgereicht.
// Adaptive Kanal-Leiste. WICHTIG für die CPU (2026-07-09): Die 30-Hz-Oszilloskope
// + VU-Meter ALLER Kanäle werden in EINEM Canvas gezeichnet (ChannelScopesCanvas)
// statt als 32 × (VU-Canvas + Scope-Canvas + 2 Buttons). Vorher rerenderte jeder
// 30-Hz-Tick 32 Streifen mit ~65 SwiftUI-Views + teuren Buttons — der größte
// CPU-Posten (per `sample` verifiziert). Die Mute/Solo-Footer beobachten NICHT den
// visualizerState und rendern daher nicht 30×/s mit; sie nutzen onTapGesture statt
// des teuren SwiftUI-Button. Der Container selbst beobachtet nichts Hochfrequentes.
struct ChannelStripsView: View {
    let visualizer: VisualizerState      // NICHT @ObservedObject: nur das Canvas-Kind beobachtet
    let coordinator: ModPlayerCoordinator
    let channelCount: Int
    let theme: PlayerTheme

    var body: some View {
        GeometryReader { geo in
            let count = max(1, channelCount)
            let spacing: CGFloat = count > 8 ? 6 : 12
            let minStripWidth: CGFloat = 26
            let ideal = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let stripWidth = max(minStripWidth, ideal)
            let content = VStack(spacing: 4) {
                ChannelScopesCanvas(visualizer: visualizer, count: count,
                                    stripWidth: stripWidth, spacing: spacing, theme: theme)
                    .frame(height: 50)
                ChannelFootersRow(coordinator: coordinator, count: count,
                                  stripWidth: stripWidth, spacing: spacing, theme: theme)
            }
            if ideal >= minStripWidth {
                content.frame(width: geo.size.width, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: true) { content }
            }
        }
        .frame(height: 70)
    }
}

// Alle Kanal-VU-Meter + Oszilloskope in EINEM Canvas (immediate mode). Beobachtet
// den visualizerState und rendert 30×/s — aber als EIN Knoten statt 64.
struct ChannelScopesCanvas: View {
    @ObservedObject var visualizer: VisualizerState
    let count: Int
    let stripWidth: CGFloat
    let spacing: CGFloat
    let theme: PlayerTheme

    var body: some View {
        Canvas { ctx, size in
            let vuLevels = visualizer.vuLevels
            let waves = visualizer.channelWaveforms
            let accent = Color.accent(theme)
            let scopeBg = theme == .workbench ? Color.white : Color.black.opacity(0.2)
            let vuW = min(24, max(6, stripWidth * 0.20))
            let innerGap: CGFloat = 4
            for i in 0..<count {
                let colX = CGFloat(i) * (stripWidth + spacing)
                // ---- VU-Meter (12 Segmente) ----
                let level = i < vuLevels.count ? vuLevels[i] : 0
                let segCount = 12
                let segGap: CGFloat = 2
                let segH = (size.height - 4 - segGap * CGFloat(segCount - 1)) / CGFloat(segCount)
                if segH > 0 {
                    for s in 0..<segCount {
                        let threshold = Float(s) / Float(segCount)
                        let active = level >= threshold
                        let y = size.height - 2 - CGFloat(s + 1) * segH - CGFloat(s) * segGap
                        let rect = CGRect(x: colX, y: y, width: vuW, height: segH)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                 with: .color(active ? Self.ledColor(threshold, theme) : Self.inactiveColor(theme)))
                    }
                }
                // ---- Oszilloskop ----
                let scopeX = colX + vuW + innerGap
                let scopeW = max(0, stripWidth - vuW - innerGap)
                let box = CGRect(x: scopeX, y: 0, width: scopeW, height: size.height)
                ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(scopeBg))
                if i < waves.count, scopeW > 1 {
                    let history = waves[i]
                    if history.count > 1 {
                        var path = Path()
                        let step = scopeW / CGFloat(history.count - 1)
                        path.move(to: CGPoint(x: scopeX, y: size.height * CGFloat(0.5 - history[0] * 0.5)))
                        for idx in 1..<history.count {
                            path.addLine(to: CGPoint(x: scopeX + CGFloat(idx) * step,
                                                     y: size.height * CGFloat(0.5 - history[idx] * 0.5)))
                        }
                        ctx.stroke(path, with: .color(accent), lineWidth: 1.2)
                    }
                }
            }
        }
    }

    static func inactiveColor(_ theme: PlayerTheme) -> Color {
        theme == .workbench ? Color.black.opacity(0.07) : Color.white.opacity(0.04)
    }
    static func ledColor(_ threshold: Float, _ theme: PlayerTheme) -> Color {
        if threshold > 0.85 { return .red }
        if threshold > 0.65 { return .orange }
        if threshold > 0.4 { return theme == .workbench ? .lightAccent : .spaceAccentGlow }
        return theme == .workbench ? Color.lightAccent.opacity(0.65) : .spaceAccent
    }
}

// Kanalnummern + Mute/Solo. Beobachtet den Coordinator (Mute/Solo ändern sich selten)
// — NICHT den visualizerState, damit diese Buttons nicht 30×/s neu rendern. onTapGesture
// statt SwiftUI-Button (ButtonBehavior ist teuer und war im Profil heiß).
struct ChannelFootersRow: View {
    @ObservedObject var coordinator: ModPlayerCoordinator
    let count: Int
    let stripWidth: CGFloat
    let spacing: CGFloat
    let theme: PlayerTheme

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 4) {
                    Text("\(i + 1)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.7) : .spaceTextSecondary)
                        .lineLimit(1)
                    tag("M", on: coordinator.isMuted(channelIndex: i), color: .red)
                        .onTapGesture { coordinator.toggleMute(channelIndex: i) }
                    tag("S", on: coordinator.isSoloed(channelIndex: i), color: .green)
                        .onTapGesture { coordinator.toggleSolo(channelIndex: i) }
                }
                .frame(width: stripWidth, alignment: .leading)
            }
        }
    }

    private func tag(_ label: String, on: Bool, color: Color) -> some View {
        Text(label)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 3)
            .background(on ? color : Color.clear)
            .foregroundColor(on ? .white : color)
            .cornerRadius(2)
            .contentShape(Rectangle())
    }
}

// Master-Oszilloskop-Kurve (128 Samples). Beobachtet nur den visualizerState.
struct MasterScopeCanvas: View {
    @ObservedObject var visualizer: VisualizerState
    let theme: PlayerTheme

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let samples = visualizer.masterSamples
                guard samples.count > 1 else { return }
                let step = geo.size.width / CGFloat(samples.count - 1)
                path.move(to: CGPoint(x: 0, y: geo.size.height * CGFloat(0.5 - Double(samples[0]) * 0.5)))
                for idx in 1..<samples.count {
                    let val = Double(samples[idx])
                    path.addLine(to: CGPoint(x: CGFloat(idx) * step, y: geo.size.height * CGFloat(0.5 - val * 0.5)))
                }
            }
            .stroke(Color.accent(theme), lineWidth: 1.5)
        }
        .frame(height: 32)
        .background(theme == .workbench ? Color.white : Color.black.opacity(0.3))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme == .workbench ? Color.lightTextSecondary.opacity(0.35) : Color.spaceAccent.opacity(0.15), lineWidth: 1)
        )
    }
}

// Verstrichene Spielzeit — eigener 30-Hz-Beobachter, damit die tickende Uhr nicht
// die MainView.body neu rendert.
struct ElapsedTimeText: View {
    @ObservedObject var visualizer: VisualizerState
    var body: some View {
        Text(formatPlaybackTime(visualizer.elapsedTime))
            .font(.system(size: 11))
            .monospacedDigit() // proportionale Schrift, aber feste Ziffernbreite (kein Zittern)
            .foregroundColor(.spaceTextSecondary)
    }
}

// Gesamtdauer (ändert sich selten, aber im selben State geführt).
struct TotalTimeText: View {
    @ObservedObject var visualizer: VisualizerState
    var body: some View {
        Text(formatPlaybackTime(visualizer.totalDuration))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundColor(.spaceTextSecondary)
    }
}
