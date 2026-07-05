import Foundation
import QuickLookUI
import UniformTypeIdentifiers

// Principal Class der Quick-Look-Extension (datenbasierte Preview,
// QLIsDataBasedPreview = true in der Info.plist des Appex).
//
// Funktionsweise: Die Extension parst das Tracker-Modul (alle MOD-Varianten
// + S3M über ModuleLoader) und rendert es mit der identischen DSP-Engine des
// Players offline zu WAV-Daten. Quick Look zeigt für die gelieferten
// WAV-Daten den nativen macOS-Audio-Player — damit ist das Modul direkt im
// Finder (Leertaste) abspielbar, inklusive Scrubbing und Lautstärke.
//
// Hinweis zum Build: Dieses File wird NICHT über SwiftPM gebaut, sondern von
// build_app.sh zusammen mit den SavageModPlayerCore-Quellen per swiftc
// in EIN Modul kompiliert (deshalb kein `import SavageModPlayerCore`).
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let mod = try ModuleLoader.parse(data: data)
        let wav = try ModuleRenderer.renderWavData(mod: mod)

        // WICHTIG: Die WAV als DATEI-URL liefern, nicht als Daten-Reply.
        // QLPreviewReply(dataOfContentType:) zeigt fuer Audio nur die
        // generische Info-Karte; erst initWithFileURL: (laut Header explizit
        // inkl. UTTypeAudio) bekommt den nativen Audio-Player mit
        // Play/Scrubbing. Die Datei liegt im Sandbox-Container der Extension.
        let wavURL = try Self.writePreviewWav(wav, sourceName: request.fileURL.deletingPathExtension().lastPathComponent)
        let reply = QLPreviewReply(fileURL: wavURL)

        // Titelzeile des Preview-Fensters: Songname + Format + Kanalzahl.
        let title = mod.name.isEmpty ? request.fileURL.lastPathComponent : mod.name
        reply.title = "\(title) — \(mod.format.displayName), \(mod.channelCount) Kanäle"
        return reply
    }

    // Schreibt die gerenderte WAV in den Temp-Bereich des Extension-Containers.
    // Eindeutiger Dateiname pro Request (parallele Previews); Altbestand wird
    // best-effort weggeraeumt, damit der Container nicht zumuellt.
    private static func writePreviewWav(_ wav: Data, sourceName: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SavagePreviews", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Aufraeumen: alles loeschen, was aelter als eine Stunde ist.
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-3600)
            for url in existing {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if mtime < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        let url = dir.appendingPathComponent("\(sourceName)-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }
}
