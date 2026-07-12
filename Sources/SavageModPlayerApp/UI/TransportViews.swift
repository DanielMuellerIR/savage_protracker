import SwiftUI
import SavageModPlayerCore
#if canImport(AppKit)
import AppKit
#endif

// Ziehbarer vertikaler Trenn-Handle für die Playlist-Sidebar-Breite. Portabel
// (macOS/iOS); auf macOS zeigt er beim Überfahren den Links-/Rechts-Resize-Cursor.
// Die Breite wird als Binding gehalten (in MainView per @AppStorage persistiert)
// und beim Ziehen in `range` geklemmt.
struct ResizableDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let theme: PlayerTheme
    // .vertical  = senkrechter Balken, horizontales Ziehen ändert eine BREITE.
    // .horizontal = waagrechter Balken, senkrechtes Ziehen ändert eine HÖHE;
    //   `inverted` (nach oben ziehen = größer) für unten angedockte Sektionen.
    var axis: Axis = .vertical
    var inverted: Bool = false
    // Wert bei Gesten-Beginn, damit die Verschiebung relativ dazu rechnet
    // (sonst springt der Handle bei jedem onChanged-Event).
    @State private var startValue: Double? = nil

    var body: some View {
        // Die SICHTBARE Linie ist bewusst dünn (1 pt) und dezent gehalten, damit der
        // Trenner nicht ins Auge sticht. Die eigentliche KLICK-/ZIEHFLÄCHE ist über
        // `contentShape` aber deutlich breiter (`hitSize`) — sonst trifft man den
        // schmalen Handle mit der Maus kaum. So bleibt die Optik ruhig, das
        // Ziehen aber gut greifbar.
        let thickness: CGFloat = 1     // sichtbare Linienstärke (dünn)
        // Unsichtbare Trefferfläche. Vertikal bewusst schmal (11 pt) gehalten,
        // damit das opake Band auf der Hauptbereich-Seite kaum auffällt.
        // Horizontal großzügiger (20 pt): Der Trenner steckt zwischen zwei
        // ScrollViews (Playlist oben, Verlauf unten) — ein knapp daneben
        // gesetzter senkrechter Zug scrollt sonst die Liste statt zu ziehen.
        // Vertikal kostet mehr Breite Optik, horizontal NICHT (Band verschmilzt
        // oben wie unten mit der Sidebar-Fläche).
        let hitSize: CGFloat = axis == .vertical ? 11 : 20
        // WICHTIG: Die breite Trefferfläche MUSS opak gefüllt sein. Mit
        // `Color.clear` schien im Dark-Mode der weiße Fenster-Hintergrund durch
        // und der Trenner wurde zum grellen, breiten weißen Balken (Bug
        // 2026-07-12). Der Flächenton entspricht der Sidebar-/Listenfläche,
        // sodass die 11-pt-Fläche optisch mit dem Nachbar-Panel verschmilzt und
        // NUR die dünne Linie als Trenner sichtbar bleibt.
        let barColor: Color = theme == .workbench ? Color.lightSurface : Color.spaceSurface
        // Dünne, dezente Linie: Light heller als zuvor, Dark neutral-grau statt
        // hellem Cyan-Akzent.
        let lineColor: Color = theme == .workbench
            ? Color.lightTextSecondary.opacity(0.30)
            : Color.spaceTextSecondary.opacity(0.22)
        // Linie MITTIG im Handle (nicht an der Kante): Der Nutzer zielt auf den
        // sichtbaren Strich; sitzt die Trefferfläche nur auf EINER Seite davon,
        // verfehlt jeder Klick knapp daneben. Zentriert bleiben links UND rechts
        // je ~5 pt greifbar (Bug „fühlt sich wie 1 px an", 2026-07-12).
        return ZStack {
            // Opake Trefferfläche (füllt den hitSize-Rahmen, verdeckt den
            // Fenster-Hintergrund, verschmilzt mit der Sidebar).
            barColor
            // Dünne Linie mittig.
            Rectangle()
                .fill(lineColor)
                .frame(width: axis == .vertical ? thickness : nil,
                       height: axis == .horizontal ? thickness : nil)
        }
        .frame(width: axis == .vertical ? hitSize : nil, height: axis == .horizontal ? hitSize : nil)
        .frame(maxWidth: axis == .horizontal ? .infinity : nil,
               maxHeight: axis == .vertical ? .infinity : nil)
        .contentShape(Rectangle())
        // highPriority statt gesture: Der horizontale Trenner grenzt an
        // ScrollViews; deren Scroll-Geste würde einen senkrechten Zug sonst
        // abfangen. highPriorityGesture lässt das Ziehen des Handles gewinnen,
        // sobald der Cursor in seiner Trefferfläche liegt.
        .highPriorityGesture(
                // WICHTIG: `.global` als Koordinatenraum. Im (Default-)lokalen
                // Raum wandert die Referenz mit dem Handle mit, während dieser
                // beim Ziehen seine Position ändert — die `translation` koppelt
                // dadurch zurück und der Trenner zittert mit hoher Frequenz hin
                // und her (Bug 2026-07-12). Global gemessen ist der Bezug fix.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startValue ?? width
                        if startValue == nil { startValue = width }
                        let raw = axis == .vertical ? Double(value.translation.width)
                                                    : Double(value.translation.height)
                        let delta = inverted ? -raw : raw
                        width = min(range.upperBound, max(range.lowerBound, base + delta))
                    }
                    .onEnded { _ in startValue = nil }
            )
            .onHover { inside in
                #if canImport(AppKit)
                if inside {
                    (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else { NSCursor.pop() }
                #endif
            }
            .help(axis == .vertical
                  ? "Ziehen, um die Playlist-Breite anzupassen (lange Dateinamen sichtbar machen)"
                  : "Ziehen, um die Höhe der Liste anzupassen")
    }
}

