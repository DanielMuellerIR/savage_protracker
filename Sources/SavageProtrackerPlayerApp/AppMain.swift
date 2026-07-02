import SwiftUI

@main
struct SavageProtrackerPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                #if os(macOS)
                .navigationTitle("Savage Protracker Player")
                #endif
        }
        .commands {
            #if os(macOS)
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
    }
}
