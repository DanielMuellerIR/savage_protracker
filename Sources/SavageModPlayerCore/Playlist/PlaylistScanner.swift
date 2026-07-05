import Foundation

// Sammelt Mod-Dateien aus gedroppten URLs bzw. dem Start-Ordner ein und baut
// daraus eine hierarchische Ordner-Struktur fuer die Playlist-Anzeige.
//
// Kernideen:
// - Jede gefundene Datei wird (wie bisher) in ein Temp-Verzeichnis kopiert,
//   merkt sich aber zusaetzlich ihren relativen Ordner-Pfad (`folderPath`).
//   Daraus baut `buildTree` den Anzeigebaum; `flattenedFiles` liefert die
//   flache Abspiel-Reihenfolge (Tiefensuche) — damit funktionieren
//   Weiter/Zurueck, Shuffle und Playlist-Loop unveraendert ueber alle
//   Ordner hinweg.
// - Archive (.zip/.7z) werden unsichtbar per System-`bsdtar` ins
//   Temp-Verzeichnis entpackt und wie ein Ordner behandelt (Knoten-Name =
//   Archivname ohne Endung). Der Nutzer sieht nie entpackte Dateien im
//   Quell-Ordner; aufgeraeumt wird das Temp-Verzeichnis von der App
//   (Start + Beenden).
public enum PlaylistScanner {

    // Eine gefundene Mod-Datei: Temp-Kopie + Original-Anzeigename + Ordner-Pfad
    // relativ zur Drop-/Scan-Wurzel (z.B. ["Chiptunes", "4mat"]).
    public struct Entry: Sendable {
        public let url: URL
        public let displayName: String
        public let folderPath: [String]

        public init(url: URL, displayName: String, folderPath: [String]) {
            self.url = url
            self.displayName = displayName
            self.folderPath = folderPath
        }
    }

    // Ein Ordner-Knoten des Anzeigebaums. `path` ist die mit "/" verbundene
    // Komponenten-Kette und dient als stabile ID fuers Auf-/Zuklappen.
    public struct FolderNode: Sendable {
        public let name: String
        public let path: String
        public var subfolders: [FolderNode]
        public var files: [Entry]
    }

    // Archiv-Endungen, die wie Ordner behandelt werden.
    public static let archiveExtensions: Set<String> = ["zip", "7z"]

