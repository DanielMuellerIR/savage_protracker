import Foundation
import QuickLookUI
import UniformTypeIdentifiers

// Principal Class der Quick-Look-Extension (datenbasierte Preview,
// QLIsDataBasedPreview = true in der Info.plist des Appex).
//
// Funktionsweise: Die Extension parst das Tracker-Modul (alle MOD-Varianten
// + S3M/XM/IT über ModuleLoader) und rendert es mit der identischen DSP-Engine des
// Players offline zu WAV-Daten. Quick Look zeigt für die gelieferten
// WAV-Daten den nativen macOS-Audio-Player — damit ist das Modul direkt im
// Finder (Leertaste) abspielbar, inklusive Scrubbing und Lautstärke.
//
// Hinweis zum Build: Dieses File wird NICHT über SwiftPM gebaut, sondern von
// build_app.sh zusammen mit den SavageModPlayerCore-Quellen per swiftc
// in EIN Modul kompiliert (deshalb kein `import SavageModPlayerCore`).
class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    // Quick Look soll unmittelbar als Vorschau reagieren, nicht erst nach einem
    // minutenlangen Komplett-Render. Eine Minute enthält bei Trackern meist den
    // charakteristischen Einstieg und begrenzt CPU, RAM und WAV-Größe zuverlässig.
    private static let previewDurationSeconds = 60.0

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        do {
            let data = try Data(contentsOf: request.fileURL)
            let mod = try ModuleLoader.parse(data: data)

            // WICHTIG: Die WAV als DATEI-URL liefern, nicht als Daten-Reply.
            // QLPreviewReply(dataOfContentType:) zeigt fuer Audio nur die
            // generische Info-Karte; erst initWithFileURL: (laut Header explizit
            // inkl. UTTypeAudio) bekommt den nativen Audio-Player mit
            // Play/Scrubbing. Die Datei liegt im Sandbox-Container der Extension.
            let wavURL = try Self.previewWav(for: mod, sourceURL: request.fileURL)
            let reply = QLPreviewReply(fileURL: wavURL)

            // Titelzeile des Preview-Fensters: Songname + Format + Kanalzahl.
            let title = mod.name.isEmpty ? request.fileURL.lastPathComponent : mod.name
            reply.title = "\(title) — \(mod.format.displayName), \(mod.usedChannelCount) Kanäle (Vorschau bis 60 s)"
            return reply
        } catch {
            // Ein Parserfehler darf nicht wie ein nie endender Ladeindikator
            // aussehen. Eine kleine Textdatei liefert Quick Look sofort aus und
            // zeigt den konkreten Grund, ohne eine kaputte Audio-WAV vorzutäuschen.
            let errorURL = try Self.writeErrorPreview(error, sourceURL: request.fileURL)
            let reply = QLPreviewReply(fileURL: errorURL)
            reply.title = "\(request.fileURL.lastPathComponent) — keine Wiedergabe möglich"
            return reply
        }
    }

    // Rendert jede unveränderte Quelldatei nur einmal. Finder fordert dieselbe
    // Vorschau häufig mehrfach an; ohne diesen Cache sah der Nutzer bei jedem
    // Öffnen wieder lange den Ladeindikator.
    private static func previewWav(for mod: Mod, sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SavagePreviews", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize ?? 0
        let timestamp = Int(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let cachedURL = dir.appendingPathComponent("\(sourceName)-\(fileSize)-\(timestamp).wav")
        if fm.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        let wav = try ModuleRenderer.renderWavData(
            mod: mod,
            maxDurationSeconds: previewDurationSeconds
        )

        // Aufraeumen: Der Dateistempel ist Teil des Cache-Schlüssels. Alte
        // Varianten bleiben nur kurz liegen, damit wiederholtes Leertasten
        // schnell bleibt, ohne den Extension-Container dauerhaft zu füllen.
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86_400)
            for url in existing {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if mtime < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }

        // Zuerst in eine private temporäre Datei schreiben und danach umbenennen:
        // parallele Finder-Anfragen können so nie eine halbfertige WAV erhalten.
        let temporaryURL = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: temporaryURL, options: .atomic)
        do {
            try fm.moveItem(at: temporaryURL, to: cachedURL)
            return cachedURL
        } catch {
            try? fm.removeItem(at: temporaryURL)
            if fm.fileExists(atPath: cachedURL.path) { return cachedURL }
            throw error
        }
    }

    private static func writeErrorPreview(_ error: Error, sourceURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavagePreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let message = """
        Savage Mod Player konnte dieses Modul nicht wiedergeben.

        Datei: \(sourceURL.lastPathComponent)

        Grund: \(error.localizedDescription)

        Bei neueren OpenMPT-IT-Dateien können proprietäre Erweiterungen außerhalb der nativen Impulse-Tracker-2.14-/2.15-Unterstützung liegen.
        """
        let url = dir.appendingPathComponent("Fehler-\(UUID().uuidString).txt")
        try Data(message.utf8).write(to: url, options: .atomic)
        return url
    }
}
