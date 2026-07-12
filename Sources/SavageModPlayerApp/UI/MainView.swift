import SwiftUI
import SavageModPlayerCore
import UniformTypeIdentifiers
import UserNotifications
import MediaPlayer

final class DropURLsContainer: @unchecked Sendable {
    let lock = NSLock()
    var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

enum LoopMode: String, CaseIterable, Identifiable {
    case playlist = "Wiederhole Playlist"
    case track = "Wiederhole Song"
    case none = "Einmal abspielen"
    
    var id: String { self.rawValue }
    
    var iconName: String {
        switch self {
        case .playlist: return "repeat"
        case .track: return "repeat.1"
        case .none: return "play.slash"
        }
    }
}

struct MainView: View {
    @StateObject var coordinator = ModPlayerCoordinator()
    // Theme, Lautstaerke und loopMode ueber Neustarts hinweg merken (@AppStorage).
    @AppStorage("savage.theme") var theme: PlayerTheme = .cyber
    @AppStorage("savage.volume") var volume: Double = 0.6
    // Default Playlist-Wiederholung: Der Player laedt beim Start den ganzen
    // audio-Ordner; am Songende automatisch zum naechsten Titel zu springen ist
    // fuer einen Playlist-Player das erwartete Verhalten (frueher lief der loopMode
    // ins Leere und der Renderblock wiederholte denselben Song endlos).
    @AppStorage("savage.loopMode") var loopMode: LoopMode = .playlist
    // Shuffle: Titel-Wechsel (weiter/zurueck/Songende) springt zufaellig statt
    // sequenziell durch die Playlist. Ueberlebt App-Neustarts.
    @AppStorage("savage.shuffle") var shuffleEnabled = false

    // Zuletzt gespielter Titel als stabiler Anzeigename (ohne UUID-Temp-Praefix).
    // Bei ausgeschaltetem Shuffle nimmt der naechste Start diesen Titel wieder
    // auf, statt stur beim ersten der Liste zu beginnen.
    @AppStorage("savage.lastPlayed") var lastPlayedSongName: String = ""

    // Autoplay-Ordner aus den Einstellungen (leer = nicht gesetzt, dann greifen
    // nur die audio/-Fallbacks in loadLocalAudioFolder). Gesetzt wird der Wert
    // im Einstellungs-Fenster (SettingsView, gleicher Schluessel).
    @AppStorage("savage.autoplayFolder") var autoplayFolderPath: String = ""

    // Breite der Playlist-Sidebar (ziehbar per Trenn-Handle). Persistiert, damit
    // lange Dateinamen dauerhaft sichtbar bleiben (LIDA-XM-Problem: 260 pt fix war
    // zu schmal, um das Datei-Ende je zu sehen). Geklemmt in sidebarWidthRange.
    @AppStorage("savage.sidebarWidth") var sidebarWidth: Double = 260

    // Höhe der "ZULETZT GESPIELT"-Sektion unten in der Sidebar (ziehbar, persistiert).
    @AppStorage("savage.recentHeight") var recentHeight: Double = 96

    // Sidebar tabs
    @State var selectedSidebarTab: Int = 0 // 0 = Playlist, 1 = Instrumente
    
    // Playlist states
    // `playlist` bleibt die flache Abspielliste in Anzeige-Reihenfolge
    // (Tiefensuche durch den Baum) — Weiter/Zurueck/Shuffle/Loop arbeiten
    // damit unveraendert ueber alle Ordner hinweg.
    @State var playlist: [URL] = []
    @State var currentPlaylistIndex: Int = -1
    // Hierarchische Anzeige: Ordner-/Archiv-Baum der aktuellen Playlist,
    // Menge der aufgeklappten Ordner-Pfade und Ordner-Pfad je Datei
    // (fuers Auto-Aufklappen des gerade laufenden Titels).
    @State var playlistTree: PlaylistScanner.FolderNode? = nil
    @State var expandedFolders: Set<String> = []
    @State var folderPathByURL: [URL: [String]] = [:]
    
