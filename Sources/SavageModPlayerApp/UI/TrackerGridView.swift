import SwiftUI
import SavageModPlayerCore

struct TrackerRowView: View {
    let rIdx: Int
    let notes: [Note]           // Eine Note pro Kanal (dynamische Kanalzahl)
    let isCurrent: Bool
    let theme: PlayerTheme
    // Ab 5 Kanälen bekommt jede Zelle eine feste Breite und das Grid scrollt
    // horizontal — sonst würden die Zellen unleserlich zusammengequetscht.
    let fixedCellWidth: CGFloat?
    // S3M-Patterns haben eine eigene Volume-Column; bei MOD bleibt sie weg.
    let showVolume: Bool
    // Schriftgroesse der Pattern-Zellen; die Zeilenhoehe haengt daran (kompakt).
    let fontSize: CGFloat

    // Nur noch die Kanal-Zellen — die Zeilennummer sitzt in einer eigenen, beim
    // horizontalen Scrollen FESTSTEHENDEN Spalte (siehe TrackerGridView).
    var body: some View {
        let rowBg: Color = isCurrent ? (theme == .workbench ? Color.amigaOrange.opacity(0.35) : Color.spaceAccent.opacity(0.18)) : Color.clear

        HStack(spacing: 0) {
            ForEach(0..<notes.count, id: \.self) { c in
                separator

                if let width = fixedCellWidth {
                    channelCell(note: notes[c])
                        .frame(width: width)
                } else {
                    channelCell(note: notes[c])
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // Zeilenhoehe = Schrift + 6 (frueher fixe 24): halbiert den Abstand
        // zwischen den 3-Zeichen-Reihen, zeigt so mehr Zeilen gleichzeitig.
        .frame(height: fontSize + 6)
        .background(rowBg)
    }

    // Kein Abstand mehr zwischen den Kanaelen — nur eine 1-pt-Trennlinie, dafuer
    // deutlich heller, damit sie klar trennt (Wunsch: Kanaele dichter, Linie
    // sichtbarer).
    private var separator: some View {
        Rectangle()
            .fill(theme == .workbench ? Color.amigaWhite.opacity(0.55) : Color.spaceAccent.opacity(0.45))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func channelCell(note: Note) -> some View {
        let hasNote = note.period > 0 || note.key >= 0
        let hasInst = note.instrument > 0
        let hasEff = note.hasEffect

        let noteStr = hasNote ? noteName(note) : "---"
        let instStr = hasInst ? String(format: "%02X", note.instrument) : "--"

        var effStr = "..."
        if hasEff {
            if note.effectId >= 0x100 {
                // Interne S3M-Effekte als ScreamTracker-Buchstabe anzeigen.
                effStr = String(format: "%@%02X", s3mEffectLetter(note.effectId), note.effectData)
            } else if note.effectId >= 0xE0 {
                let subEff = note.effectId & 0x0F
                effStr = String(format: "E%X%X", subEff, note.effectData)
            } else {
                effStr = String(format: "%01X%02X", note.effectId, note.effectData)
            }
        }

        let noteColor: Color = hasNote ? (theme == .workbench ? .amigaWhite : .codeNote) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)
        let instColor: Color = hasInst ? (theme == .workbench ? .amigaGrey : .codeInstrument) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)
        let effColor: Color = hasEff ? (theme == .workbench ? .amigaOrange : .codeEffect) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)

        // Volume-Column (nur S3M): "v40" bzw. gedimmtes "..." ohne Angabe.
        let hasVol = note.volume >= 0
        let volStr = hasVol ? String(format: "v%02d", note.volume) : "..."
        let volColor: Color = hasVol ? (theme == .workbench ? .amigaGrey : .codeInstrument) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)

        return HStack(spacing: 4) {
            Text(noteStr).foregroundColor(noteColor)
            Text(instStr).foregroundColor(instColor)
            if showVolume {
                Text(volStr).foregroundColor(volColor)
            }
            Text(effStr).foregroundColor(effColor)
        }
        .font(.system(size: fontSize, weight: isCurrent ? .bold : .semibold, design: .monospaced))
    }

