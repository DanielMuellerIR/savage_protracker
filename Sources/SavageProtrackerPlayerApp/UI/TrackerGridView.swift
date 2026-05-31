import SwiftUI
import SavageProtrackerPlayerCore

struct TrackerRowView: View {
    let rIdx: Int
    let note0: Note
    let note1: Note
    let note2: Note
    let note3: Note
    let isCurrent: Bool
    let theme: PlayerTheme
    
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
            
            separator
            
            channelCell(note: note0)
                .frame(maxWidth: .infinity)
            
            separator
            
            channelCell(note: note1)
                .frame(maxWidth: .infinity)
            
            separator
            
            channelCell(note: note2)
                .frame(maxWidth: .infinity)
            
            separator
            
            channelCell(note: note3)
                .frame(maxWidth: .infinity)
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
        let hasNote = note.period > 0
        let hasInst = note.instrument > 0
        let hasEff = note.hasEffect
        
        let noteStr = hasNote ? periodToNoteName(note.period) : "---"
        let instStr = hasInst ? String(format: "%02X", note.instrument) : "--"
        
        var effStr = "..."
        if hasEff {
            if note.effectId >= 0xE0 {
                let subEff = note.effectId & 0x0F
                effStr = String(format: "E%X%X", subEff, note.effectData)
            } else {
                effStr = String(format: "%01X%02X", note.effectId, note.effectData)
            }
        }
        
        let noteColor: Color = hasNote ? (theme == .workbench ? .amigaWhite : .codeNote) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)
        let instColor: Color = hasInst ? (theme == .workbench ? .amigaGrey : .codeInstrument) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)
        let effColor: Color = hasEff ? (theme == .workbench ? .amigaOrange : .codeEffect) : (theme == .workbench ? .amigaWhite.opacity(0.3) : .codeDim)
        
        return HStack(spacing: 8) {
            Text(noteStr).foregroundColor(noteColor)
            Text(instStr).foregroundColor(instColor)
            Text(effStr).foregroundColor(effColor)
        }
        .font(.system(size: 12, weight: isCurrent ? .bold : .semibold, design: .monospaced))
    }
    
    private func periodToNoteName(_ period: Int) -> String {
        guard period >= 113 && period <= 856 else { return "---" }
        
        let noteNames = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]
        
        // Logarithmic calculation from modplayer.js
        let noteIndexDouble = 24.0 + 12.0 * log2(428.0 / Double(period))
        let noteIndex = Int(round(noteIndexDouble))
        
        guard noteIndex >= 0 else { return "---" }
        
        let noteName = noteNames[noteIndex % 12]
        let octave = (noteIndex / 12) + 1
        return "\(noteName)\(octave)"
    }
}

struct TrackerGridView: View {
    let pattern: SavageProtrackerPlayerCore.Pattern
    let currentRow: Int
    let theme: PlayerTheme
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<64, id: \.self) { rIdx in
                        if pattern.rows[rIdx].notes.count >= 4 {
                            TrackerRowView(
                                rIdx: rIdx,
                                note0: pattern.rows[rIdx].notes[0],
                                note1: pattern.rows[rIdx].notes[1],
                                note2: pattern.rows[rIdx].notes[2],
                                note3: pattern.rows[rIdx].notes[3],
                                isCurrent: currentRow == rIdx,
                                theme: theme
                            )
                            .id(rIdx)
                        }
                    }
                }
            }
            .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface)
            .border(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.15), width: theme == .workbench ? 2 : 1)
            .cornerRadius(theme == .workbench ? 0 : 8)
            .onChange(of: currentRow) { newRow in
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(newRow, anchor: .center)
                }
            }
        }
    }
}