    // Mod-Erkennung: bekannte Endungen oder Amiga-Konvention "mod.<name>".
    public static func isModFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return ModuleLoader.supportedExtensions.contains(ext) || name.hasPrefix("mod.")
    }

    public static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    // Schneller Vorab-Check fuer den Start-Ordner: enthaelt das Verzeichnis
    // (rekursiv) mindestens eine Mod-Datei oder ein Archiv?
    public static func directoryContainsPlayableContent(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        while let fileURL = enumerator.nextObject() as? URL {
            if isModFile(fileURL) || isArchive(fileURL) { return true }
        }
        return false
    }

    // MARK: - Einsammeln

    // Kopiert alle Mod-Dateien aus den URLs (Dateien, Ordner rekursiv, Archive
    // entpackt) nach `tempDir` und liefert die Eintraege samt Ordner-Pfad.
    // Beruehrt keinen UI-State — laeuft sicher abseits des Main-Threads.
    public static func collectEntries(from urls: [URL], tempDir: URL) -> [Entry] {
        let fm = FileManager.default
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        var entries: [Entry] = []

        // Eine einzelne Datei einsortieren: Mods kopieren, Archive entpacken
        // und deren Inhalt als Unterordner scannen. `archiveDepth` begrenzt
        // Archiv-in-Archiv-Rekursion.
        func handleFile(_ fileURL: URL, folderPath: [String], archiveDepth: Int) {
            if isModFile(fileURL) {
                // UUID-Praefix vermeidet Namens-Kollisionen im flachen Temp-Ziel;
                // die UI blendet ihn beim Anzeigen wieder aus (cleanFilename).
                let destURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(fileURL.lastPathComponent)")
                do {
                    try fm.copyItem(at: fileURL, to: destURL)
                    entries.append(Entry(url: destURL, displayName: fileURL.lastPathComponent, folderPath: folderPath))
                } catch {
                    print("Fehler beim Kopieren: \(error)")
                }
            } else if isArchive(fileURL), archiveDepth < 3 {
                if let extractedDir = extractArchive(fileURL, tempDir: tempDir) {
                    // Archivname ohne Endung als Ordner-Name — dass es ein
                    // Archiv war, soll man in der Playlist nicht merken.
                    let nodeName = (fileURL.lastPathComponent as NSString).deletingPathExtension
                    scanDirectory(extractedDir, folderPath: folderPath + [nodeName], archiveDepth: archiveDepth + 1)
                }
            }
        }

        // Ordner rekursiv absteigen und dabei die relativen Pfad-Komponenten
        // mitfuehren (der fruehere flache enumerator verlor die Hierarchie).
        func scanDirectory(_ dir: URL, folderPath: [String], archiveDepth: Int) {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children {
                // Das eigene Temp-Wurzelverzeichnis nie als Kind mitscannen —
                // sonst wuerden frisch angelegte Kopien erneut eingesammelt,
                // falls tempDir (wie in Tests) innerhalb der Scan-Wurzel liegt.
                // (Die extracted-Unterverzeichnisse DARUNTER werden dagegen
                // gezielt per scanDirectory betreten — nicht ausschliessen.)
                if child.standardizedFileURL.path == tempDir.standardizedFileURL.path { continue }
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    scanDirectory(child, folderPath: folderPath + [child.lastPathComponent], archiveDepth: archiveDepth)
                } else {
                    handleFile(child, folderPath: folderPath, archiveDepth: archiveDepth)
                }
            }
        }

        for url in urls {
            // Drag&Drop liefert ggf. security-scoped URLs (Sandbox) — Zugriff
            // pro Wurzel-URL oeffnen und wieder schliessen.
            let accessed = url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    scanDirectory(url, folderPath: [], archiveDepth: 0)
                } else {
                    handleFile(url, folderPath: [], archiveDepth: 0)
                }
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return entries
    }

    // Entpackt ein Archiv in ein frisches Unterverzeichnis von `tempDir` und
    // liefert dessen URL (nil bei Fehler). Nutzt das System-`bsdtar`
    // (libarchive), das sowohl Zip als auch 7-Zip lesen kann — keine
    // Zusatz-Abhaengigkeit noetig.
    private static func extractArchive(_ archive: URL, tempDir: URL) -> URL? {
        #if os(macOS)
        let fm = FileManager.default
        let dest = tempDir.appendingPathComponent("extracted-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-x", "-f", archive.path, "-C", dest.path]
            // Fehlermeldungen nicht ins App-Log spammen; Erfolg zaehlt per Exit-Code.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                print("Archiv nicht lesbar (bsdtar exit \(process.terminationStatus)): \(archive.lastPathComponent)")
                return nil
            }
            return dest
        } catch {
            print("Archiv-Entpacken fehlgeschlagen: \(error)")
            return nil
        }
        #else
        // Auf Nicht-macOS-Plattformen gibt es kein Process/bsdtar — Archive
        // werden dort schlicht ignoriert.
        return nil
        #endif
    }

    // MARK: - Baum bauen & abflachen

    // Baut aus den Eintraegen den Anzeigebaum. Sortierung pro Ebene:
    // erst Unterordner (alphabetisch), dann Dateien (alphabetisch) —
    // klassische Baumansicht. Diese Reihenfolge ist zugleich die
    // Abspiel-Reihenfolge (siehe flattenedFiles).
    public static func buildTree(_ entries: [Entry]) -> FolderNode {
        // Zwischenstruktur mit Referenz-Semantik, damit das Einsortieren ohne
        // umstaendliches Kopieren verschachtelter Value-Types auskommt.
        final class MutableNode {
            let name: String
            let path: String
            var subfolders: [String: MutableNode] = [:]
            var files: [Entry] = []
            init(name: String, path: String) {
                self.name = name
                self.path = path
            }
        }

        let root = MutableNode(name: "", path: "")
        for entry in entries {
            var node = root
            for component in entry.folderPath {
                let childPath = node.path.isEmpty ? component : "\(node.path)/\(component)"
                if let existing = node.subfolders[component] {
                    node = existing
                } else {
                    let child = MutableNode(name: component, path: childPath)
                    node.subfolders[component] = child
                    node = child
                }
            }
            node.files.append(entry)
        }

        func freeze(_ node: MutableNode) -> FolderNode {
            let sortedFolders = node.subfolders.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(freeze)
            let sortedFiles = node.files
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return FolderNode(name: node.name, path: node.path, subfolders: sortedFolders, files: sortedFiles)
        }
        return freeze(root)
    }

    // Flache Abspiel-Reihenfolge: Tiefensuche durch den Baum in Anzeige-
    // Reihenfolge. Index-basierte Logik (Weiter/Zurueck/Shuffle) laeuft damit
    // automatisch ueber Ordner-Grenzen hinweg.
    public static func flattenedFiles(_ node: FolderNode) -> [Entry] {
        var result: [Entry] = []
        for sub in node.subfolders {
            result.append(contentsOf: flattenedFiles(sub))
        }
        result.append(contentsOf: node.files)
        return result
    }
}