// Positions-/Zeilen-abhängige Subviews, die den row-rate `TransportState`
// beobachten — herausgezogen aus MainView, damit die ~20-Hz-Zeilenwechsel NICHT
// die große MainView.body neu evaluieren. Das war die eigentliche CPU-Grundlast
// (2026-07-09, gemessen: ~74 % „Floor" auch bei ausgeblendetem Grid/Oszilloskop).

// Tracker-Grid inkl. Pattern-Auswahl aus der aktuellen Song-Position. Beobachtet
// `transport`; das restliche MainView bleibt vom Zeilentakt entkoppelt.
struct TrackerGridContainer: View {
    @ObservedObject var transport: TransportState
    let mod: Mod
    let channelIndices: [Int]
    let theme: PlayerTheme
    // Klick auf eine Zeile -> zu (aktuelle Position, Zeile) springen.
    var onSeekRow: (Int) -> Void = { _ in }

    var body: some View {
        // Defensiv wie zuvor: length/patternTable/patternIndex vor dem Zugriff klemmen.
        let tableIdx = max(0, min(mod.length - 1, transport.currentPosition))
        let patternIndex = mod.patternTable[max(0, min(mod.patternTable.count - 1, tableIdx))]
        if patternIndex >= 0, patternIndex < mod.patterns.count {
            TrackerGridView(pattern: mod.patterns[patternIndex], patternIndex: patternIndex,
                            currentRow: transport.currentRow,
                            channelIndices: channelIndices, theme: theme,
                            onSeekRow: onSeekRow)
        } else {
            Color.clear
        }
    }
}

// „PAT: n/N" — aktuelle Song-Position im Header.
struct PatPositionText: View {
    @ObservedObject var transport: TransportState
    let length: Int
    var body: some View {
        Text(String(format: "PAT: %d/%d", transport.currentPosition + 1, length))
            .fixedSize()
    }
}