    private static let noteNames = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]

    private func noteName(_ note: Note) -> String {
        // S3M: Halbton-Key direkt (Oktave*12 + Note); ^^^ = Note-Cut.
        if note.key == Note.keyCut { return "^^^" }
        if note.key >= 0 {
            let name = Self.noteNames[note.key % 12]
            return "\(name)\(note.key / 12)"
        }
        return periodToNoteName(note.period)
    }

    // Interne ModuleEffect-IDs zurück auf den S3M-Anzeigebuchstaben mappen.
    private func s3mEffectLetter(_ effectId: Int) -> String {
        switch effectId {
        case ModuleEffect.setSpeed: return "A"
        case ModuleEffect.setTempo: return "T"
        case ModuleEffect.globalVolume: return "V"
        case ModuleEffect.tremor: return "I"
        case ModuleEffect.fineVibrato: return "U"
        case ModuleEffect.volumeSlideS3M: return "D"
        case ModuleEffect.portaDownS3M: return "E"
        case ModuleEffect.portaUpS3M: return "F"
        default: return "?"
        }
    }

    private func periodToNoteName(_ period: Int) -> String {
        guard period >= 113 && period <= 856 else { return "---" }

        // Logarithmic calculation from modplayer.js
        let noteIndexDouble = 24.0 + 12.0 * log2(428.0 / Double(period))
        let noteIndex = Int(round(noteIndexDouble))

        guard noteIndex >= 0 else { return "---" }

        let noteName = Self.noteNames[noteIndex % 12]
        let octave = (noteIndex / 12) + 1
        return "\(noteName)\(octave)"
    }
}

struct TrackerGridView: View {
    let pattern: SavageModPlayerCore.Pattern
    let currentRow: Int
    let theme: PlayerTheme

    // Aktueller horizontaler Scroll-Offset (nur bei >4 Kanaelen relevant).
    @State private var hScrollOffset: CGFloat = 0

    // Kanalzahl aus den Pattern-Daten (jede Row hat channelCount Noten).
    private var channelCount: Int {
        pattern.rows.first?.notes.count ?? 4
    }

