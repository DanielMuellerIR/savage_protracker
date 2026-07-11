import SwiftUI
import SavageModPlayerCore

// Feststehende Zeilennummer (scrollt NICHT horizontal mit den Kanaelen). Statisch
// (ohne aktuelle-Zeile-Hervorhebung) — die Markierung übernimmt jetzt ein separates
// Highlight-Band, damit der Zellenblock beim Zeilenwechsel unverändert bleibt.
struct RowIndexCell: View {
    let rIdx: Int
    let theme: PlayerTheme
    let fontSize: CGFloat
    // Klick auf die Zeilennummer springt zu dieser Zeile (Play danach ab hier).
    var onTap: (() -> Void)? = nil

    var body: some View {
        Text(String(format: "%02d", rIdx))
            .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
            .foregroundColor(theme == .workbench ? .lightAccent : .spaceAccentGlow)
            .frame(width: 38, height: fontSize + 6, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .help("Zu dieser Zeile springen — Play/Weiter spielt ab hier (Tempo wird rekonstruiert; laufende Slide-/Vibrato-Effekte näherungsweise).")
    }
}

// Zeichnet ALLE Kanalzellen (bis zu 200 × 64 bei IT) in EINEM Canvas statt als
// tausende einzelne SwiftUI-Views.
// Der Canvas wird nur bei Pattern-/Layout-Wechsel neu gezeichnet
// (Equatable ohne currentRow) — beim Scrollen/Zeilenwechsel wird er nur verschoben
// (CoreAnimation), NICHT neu gelayoutet. Das ersetzt den mit Abstand teuersten
// Posten: die 2048-Zellen-ScrollView-Layout-Rekursion pro Zeilenwechsel (2026-07-09,
// per `sample` verifiziert — ScrollView-`sizeThatFits` sättigte den Main-Thread).
struct ChannelCellsCanvas: View, Equatable {
    let pattern: SavageModPlayerCore.Pattern
    let patternIndex: Int
    let channelIndices: [Int]
    let rowCount: Int
    let cellWidth: CGFloat
    let showVolume: Bool
    let fontSize: CGFloat
    let theme: PlayerTheme

    nonisolated static func == (lhs: ChannelCellsCanvas, rhs: ChannelCellsCanvas) -> Bool {
        lhs.patternIndex == rhs.patternIndex && lhs.channelIndices == rhs.channelIndices
            && lhs.rowCount == rhs.rowCount && lhs.cellWidth == rhs.cellWidth
            && lhs.showVolume == rhs.showVolume && lhs.fontSize == rhs.fontSize && lhs.theme == rhs.theme
    }

    private static let noteNames = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]

    var body: some View {
        let rowHeight = fontSize + 6
        let charW = fontSize * 0.62   // Monospaced-Vorschub (SF Mono ~0.6·pt)
        let sepColor = theme == .workbench ? Color.lightTextPrimary.opacity(0.55) : Color.spaceAccent.opacity(0.45)
        let dim = theme == .workbench ? Color.lightTextPrimary.opacity(0.3) : Color.codeDim
        let font = Font.system(size: fontSize, weight: .semibold, design: .monospaced)

        return Canvas { ctx, size in
            for r in 0..<rowCount {
                let y = CGFloat(r) * rowHeight
                let notes = pattern.rows[r].notes
                for (column, channelIndex) in channelIndices.enumerated()
                    where channelIndex < notes.count {
                    let colX = CGFloat(column) * cellWidth
                    // Kanal-Trennlinie.
                    ctx.fill(Path(CGRect(x: colX, y: y, width: 1, height: rowHeight)), with: .color(sepColor))

                    let n = notes[channelIndex]
                    let hasNote = n.period > 0 || n.key >= 0
                    let hasInst = n.instrument > 0
                    let hasEff = n.hasEffect
                    let hasVol = n.volume >= 0

                    let noteStr = hasNote ? Self.noteName(n) : "---"
                    let instStr = hasInst ? String(format: "%02X", n.instrument) : "--"
                    let effStr = Self.effString(n)
                    let volStr = hasVol ? String(format: "v%02d", n.volume) : "..."

                    let noteColor = hasNote ? (theme == .workbench ? Color.lightTextPrimary : .codeNote) : dim
                    let instColor = hasInst ? (theme == .workbench ? Color.lightTextSecondary : .codeInstrument) : dim
                    let effColor = hasEff ? (theme == .workbench ? Color.lightAccent : .codeEffect) : dim
                    let volColor = hasVol ? (theme == .workbench ? Color.lightTextSecondary : .codeInstrument) : dim

                    var tx = colX + 5
                    let cy = y + rowHeight / 2
                    func put(_ s: String, _ col: Color, _ chars: Int) {
                        ctx.draw(Text(s).font(font).foregroundColor(col), at: CGPoint(x: tx, y: cy), anchor: .leading)
                        tx += CGFloat(chars) * charW + 4
                    }
                    put(noteStr, noteColor, 3)
                    put(instStr, instColor, 2)
                    if showVolume { put(volStr, volColor, 3) }
                    put(effStr, effColor, 3)
                }
            }
        }
    }