// Pattern-Mini-Map: Order-Positionen als anklickbare Marker; hebt die aktuelle hervor.
struct PatternMarkerMap: View {
    @ObservedObject var transport: TransportState
    let mod: Mod
    let theme: PlayerTheme
    let onSeek: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<mod.length, id: \.self) { idx in
                    let isCurrent = idx == transport.currentPosition
                    let patNum = mod.patternTable[idx]
                    Button(action: { onSeek(idx) }) {
                        VStack(spacing: 2) {
                            Text(String(format: "%02d", idx))
                                .font(.system(size: 8, weight: .bold))
                            Text("P\(patNum)")
                                .font(.system(size: 7))
                        }
                        .frame(width: 24, height: 26)
                        .background(
                            isCurrent
                            ? Color.accent(theme)
                            : (theme == .workbench ? Color.lightSurfaceAlt : Color.spaceSurface)
                        )
                        .foregroundColor(isCurrent ? .white : .spaceTextSecondary)
                        .cornerRadius(3)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// Rotierende Play/Pause-Disk mit EIGENEM Rotations-State + Timer. Früher lag der
// 30-Hz-Timer und `diskRotation` als @State auf MainView — jeder Tick rerenderte
// damit die GESAMTE MainView.body (2000+ Zeilen) 30×/s. Das war DIE CPU-Ursache
// (2026-07-09, per `sample` gefunden). Als eigener View betrifft die Rotation nur
// noch diese kleine Disk. Die Drehung wird Frame für Frame selbst hochgezählt (nicht
// per .repeatForever), damit sie bei Pause/Stop exakt stehen bleibt.
struct SpinningDiskButton: View {
    let isPlaying: Bool
    let isPaused: Bool
    let enabled: Bool
    let theme: PlayerTheme
    let onTap: () -> Void

    @State private var rotation: Double = 0
    private let spinTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    // Eine volle Umdrehung in 2,7 s bei 30 fps.
    private let degreesPerTick: Double = 360.0 / (2.7 * 30.0)

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(theme == .workbench ? Color.lightTextPrimary.opacity(0.12) : Color.spaceSurface)
                    .frame(width: 40, height: 40)
                    .shadow(color: theme == .workbench ? Color.clear : Color.spaceAccent.opacity(0.3), radius: 5)
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 30))
                    .foregroundColor(Color.accent(theme))
                    .rotationEffect(.degrees(rotation))
                Circle()
                    .fill(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground)
                    .frame(width: 6, height: 6)
                Image(systemName: isPlaying && !isPaused ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            .opacity(isPlaying ? 1.0 : 0.6)
            .animation(.easeInOut, value: isPlaying)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .help(isPlaying && !isPaused
              ? "Pause — an derselben Stelle fortsetzbar (Leertaste)."
              : "Abspielen bzw. pausierte Wiedergabe fortsetzen (Leertaste).")
        .onReceive(spinTimer) { _ in
            if isPlaying && !isPaused { rotation += degreesPerTick }
        }
    }
}

// Positions-Slider (Song-Position wählen; funktioniert auch im gestoppten Zustand).
struct PositionSlider: View {
    @ObservedObject var transport: TransportState
    let mod: Mod
    let theme: PlayerTheme
    let onSeek: (Int) -> Void

    var body: some View {
        // WICHTIG: Range nie leer (mod.length == 1 -> 0...0 crasht SwiftUIs Slider).
        // Die Arithmetik liegt in `SongPositionScale` (Core), damit die
        // Crash-verhindernde Invariante headless testbar ist.
        let bounds = SongPositionScale.bounds(positionCount: mod.length, current: transport.currentPosition)
        Slider(
            value: Binding(
                get: { bounds.value },
                set: { onSeek(Int($0)) }
            ),
            in: bounds.range,
            step: 1.0
        )
        .accentColor(Color.accent(theme))
        .disabled(!bounds.isEnabled)
        .help("Song-Position wählen — funktioniert auch bei gestoppter Wiedergabe: Play startet dann ab dieser Stelle.")
    }
}