    // Horizontaler Scroll-Container fuer die Kanalspalten (nur bei >4 Kanaelen).
    // Traegt KEINE Scrollbar — die wird in body an den unteren SICHTBAREN Rand
    // gepinnt (hier laege sie am Ende des langen 64-Zeilen-Inhalts).
    @ViewBuilder
    private func horizontalWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if channelCount > 4 {
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .background(
                        // Offset bei JEDER Layout-Auswertung direkt in den State
                        // schreiben (async, um "State waehrend View-Update"-Warnung
                        // zu vermeiden) — folgt dem Scrollen kontinuierlich.
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

    // Eigene horizontale Scrollbar: duenn, mit einem mittleren Grau, das sonst
    // nirgends vorkommt — faellt auf, bleibt aber dezent. Nur sichtbar, wenn der
    // Inhalt breiter als die Ansicht ist.
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

    // Feststehende Zeilennummer (scrollt NICHT horizontal mit den Kanaelen).
    @ViewBuilder
    private func rowIndexCell(_ rIdx: Int, isCurrent: Bool, fontSize: CGFloat) -> some View {
        let color: Color = isCurrent ? .amigaOrange : (theme == .workbench ? .amigaOrange : .spaceAccentGlow)
        let bg: Color = isCurrent ? (theme == .workbench ? Color.amigaOrange.opacity(0.35) : Color.spaceAccent.opacity(0.18)) : Color.clear
        Text(String(format: "%02d", rIdx))
            .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 38, height: fontSize + 6, alignment: .center)
            .background(bg)
    }

    // S3M-Patterns tragen eine Volume-Column (Note.volume >= 0 irgendwo im
    // Pattern) — dann bekommt jede Zelle das zusätzliche Volume-Feld.
    private var hasVolumeColumn: Bool {
        pattern.rows.contains { $0.notes.contains { $0.volume >= 0 } }
    }

    var body: some View {
        // Bis 4 Kanäle füllen die Zellen die Breite (klassisches Layout);
        // darüber feste Zellbreite + horizontales Scrollen (mit Volume-Column
        // entsprechend breiter).
        let showVolume = hasVolumeColumn

        GeometryReader { geo in
            // Zellbreite/Font: bei >4 Kanaelen feste Zellen; muesste dann eine
            // horizontale Scrollbar noetig sein, wird die Schrift um 1 verkleinert
            // (Entscheidung auf Font-12-Basis -> stabil, kein Flackern). Zellbreiten
            // eng an den Inhalt (nur ein Hauch Rand um die Trennlinie).
            let rowIndexWidth: CGFloat = 38
            let baseCell: CGFloat = showVolume ? 98 : 72
            let sepGap: CGFloat = 1          // Kanal-Trennlinie (siehe separator)
            let channelsViewport = geo.size.width - rowIndexWidth
            let neededAtBase = CGFloat(channelCount) * (baseCell + sepGap)
            let needsScroll = channelCount > 4 && neededAtBase > channelsViewport
            let fontSize: CGFloat = needsScroll ? 11 : 12
            let fixedCellWidth: CGFloat? = channelCount > 4 ? baseCell * (fontSize / 12) : nil
            // Inhaltsbreite NUR der Kanalspalten (die Nummern-Spalte steht fest).
            let contentWidth = CGFloat(channelCount) * ((fixedCellWidth ?? 0) + sepGap)

            // Vertikaler Scroll AUSSEN; darin die feststehende Nummern-Spalte plus
            // die horizontal scrollbaren Kanaele. scrollTo() folgt so nur der
            // Y-Achse, und die Nummern bleiben beim H-Scroll links stehen. Die
            // eigene Scrollbar wird per ZStack an den unteren SICHTBAREN Rand
            // gepinnt (nicht ans Ende des langen 64-Zeilen-Inhalts).
            ZStack(alignment: .bottomLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            // Feststehende Nummern-Spalte (scrollt nur vertikal mit).
                            VStack(spacing: 0) {
                                ForEach(0..<64, id: \.self) { rIdx in
                                    if rIdx < pattern.rows.count {
                                        rowIndexCell(rIdx, isCurrent: currentRow == rIdx, fontSize: fontSize)
                                            .id(rIdx)
                                    }
                                }
                            }
                            // Horizontal scrollbare Kanalspalten.
                            horizontalWrapper {
                                // VStack statt LazyVStack: die ~64 Zeilen sind zu klein
                                // für lazy rendering (scrollTo-Sprünge/Jitter sonst).
                                VStack(spacing: 0) {
                                    ForEach(0..<64, id: \.self) { rIdx in
                                        if rIdx < pattern.rows.count {
                                            TrackerRowView(
                                                rIdx: rIdx,
                                                notes: pattern.rows[rIdx].notes,
                                                isCurrent: currentRow == rIdx,
                                                theme: theme,
                                                fixedCellWidth: fixedCellWidth,
                                                showVolume: showVolume,
                                                fontSize: fontSize
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: currentRow) { newRow in
                        // Kein withAnimation: direktes scrollTo landet frame-synchron.
                        proxy.scrollTo(newRow, anchor: .center)
                    }
                }

                // Scrollbar am unteren SICHTBAREN Rand, rechts neben der fixen
                // Nummern-Spalte.
                hScrollBar(viewport: channelsViewport, contentWidth: contentWidth)
                    .padding(.leading, rowIndexWidth)
            }
        }
        .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface)
        .border(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.15), width: theme == .workbench ? 2 : 1)
        .cornerRadius(theme == .workbench ? 0 : 8)
    }
}