    private static func noteName(_ note: Note) -> String {
        if note.key == Note.keyCut { return "^^^" }   // S3M Note-Cut
        if note.key == Note.keyOff { return "===" }   // XM Key-Off (Note 97) korrekt zeigen
        if note.key == Note.keyFade { return "~~~" }  // IT Note Fade
        if note.key >= 0 { return "\(noteNames[note.key % 12])\(note.key / 12)" }
        // MOD: aus der Amiga-Periode.
        guard note.period >= 113 && note.period <= 856 else { return "---" }
        let idx = Int(round(24.0 + 12.0 * log2(428.0 / Double(note.period))))
        guard idx >= 0 else { return "---" }
        return "\(noteNames[idx % 12])\((idx / 12) + 1)"
    }

    private static func effString(_ n: Note) -> String {
        guard n.hasEffect else { return "..." }
        if n.effectId > ModuleEffect.impulseTrackerCommandBase,
           n.effectId <= ModuleEffect.impulseTrackerCommandBase + 26 {
            let scalar = UnicodeScalar(64 + n.effectId - ModuleEffect.impulseTrackerCommandBase)!
            return String(format: "%@%02X", String(Character(scalar)), n.effectData)
        }
        if n.effectId >= 0x100 {
            let letter: String
            switch n.effectId {
            case ModuleEffect.setSpeed: letter = "A"
            case ModuleEffect.setTempo: letter = "T"
            case ModuleEffect.globalVolume: letter = "V"
            case ModuleEffect.tremor: letter = "I"
            case ModuleEffect.fineVibrato: letter = "U"
            case ModuleEffect.volumeSlideS3M: letter = "D"
            case ModuleEffect.portaDownS3M: letter = "E"
            case ModuleEffect.portaUpS3M: letter = "F"
            default: letter = "?"
            }
            return String(format: "%@%02X", letter, n.effectData)
        }
        if n.effectId >= 0xE0 { return String(format: "E%X%X", n.effectId & 0x0F, n.effectData) }
        return String(format: "%01X%02X", n.effectId, n.effectData)
    }
}

// Der komplette (statische) Zellen-Block: feststehende Nummern-Spalte + horizontal
// scrollbare Kanalspalten für ALLE 64 Zeilen. WICHTIG — Equatable OHNE currentRow:
// So überspringt SwiftUI beim Zeilenwechsel den GESAMTEN Layout-/Zeichen-Aufwand
// dieses Blocks (bis zu 64×32 Zellen). Vorher legte der Layout-Engine bei JEDEM
// Zeilenwechsel (~20×/s bei schnellen Songs) das ganze Grid neu aus — DAS war der
// mit Abstand größte CPU-Posten (2026-07-09, per `sample` verifiziert: SwiftUI-
// ScrollView-`sizeThatFits` sättigte den Main-Thread). Die aktuelle Zeile markiert
// jetzt ein separates Highlight-Band (siehe TrackerGridView), das sich bewegt, ohne
// die Zellen anzufassen.
struct GridCellsBlock: View, Equatable {
    let pattern: SavageModPlayerCore.Pattern
    let patternIndex: Int
    let theme: PlayerTheme
    let cellStride: CGFloat        // Spaltenbreite je Kanal (inkl. Trennlinie)
    let canvasWidth: CGFloat       // Gesamtbreite der Kanal-Zeichenfläche
    let showVolume: Bool
    let fontSize: CGFloat
    let rowCount: Int
    let channelIndices: [Int]
    private var channelCount: Int { channelIndices.count }
    // Für die eigene H-Scrollbar in TrackerGridView: der GeometryReader schreibt den
    // aktuellen Offset hierhin. NICHT im == — Scroll-Updates laufen über die
    // ScrollView-Geometrie, nicht über einen Block-Rerender.
    @Binding var hScrollOffset: CGFloat
    // Klick auf eine Zeilennummer -> zu dieser Zeile springen. NICHT im == (Closure).
    var onSeekRow: (Int) -> Void

    nonisolated static func == (lhs: GridCellsBlock, rhs: GridCellsBlock) -> Bool {
        lhs.patternIndex == rhs.patternIndex
            && lhs.theme == rhs.theme
            && lhs.cellStride == rhs.cellStride
            && lhs.canvasWidth == rhs.canvasWidth
            && lhs.showVolume == rhs.showVolume
            && lhs.fontSize == rhs.fontSize
            && lhs.rowCount == rhs.rowCount
            && lhs.channelIndices == rhs.channelIndices
    }

