import SwiftUI
#if os(macOS)
import AppKit

// Einstellungs-Fenster (macOS-Standard: App-Menue > Einstellungen, Cmd+,).
// Aktuell eine Einstellung: der Autoplay-Ordner, aus dem die Playlist beim
// App-Start befuellt wird. Leer = nur die audio/-Fallback-Ordner neben
// Arbeitsverzeichnis bzw. App werden probiert (Verhalten ohne Konfiguration).
struct SettingsView: View {
    // Gleicher Schluessel wie in MainView.loadLocalAudioFolder — @AppStorage
    // haelt beide Stellen automatisch synchron.
    @AppStorage("savage.autoplayFolder") private var autoplayFolderPath: String = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Autoplay-Ordner:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(autoplayFolderPath.isEmpty ? "Nicht gesetzt" : autoplayFolderPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(autoplayFolderPath.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Auswählen…") { chooseFolder() }
                            if !autoplayFolderPath.isEmpty {
                                Button("Entfernen") { autoplayFolderPath = "" }
                            }
                        }
                    }
                }
                Text("Aus diesem Ordner (inklusive Unterordnern und Zip-/7z-Archiven) füllt der Player beim Start die Playlist und beginnt zu spielen. Änderungen wirken ab dem nächsten Start.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        // Beim vorhandenen Pfad starten, sonst im Home-Verzeichnis.
        if !autoplayFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (autoplayFolderPath as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            autoplayFolderPath = url.path
        }
    }
}
#endif
