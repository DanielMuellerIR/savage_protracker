import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct SavageModPlayerApp: App {
    init() {
        // Temp-Kopien frueherer App-Laeufe einmalig beim Start aufraeumen.
        // (Innerhalb einer Sitzung bleiben die pro-Drop-Verzeichnisse bestehen,
        // weil die Playlist sie noch referenziert — siehe cleanStaleTempRoot.)
        MainView.cleanStaleTempRoot()
        #if os(macOS)
        // Zusaetzlich beim regulaeren Beenden aufraeumen (Temp-Kopien und
        // entpackte Archive verschwinden sofort); die Start-Reinigung oben
        // bleibt als Fallnetz fuer Abstuerze/Force-Quit bestehen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainView.cleanStaleTempRoot()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                #if os(macOS)
                .navigationTitle("Savage Mod Player")
                #endif
        }
        .commands {
            #if os(macOS)
            // Standard-"Über"-Eintrag im App-Menü durch einen eigenen ersetzen,
            // damit der native macOS-About-Panel Autor und Lizenz zeigt (Icon,
            // Name und Version kommen automatisch aus dem Bundle). Der verspielte
            // Guru-Meditation-Screen bleibt zusätzlich über den ⓘ-Button erhalten.
            CommandGroup(replacing: .appInfo) {
                Button("Über Savage Mod Player") {
                    let credits = NSAttributedString(
                        string: "Entwickelt von Daniel Müller.\n\n"
                            + "ProTracker-/Paula-Engine: Eigenentwicklung (kein libopenmpt), "
                            + "aus dem Schwesterprojekt FraktalLab nach Swift portiert.\n\n"
                            + "Lizenz: WTFPL (Do What The Fuck You Want To Public License).\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.labelColor
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }

            CommandMenu("Wiedergabe") {
                Button("Abspielen / Pause") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuPlayStop"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Stopp") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuStop"), object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("Nächster Titel") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuNextTrack"), object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                
                Button("Vorheriger Titel") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuPrevTrack"), object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            #endif
        }

        #if os(macOS)
        // Natives Einstellungs-Fenster (App-Menue > Einstellungen, Cmd+,) —
        // aktuell nur der Autoplay-Ordner fuer die Start-Playlist.
        Settings {
            SettingsView()
        }
        #endif
    }
}