    @ViewBuilder
    private func horizontalWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if channelCount > 4 {
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .background(
                        GeometryReader { g -> Color in
                            let x = -g.frame(in: .named("patternH")).minX
                            DispatchQueue.main.async {
                                if abs(hScrollOffset - x) > 0.5 { hScrollOffset = x }
                            }
                            return Color.clear
                        }
                    )
            }
            .coordinateSpace(name: "patternH")
        } else {
            content()
        }
    }

    var body: some View {
        let contentHeight = CGFloat(rowCount) * (fontSize + 6)
        HStack(alignment: .top, spacing: 0) {
            // Feststehende Nummern-Spalte (scrollt nur vertikal mit) — 64 leichte
            // Views mit .id für scrollTo.
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { rIdx in
                    RowIndexCell(rIdx: rIdx, theme: theme, fontSize: fontSize,
                                 onTap: { onSeekRow(rIdx) }).id(rIdx)
                }
            }
            // Horizontal scrollbare Kanalspalten — ALLE Zellen in EINEM Canvas.
            horizontalWrapper {
                ChannelCellsCanvas(
                    pattern: pattern, patternIndex: patternIndex, channelIndices: channelIndices,
                    rowCount: rowCount, cellWidth: cellStride, showVolume: showVolume,
                    fontSize: fontSize, theme: theme
                )
                .frame(width: canvasWidth, height: contentHeight)
            }
        }
    }
}

struct TrackerGridView: View {
    let pattern: SavageModPlayerCore.Pattern
    let patternIndex: Int
    let currentRow: Int
    let channelIndices: [Int]
    let theme: PlayerTheme
    var onSeekRow: (Int) -> Void = { _ in }

    @State private var hScrollOffset: CGFloat = 0

    private var rowCount: Int { pattern.rows.count }
    private var channelCount: Int { max(1, channelIndices.count) }

    // Eigene horizontale Scrollbar: duenn, dezent, nur wenn Inhalt breiter als View.
    @ViewBuilder
    private func hScrollBar(viewport: CGFloat, contentWidth: CGFloat) -> some View {
        if contentWidth > viewport && viewport > 0 {
            let thumbWidth = max(28, viewport * viewport / contentWidth)
            let maxOffset = contentWidth - viewport
            let ratio = maxOffset > 0 ? min(1, max(0, hScrollOffset / maxOffset)) : 0
            Capsule()
                .fill(Color(white: 0.5).opacity(0.75))
                .frame(width: thumbWidth, height: 4)
                .offset(x: (viewport - thumbWidth) * ratio, y: -2)
                .allowsHitTesting(false)
        }
    }

    // S3M-Patterns tragen eine Volume-Column (Note.volume >= 0 irgendwo im Pattern).
    private var hasVolumeColumn: Bool {
        pattern.rows.contains { $0.notes.contains { $0.volume >= 0 } }
    }

    var body: some View {
        let showVolume = hasVolumeColumn

        GeometryReader { geo in
            let rowIndexWidth: CGFloat = 38
            let baseCell: CGFloat = showVolume ? 98 : 72
            let sepGap: CGFloat = 1
            let channelsViewport = geo.size.width - rowIndexWidth
            let neededAtBase = CGFloat(channelCount) * (baseCell + sepGap)
            let needsScroll = channelCount > 4 && neededAtBase > channelsViewport
            let fontSize: CGFloat = needsScroll ? 11 : 12
            // Spaltenbreite je Kanal: >4 Kanäle feste Zellbreite (+ Trennlinie) und
            // H-Scroll; ≤4 Kanäle füllen die verfügbare Breite.
            let cellStride: CGFloat = channelCount > 4
                ? baseCell * (fontSize / 12) + sepGap
                : channelsViewport / CGFloat(max(1, channelCount))
            let contentWidth = CGFloat(channelCount) * cellStride
            let rowHeight = fontSize + 6

            ZStack(alignment: .bottomLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            // Highlight-Band der aktuellen Zeile (hinter den Zellen).
                            // Bewegt sich pro Zeile, ohne den Zellen-Block anzufassen.
                            Rectangle()
                                .fill(theme == .workbench ? Color.lightAccent.opacity(0.35) : Color.spaceAccent.opacity(0.18))
                                .frame(height: rowHeight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .offset(y: CGFloat(currentRow) * rowHeight)
                                .allowsHitTesting(false)

                            // Der statische, equatable Zellen-Block (wird beim
                            // Zeilenwechsel als Ganzes übersprungen).
                            GridCellsBlock(
                                pattern: pattern,
                                patternIndex: patternIndex,
                                theme: theme,
                                cellStride: cellStride,
                                canvasWidth: contentWidth,
                                showVolume: showVolume,
                                fontSize: fontSize,
                                rowCount: rowCount,
                                channelIndices: channelIndices.isEmpty ? [0] : channelIndices,
                                hScrollOffset: $hScrollOffset,
                                onSeekRow: onSeekRow
                            )
                            .equatable()
                        }
                    }
                    .onChange(of: currentRow) { newRow in
                        // Kein withAnimation: direktes scrollTo landet frame-synchron.
                        proxy.scrollTo(newRow, anchor: .center)
                    }
                }

                hScrollBar(viewport: channelsViewport, contentWidth: contentWidth)
                    .padding(.leading, rowIndexWidth)
            }
        }
        .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceSurface)
        .border(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.15), width: theme == .workbench ? 2 : 1)
        .cornerRadius(theme == .workbench ? 0 : 8)
    }
}