    // Search & Filter
    @State var playlistSearchQuery: String = ""
    // Favoriten-Filter: zeigt nur mit Stern markierte Titel (Umschalt-Knopf im
    // Playlist-Kopf).
    @State var favoritesOnly = false
    // Gemerkte Favoriten. Schlüssel ist bewusst der BEREINIGTE Dateiname
    // (cleanFilename), NICHT der Pfad: Drag&Drop-Titel werden in pro-Sitzung
    // wechselnde Temp-Ordner kopiert — ein pfadbasierter Schlüssel überlebte den
    // Neustart nicht. Der bereinigte Name (ohne Temp-UUID-Präfix) ist über
    // Sitzungen hinweg stabil. Persistiert in UserDefaults (siehe
    // loadFavorites/toggleFavorite).
    @State var favorites: Set<String> = []

    // Recent Songs History
    @State var recentSongs: [URL] = []
    
    @State var showFileImporter = false
    @State var dragOver = false
    @State var errorMessage: String? = nil
    @State var compatibilityMessage: String? = nil
    // Wurde beim Start bereits Inhalt über ein Startargument oder „Öffnen mit"
    // (.onOpenURL) geladen? Dann NICHT zusätzlich den Autoplay-Ordner laden —
    // sonst überschrieb/übertönte der Default-Ordner den bewusst geöffneten
    // Titel (Race zwischen onAppear und onOpenURL beim Kaltstart).
    @State var didLoadInitialContent = false
    
    // Keyboard HUD & About Overlay Modals
    @State var showKeyboardHUD = false
    @State var showAboutModal = false
    
    // WAV Export Panel
    @State var isExporting = false
    @State var showExportDialog = false
    @State var exportSecondsLimit: Double = 180.0
    @State var exportStatusMessage: String? = nil
    
    // Disk rotation state
    // Steuert die Rotation der Drop-Zone-Disc (nur wenn kein Song läuft). Die
    // Play/Pause-Transport-Disk dreht sich in ihrem eigenen View (SpinningDiskButton)
    // mit lokalem State — nicht mehr über ein @State auf MainView (CPU, 2026-07-09).
    @State var isDiskAnimating = false
    // Fokus-Steuerung des Playlist-Suchfelds (kein Autofokus beim Start).
    @FocusState var searchFieldFocused: Bool
    // MPRemoteCommandCenter nur einmal verdrahten (onAppear kann mehrfach feuern).
    @State var mediaCommandsConfigured = false
    
    // Active Preview hover card
    @State var hoveredInstrumentIndex: Int? = nil

    // Lokaler Tastatur-Monitor (Leertaste/Pfeile/ESC). Token wird in
    // .onDisappear wieder entfernt, damit nichts leakt.
    @State var keyMonitor: Any? = nil
    
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Sidebar for Playlist or Instruments
                VStack(spacing: 0) {
                    // Sidebar Custom Tab Picker
                    HStack(spacing: 0) {
                        TabButton(title: "PLAYLIST", tag: 0, selection: $selectedSidebarTab, theme: theme)
                        TabButton(title: "INSTRUMENTE", tag: 1, selection: $selectedSidebarTab, theme: theme)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(theme == .workbench ? Color.lightSurface : Color.clear)
                    
                    Divider()
                        .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.2))
                    
                    if selectedSidebarTab == 0 {
                        playlistSidebar
                    } else {
                        instrumentsSidebar
                    }
                }
                .frame(width: CGFloat(sidebarWidth))
                .background(
                    theme == .workbench ? Color.lightSurface : Color.spaceSurface
                )

                // Ziehbarer Trenn-Handle zwischen Playlist und Hauptbereich:
                // erlaubt, die Sidebar breit genug zu ziehen, um lange Dateinamen
                // vollständig zu lesen. Breite wird persistiert.
                ResizableDivider(
                    width: $sidebarWidth,
                    range: 200...640,
                    theme: theme
                )

