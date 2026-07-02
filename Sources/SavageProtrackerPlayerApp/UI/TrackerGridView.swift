import SwiftUI
import SavageProtrackerPlayerCore

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

    var body: some View {
        let rowIndexColor: Color = isCurrent ? .amigaOrange : (theme == .workbench ? .amigaOrange : .spaceAccentGlow)
        let rowBg: Color = isCurrent ? (theme == .workbench ? Color.amigaOrange.opacity(0.35) : Color.spaceAccent.opacity(0.18)) : Color.clear

        HStack(spacing: 0) {
            // Row Index
            Text(String(format: "%02d", rIdx))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(rowIndexColor)
                .frame(width: 32)
                .padding(.leading, 6)

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
        .frame(height: 24)
        .background(rowBg)
        .overlay(
            Group {
                if isCurrent {
                    Rectangle().stroke(theme == .workbench ? Color.amigaOrange : Color.spaceAccent, lineWidth: 1)
                }
            }
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(theme == .workbench ? Color.amigaWhite.opacity(0.3) : Color.spaceAccent.opacity(0.12))
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

        return HStack(spacing: 8) {
            Text(noteStr).foregroundColor(noteColor)
            Text(instStr).foregroundColor(instColor)
            if showVolume {
                Text(volStr).foregroundColor(volColor)
            }
            Text(effStr).foregroundColor(effColor)
        }
        .font(.system(size: 12, weight: isCurrent ? .bold : .semibold, design: .monospaced))
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
    let pattern: SavageProtrackerPlayerCore.Pattern
    let currentRow: Int
    let theme: PlayerTheme

    // Kanalzahl aus den Pattern-Daten (jede Row hat channelCount Noten).
    private var channelCount: Int {
        pattern.rows.first?.notes.count ?? 4
    }

    // Bis 4 Kanäle direkt (Zellen füllen die Breite), darüber in einen
    // horizontalen ScrollView eingepackt.
    @ViewBuilder
    private func horizontalWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if channelCount > 4 {
            ScrollView(.horizontal) {
                content()
            }
        } else {
            content()
        }
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
        let fixedCellWidth: CGFloat? = channelCount > 4 ? (showVolume ? 150 : 118) : nil

        // Horizontales Scrollen (bei >4 Kanälen) liegt AUSSEN, das vertikale
        // Zeilen-Folgen INNEN: scrollTo() im inneren Reader bewegt so nur die
        // Y-Achse. In einem kombinierten ScrollView([.vertical, .horizontal])
        // zentrierte der Zeilen-Autoscroll sonst bei jedem Row-Wechsel auch
        // horizontal und riss die Ansicht seitlich weg.
        horizontalWrapper {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // VStack statt LazyVStack: 64 Zeilen × 24 pt = 1536 pt — zu klein
                    // für lazy rendering. LazyVStack kennt die Zeilen-Positionen erst
                    // beim Render, was scrollTo-Sprünge und Jitter verursacht.
                    VStack(spacing: 0) {
                        ForEach(0..<64, id: \.self) { rIdx in
                            if rIdx < pattern.rows.count {
                                TrackerRowView(
                                    rIdx: rIdx,
                                    notes: pattern.rows[rIdx].notes,
                                    isCurrent: currentRow == rIdx,
                                    theme: theme,
                                    fixedCellWidth: fixedCellWidth,
                                    showVolume: showVolume
                                )
                                .id(rIdx)
                            }
                        }
                    }
                }
                .onChange(of: currentRow) { newRow in
                    // Kein withAnimation: jede Animation bricht die vorherige ab und
                    // erzeugt die "auf-ab"-Oszillation. SwiftUI ist frame-synchron —
                    // direktes scrollTo landet sauber im nächsten Paint-Zyklus.
                    proxy.scrollTo(newRow, anchor: .center)
                }
            }
        }
        .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface)
        .border(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.15), width: theme == .workbench ? 2 : 1)
        .cornerRadius(theme == .workbench ? 0 : 8)
    }
}