                // Main Panel
                VStack(spacing: 0) {
                    // Header (Track Title and Metadata)
                    headerView
                        .padding()
                        .background(theme == .workbench ? Color.lightSurface : Color.spaceSurface.opacity(0.4))

                    // Nicht-fatale Formatwarnungen bleiben auch bei laufender
                    // Wiedergabe sichtbar. Im Drop-Bereich verschwanden sie direkt
                    // nach erfolgreichem Laden zusammen mit der leeren Ansicht.
                    if let compatibilityMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(compatibilityMessage)
                                .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(theme == .workbench ? 0.12 : 0.08))
                    }
                    
                    Divider()
                        .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.2))
                    
                    // Pattern Position Marker Map list — beobachtet transport (nicht
                    // coordinator), damit die Positions-Marker MainView nicht neu rendern.
                    if let mod = coordinator.activeMod {
                        PatternMarkerMap(transport: coordinator.transport, mod: mod, theme: theme,
                                         onSeek: { coordinator.seek(toPosition: $0) })
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .background(theme == .workbench ? Color.lightSurface.opacity(0.3) : Color.spaceBackground.opacity(0.4))
                        Divider()
                            .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.1))
                    }
                    
                    // VU Visualizers & Synthesis Options Panel
                    vuVisualizersView
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground.opacity(0.2))
                    
                    Divider()
                        .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.1))
                    
                    // Scrolling Tracker Grid or Empty State Drop Zone
                    VStack(spacing: 0) {
                        // Defensiv gegen leere/korrupte Mods: length, patternTable und
                        // der daraus gelesene patternIndex werden vor dem Zugriff geprueft
                        // (sonst patternTable[-1] / patterns[ausserhalb] -> Crash).
                        // codereview-ok: defensiv by-design — patternTable wird direkt danach indiziert; der isEmpty/length-Guard verhindert patternTable[-1]-Crash (2026-07-01)
                        if let mod = coordinator.activeMod,
                           mod.length > 0,
                           !mod.patternTable.isEmpty {
                            // Grid + Zeilenmarkierung beobachten transport (row-rate),
                            // damit die Zeilenwechsel MainView nicht neu evaluieren.
                            TrackerGridContainer(transport: coordinator.transport, mod: mod,
                                                 channelIndices: mod.displayChannelIndices, theme: theme,
                                                 onSeekRow: { row in
                                                     // Zu (aktuelle Position, geklickte Zeile) springen;
                                                     // Tempo wird rekonstruiert. Play/Weiter spielt ab hier.
                                                     coordinator.seek(toPosition: coordinator.currentPosition, row: row)
                                                 })
                                .padding()
                        } else {
                            dropZonePrompt
                                .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme == .workbench ? Color.lightSurfaceAlt : Color.clear)
                    
                    Divider()
                        .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.2))
                    
                    // Master Oscilloscope & Separation Sliders
                    masterOscilloscopeView
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground.opacity(0.3))
                    
                    Divider()
                        .background(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.3))
                    
                    // Toolbar Control Panel
                    controlPanelView
                        .padding()
                        .background(theme == .workbench ? Color.lightSurface : Color.spaceSurface.opacity(0.4))
                }
                .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground)
            }
            .frame(minWidth: 1080, minHeight: 720)
            .foregroundColor(theme == .workbench ? Color.lightTextPrimary : Color.spaceTextPrimary)
            .font(theme == .workbench ? .system(.body) : .body)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, UTType(filenameExtension: "mod"), UTType(filenameExtension: "s3m"), UTType(filenameExtension: "xm"), UTType(filenameExtension: "it")].compactMap { $0 },
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    handleDroppedURLs(urls)
                case .failure(let error):
                    self.errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $dragOver) { providers in
                // WICHTIG: `loadObject(ofClass: URL.self)` dekodiert die Datei-URL
                // korrekt. Der frühere Weg (loadItem + Data manuell parsen) baute
                // die URL mit `URL(fileURLWithPath:)` aus einem "file:///…"-STRING
                // — das interpretiert den String als PFAD, nicht als URL, sodass
                // die Datei nie gefunden wurde (Drop tat scheinbar nichts). macOS
                // liefert `public.file-url` heute als URL-String-Data, nicht mehr
                // als Plist mit rohem Pfad wie früher.
                let container = DropURLsContainer()
                let dispatchGroup = DispatchGroup()

                for provider in providers {
                    guard provider.canLoadObject(ofClass: URL.self) else { continue }
                    dispatchGroup.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url, url.isFileURL { container.append(url) }
                        dispatchGroup.leave()
                    }
                }

                dispatchGroup.notify(queue: .main) {
                    let urls = container.urls
                    if !urls.isEmpty {
                        // Ein Drop aufs Fenster startet die Wiedergabe sofort — der
                        // Nutzer hat die Datei/den Ordner bewusst reingezogen.
                        handleDroppedURLs(urls, autoPlay: true)
                    }
                }
                return true
            }
            // Finder „Öffnen mit" / Doppelklick auf eine .mod/.s3m/.xm/.it: die App
            // erhält die URL hierüber (nicht als argv) — direkt laden und abspielen.
            .onOpenURL { url in
                // „Öffnen mit" / Dock-Drop / Doppelklick: bewusst geöffneten Titel
                // laden + abspielen und den Autoplay-Ordner unterdrücken (auch
                // wenn onAppear leicht später feuert).
                didLoadInitialContent = true
                handleDroppedURLs([url], autoPlay: true)
            }
            .onAppear {
                isDiskAnimating = coordinator.isPlaying
                loadFavorites()
                setupNotifications()
                installKeyMonitor()
                setupMediaRemoteCommands()
                // Gespeicherte Lautstaerke in den Coordinator spiegeln, damit der
                // erste play()-Aufruf sie auf den Mixer anwenden kann.
                coordinator.setVolume(Float(volume))
                // Datei/Ordner als Startargument (z.B. `SavageModPlayer <song.xm>`
                // oder Öffnen-mit) hat Vorrang vor dem Autoplay-Ordner: direkt laden
                // und abspielen — praktisch für headless Tests/CPU-Messungen ohne
                // Klicken. Sonst wie bisher den konfigurierten Autoplay-Ordner laden.
                if let launchURL = Self.launchFileArgument() {
                    didLoadInitialContent = true
                    handleDroppedURLs([launchURL], autoPlay: true)
                } else {
                    // Verzögert, damit ein beim Kaltstart über „Öffnen mit"
                    // eintreffendes .onOpenURL zuerst greifen kann (setzt das Flag).
                    // Dann laden wir NICHT zusätzlich den Autoplay-Ordner.
                    DispatchQueue.main.async {
                        guard !didLoadInitialContent else { return }
                        loadLocalAudioFolder()
                    }
                }
                // Autofokus des Suchfelds wieder wegnehmen — macOS setzt den
                // First Responder erst nach dem Fensteraufbau, daher verzoegert.
                DispatchQueue.main.async {
                    searchFieldFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .onDisappear {
                removeKeyMonitor()
            }
            .onChange(of: coordinator.isPlaying) { isPlaying in
                isDiskAnimating = isPlaying && !coordinator.isPaused
            }
            // Pause haelt auch die Disk-Animation an (isPlaying bleibt true).
            .onChange(of: coordinator.isPaused) { isPaused in
                isDiskAnimating = coordinator.isPlaying && !isPaused
            }
            .onChange(of: coordinator.trackName) { newTrackName in
                if coordinator.isPlaying {
                    fireNotification(for: newTrackName)
                }
            }
            // Songende: loopMode auswerten (stop / wiederholen / naechster Titel).
            .onChange(of: coordinator.songEndPulse) { _ in
                handleSongEnd()
            }
            // Menue-Befehle (Cmd+P / Cmd+Pfeile) aus AppMain wieder anschliessen —
            // sie posteten bisher NSNotifications, die niemand beobachtet hat.
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("menuPlayStop"))) { _ in
                togglePlayback()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("menuStop"))) { _ in
                stopPlayback()
            }
            // Media-Tasten: explizites Play/Pause (im Gegensatz zum Toggle).
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("mediaPlay"))) { _ in
                if coordinator.isPaused {
                    coordinator.resume()
                } else if !coordinator.isPlaying {
                    togglePlayback()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("mediaPause"))) { _ in
                coordinator.pause()
            }
            // "Now Playing"-Infos fuer die Media-Tasten-Zuordnung aktuell halten.
            .onChange(of: coordinator.isPaused) { _ in updateNowPlayingInfo() }
            .onChange(of: coordinator.isPlaying) { _ in updateNowPlayingInfo() }
            .onChange(of: coordinator.trackName) { _ in updateNowPlayingInfo() }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("menuNextTrack"))) { _ in
                nextTrack()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("menuPrevTrack"))) { _ in
                prevTrack()
            }
            
            // Retro Amiga Failure Guru Meditation popup Modal
            if showAboutModal {
                guruMeditationAboutView
            }
            
            // Floating Keyboard HUD sheet overlay
            if showKeyboardHUD {
                keyboardHUDView
            }
            
            // WAV offline exporter dialog
            if showExportDialog {
                wavExporterDialog
            }
            
            // Blur Drag and Drop indicator card
            if dragOver {
                dragDropOverlayView
            }
        }
    }
    
}
