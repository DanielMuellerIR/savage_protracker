import SwiftUI
import SavageModPlayerCore
import UniformTypeIdentifiers
import UserNotifications
import MediaPlayer

final class DropURLsContainer: @unchecked Sendable {
    private let lock = NSLock()
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
    @StateObject private var coordinator = ModPlayerCoordinator()
    // Theme, Lautstaerke und loopMode ueber Neustarts hinweg merken (@AppStorage).
    @AppStorage("savage.theme") private var theme: PlayerTheme = .cyber
    @AppStorage("savage.volume") private var volume: Double = 0.6
    // Default Playlist-Wiederholung: Der Player laedt beim Start den ganzen
    // audio-Ordner; am Songende automatisch zum naechsten Titel zu springen ist
    // fuer einen Playlist-Player das erwartete Verhalten (frueher lief der loopMode
    // ins Leere und der Renderblock wiederholte denselben Song endlos).
    @AppStorage("savage.loopMode") private var loopMode: LoopMode = .playlist
    // Shuffle: Titel-Wechsel (weiter/zurueck/Songende) springt zufaellig statt
    // sequenziell durch die Playlist. Ueberlebt App-Neustarts.
    @AppStorage("savage.shuffle") private var shuffleEnabled = false

    // Zuletzt gespielter Titel als stabiler Anzeigename (ohne UUID-Temp-Praefix).
    // Bei ausgeschaltetem Shuffle nimmt der naechste Start diesen Titel wieder
    // auf, statt stur beim ersten der Liste zu beginnen.
    @AppStorage("savage.lastPlayed") private var lastPlayedSongName: String = ""

    // Autoplay-Ordner aus den Einstellungen (leer = nicht gesetzt, dann greifen
    // nur die audio/-Fallbacks in loadLocalAudioFolder). Gesetzt wird der Wert
    // im Einstellungs-Fenster (SettingsView, gleicher Schluessel).
    @AppStorage("savage.autoplayFolder") private var autoplayFolderPath: String = ""

    // Breite der Playlist-Sidebar (ziehbar per Trenn-Handle). Persistiert, damit
    // lange Dateinamen dauerhaft sichtbar bleiben (LIDA-XM-Problem: 260 pt fix war
    // zu schmal, um das Datei-Ende je zu sehen). Geklemmt in sidebarWidthRange.
    @AppStorage("savage.sidebarWidth") private var sidebarWidth: Double = 260

    // Höhe der "ZULETZT GESPIELT"-Sektion unten in der Sidebar (ziehbar, persistiert).
    @AppStorage("savage.recentHeight") private var recentHeight: Double = 96

    // Sidebar tabs
    @State private var selectedSidebarTab: Int = 0 // 0 = Playlist, 1 = Instrumente
    
    // Playlist states
    // `playlist` bleibt die flache Abspielliste in Anzeige-Reihenfolge
    // (Tiefensuche durch den Baum) — Weiter/Zurueck/Shuffle/Loop arbeiten
    // damit unveraendert ueber alle Ordner hinweg.
    @State private var playlist: [URL] = []
    @State private var currentPlaylistIndex: Int = -1
    // Hierarchische Anzeige: Ordner-/Archiv-Baum der aktuellen Playlist,
    // Menge der aufgeklappten Ordner-Pfade und Ordner-Pfad je Datei
    // (fuers Auto-Aufklappen des gerade laufenden Titels).
    @State private var playlistTree: PlaylistScanner.FolderNode? = nil
    @State private var expandedFolders: Set<String> = []
    @State private var folderPathByURL: [URL: [String]] = [:]
    
    // Search & Filter
    @State private var playlistSearchQuery: String = ""
    
    // Recent Songs History
    @State private var recentSongs: [URL] = []
    
    @State private var showFileImporter = false
    @State private var dragOver = false
    @State private var errorMessage: String? = nil
    @State private var compatibilityMessage: String? = nil
    // Wurde beim Start bereits Inhalt über ein Startargument oder „Öffnen mit"
    // (.onOpenURL) geladen? Dann NICHT zusätzlich den Autoplay-Ordner laden —
    // sonst überschrieb/übertönte der Default-Ordner den bewusst geöffneten
    // Titel (Race zwischen onAppear und onOpenURL beim Kaltstart).
    @State private var didLoadInitialContent = false
    
    // Keyboard HUD & About Overlay Modals
    @State private var showKeyboardHUD = false
    @State private var showAboutModal = false
    
    // WAV Export Panel
    @State private var isExporting = false
    @State private var showExportDialog = false
    @State private var exportSecondsLimit: Double = 180.0
    @State private var exportStatusMessage: String? = nil
    
    // Disk rotation state
    // Steuert die Rotation der Drop-Zone-Disc (nur wenn kein Song läuft). Die
    // Play/Pause-Transport-Disk dreht sich in ihrem eigenen View (SpinningDiskButton)
    // mit lokalem State — nicht mehr über ein @State auf MainView (CPU, 2026-07-09).
    @State private var isDiskAnimating = false
    // Fokus-Steuerung des Playlist-Suchfelds (kein Autofokus beim Start).
    @FocusState private var searchFieldFocused: Bool
    // MPRemoteCommandCenter nur einmal verdrahten (onAppear kann mehrfach feuern).
    @State private var mediaCommandsConfigured = false
    
    // Active Preview hover card
    @State private var hoveredInstrumentIndex: Int? = nil

    // Lokaler Tastatur-Monitor (Leertaste/Pfeile/ESC). Token wird in
    // .onDisappear wieder entfernt, damit nichts leakt.
    @State private var keyMonitor: Any? = nil
    
    private var filteredPlaylist: [URL] {
        if playlistSearchQuery.isEmpty {
            return playlist
        } else {
            return playlist.filter { cleanFilename($0).localizedCaseInsensitiveContains(playlistSearchQuery) }
        }
    }

    // Eine sichtbare Zeile der Playlist-Sidebar: entweder ein auf-/zuklappbarer
    // Ordner (bzw. ein wie ein Ordner dargestelltes Archiv) oder ein Titel.
    // Datei-Zeilen nutzen die URL als ID — darauf zielt auch das programmatische
    // Scrollen zum laufenden Titel (scrollTo).
    private struct PlaylistRow: Identifiable {
        enum Kind {
            case folder(name: String, path: String, expanded: Bool)
            case file(URL)
        }
        let id: String
        let depth: Int
        let kind: Kind
    }

    // Sichtbare Zeilen aus Baum + Aufklapp-Zustand berechnen. Bei aktiver Suche
    // stattdessen eine flache Trefferliste — Hierarchie waere dabei nur im Weg.
    private var playlistRows: [PlaylistRow] {
        if !playlistSearchQuery.isEmpty {
            return filteredPlaylist.map { PlaylistRow(id: $0.absoluteString, depth: 0, kind: .file($0)) }
        }
        guard let tree = playlistTree else {
            // Kein Baum vorhanden (sollte nur bei leerer Playlist passieren) —
            // flache Liste als Fallback.
            return playlist.map { PlaylistRow(id: $0.absoluteString, depth: 0, kind: .file($0)) }
        }
        var rows: [PlaylistRow] = []
        func walk(_ node: PlaylistScanner.FolderNode, depth: Int) {
            for sub in node.subfolders {
                let expanded = expandedFolders.contains(sub.path)
                rows.append(PlaylistRow(id: "folder:\(sub.path)", depth: depth,
                                        kind: .folder(name: sub.name, path: sub.path, expanded: expanded)))
                if expanded { walk(sub, depth: depth + 1) }
            }
            for entry in node.files {
                rows.append(PlaylistRow(id: entry.url.absoluteString, depth: depth, kind: .file(entry.url)))
            }
        }
        walk(tree, depth: 0)
        return rows
    }
    
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
                            TrackerGridContainer(transport: coordinator.transport, mod: mod, theme: theme,
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
    
    // Play/Pause-Toggle: pausiert statt zu stoppen — resume() setzt nahtlos
    // fort. Endgueltiges Stoppen macht der separate Stop-Button (stopPlayback).
    private func togglePlayback() {
        guard coordinator.activeMod != nil else { return }
        if coordinator.isPaused {
            coordinator.resume()
        } else if coordinator.isPlaying {
            coordinator.pause()
        } else {
            coordinator.play()
        }
    }

    private func stopPlayback() {
        coordinator.stop()
    }

    // Zufaelligen Playlist-Index liefern, der (wenn moeglich) nicht der
    // aktuelle Titel ist.
    private func randomPlaylistIndex() -> Int {
        guard playlist.count > 1 else { return 0 }
        var idx = currentPlaylistIndex
        while idx == currentPlaylistIndex {
            idx = Int.random(in: 0..<playlist.count)
        }
        return idx
    }

    private func nextTrack() {
        guard !playlist.isEmpty else { return }
        // Transportzustand erhalten: setMod() in loadModFile ruft stop(), daher
        // VOR dem Wechsel merken, ob gerade aktiv (nicht pausiert) gespielt wurde.
        let wasPlaying = coordinator.isPlaying && !coordinator.isPaused
        if shuffleEnabled {
            selectPlaylistSong(at: randomPlaylistIndex(), autoPlay: wasPlaying)
            return
        }
        let nextIndex = currentPlaylistIndex + 1
        if nextIndex < playlist.count {
            selectPlaylistSong(at: nextIndex, autoPlay: wasPlaying)
        } else if loopMode == .playlist {
            selectPlaylistSong(at: 0, autoPlay: wasPlaying)
        }
    }

    private func prevTrack() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = coordinator.isPlaying && !coordinator.isPaused
        if shuffleEnabled {
            selectPlaylistSong(at: randomPlaylistIndex(), autoPlay: wasPlaying)
            return
        }
        let prevIndex = currentPlaylistIndex - 1
        if prevIndex >= 0 {
            selectPlaylistSong(at: prevIndex, autoPlay: wasPlaying)
        } else if loopMode == .playlist {
            selectPlaylistSong(at: playlist.count - 1, autoPlay: wasPlaying)
        }
    }

    // Wird ausgeloest, wenn der Renderblock das Songende erreicht (Wrap auf 0).
    // Wertet den loopMode aus: einmal abspielen -> stoppen; Song wiederholen ->
    // die Engine laeuft bereits in Schleife (nichts tun); Playlist -> naechster Titel.
    private func handleSongEnd() {
        switch loopMode {
        case .none:
            coordinator.stop()
        case .track:
            break // Engine wrappt bereits auf Position 0 und spielt weiter.
        case .playlist:
            nextTrack()
        }
    }
    
    // MARK: - Playlists & File Handling
    
    // autoPlay=true startet die Wiedergabe direkt nach dem Laden — genutzt beim
    // App-Start (audio-Ordner), damit sofort etwas klingt. Echte Drag&Drops
    // rufen mit dem Default false auf und laden nur, ohne loszuspielen.
    private func handleDroppedURLs(_ urls: [URL], autoPlay: Bool = false) {
        self.errorMessage = nil
        self.compatibilityMessage = nil
        // Dateisystem-Traversal + Kopieren laufen im Hintergrund — ein grosser
        // Ordner-Drop blockierte sonst den Main-Thread (Beachball). Nur die
        // @State-Mutation und das Laden der ersten Datei kehren auf den Main-Thread
        // zurueck.
        DispatchQueue.global(qos: .userInitiated).async {
            // Einsammeln (inkl. Ordner-Rekursion und unsichtbarem Entpacken von
            // Zip/7z-Archiven) uebernimmt der testbare Core-Scanner; hier bleibt
            // nur das Temp-Ziel und die UI-Anbindung.
            let entries = PlaylistScanner.collectEntries(from: urls, tempDir: MainView.newDropTempDir())
            let tree = PlaylistScanner.buildTree(entries)
            let flat = PlaylistScanner.flattenedFiles(tree)
            DispatchQueue.main.async {
                guard !flat.isEmpty else {
                    self.errorMessage = "Keine unterstützten Tracker-Dateien gefunden."
                    return
                }
                let sorted = flat.map(\.url)
                self.playlist = sorted
                self.playlistTree = tree
                self.folderPathByURL = Dictionary(uniqueKeysWithValues: flat.map { ($0.url, $0.folderPath) })
                // Standard: alle Ordner zugeklappt; nur der Pfad zum Start-Titel
                // wird unten via selectPlaylistSong/expandAncestors geoeffnet.
                self.expandedFolders = []
                self.selectedSidebarTab = 0 // Playlist fokussieren

                // Start-Titel bestimmen: ein expliziter "--autoplay <filter>"
                // gewinnt; sonst bei ausgeschaltetem Shuffle der zuletzt gespielte
                // Titel (falls noch in der Liste); sonst bei Shuffle ein Zufalls-
                // Titel, sonst der erste der (sortierten) Liste.
                let filterIndex = Self.autoplayFilterIndex(in: sorted)
                let lastPlayedIndex = self.shuffleEnabled
                    ? nil
                    : sorted.firstIndex(where: { self.cleanFilename($0) == self.lastPlayedSongName })
                let startIndex = filterIndex
                    ?? lastPlayedIndex
                    ?? (self.shuffleEnabled ? Int.random(in: 0..<sorted.count) : 0)

                // Sofort losspielen, wenn der Aufrufer es will (App-Start) oder die
                // Headless-/Agent-Steuerung "--autoplay [filter]" gesetzt ist —
                // Letzteres auch fuer Screenshots und Smoke-Tests ohne Klicks.
                if autoPlay || CommandLine.arguments.contains("--autoplay") {
                    self.selectPlaylistSong(at: startIndex, autoPlay: true)
                } else {
                    self.currentPlaylistIndex = startIndex
                    self.loadModFile(from: sorted[startIndex])
                    self.expandAncestors(of: sorted[startIndex])
                }
            }
        }
    }

    // Liefert den Playlist-Index des ersten Titels, dessen Name den optionalen
    // "--autoplay <filter>"-Parameter enthaelt (nil ohne Filter/Treffer).
    nonisolated private static func autoplayFilterIndex(in urls: [URL]) -> Int? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--autoplay") else { return nil }
        let next = flagIndex + 1
        if next < args.count, !args[next].hasPrefix("--") {
            let filter = args[next].lowercased()
            return urls.firstIndex(where: { $0.lastPathComponent.lowercased().contains(filter) })
        }
        return nil
    }

    // Pro Drop ein eigenes Temp-Unterverzeichnis statt das gemeinsame zu loeschen:
    // sonst entwertet ein neuer Drop die Temp-URLs frueherer Baetche. Das
    // eigentliche Einsammeln/Kopieren/Entpacken macht PlaylistScanner (Core).
    nonisolated private static func newDropTempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModPlayerTemp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // Loescht die Temp-Kopien frueherer App-Laeufe (ModPlayerTemp/). Wird einmalig
    // beim App-Start gerufen (AppMain.init): die pro-Drop angelegten UUID-
    // Verzeichnisse bleiben innerhalb einer Sitzung bestehen (die Playlist
    // referenziert sie noch), wuerden sich sonst aber ueber Laeufe hinweg
    // unbegrenzt ansammeln.
    nonisolated static func cleanStaleTempRoot() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModPlayerTemp", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    // Alle Ordner-Ebenen ueber dem Titel aufklappen, damit der laufende
    // Eintrag in der Baum-Ansicht sichtbar ist. Manuell geoeffnete Ordner
    // bleiben unangetastet (nur einfuegen, nie zuklappen).
    private func expandAncestors(of url: URL) {
        guard let components = folderPathByURL[url], !components.isEmpty else { return }
        var path = ""
        for component in components {
            path = path.isEmpty ? component : "\(path)/\(component)"
            expandedFolders.insert(path)
        }
    }

    private func selectPlaylistSong(at index: Int, autoPlay: Bool = true) {
        guard index >= 0 && index < playlist.count else { return }
        self.currentPlaylistIndex = index
        let songUrl = playlist[index]
        expandAncestors(of: songUrl)
        if loadModFile(from: songUrl) {
            // Nur abspielen, wenn gewuenscht — sonst startet z.B. Weiterblaettern
            // im pausierten Zustand ungewollt die Wiedergabe.
            if autoPlay { coordinator.play() }
        }
        // "Zuletzt gespielt" wird zentral in loadModFile gepflegt (alle Ladepfade).
    }
    
    @discardableResult
    private func loadModFile(from url: URL) -> Bool {
        self.errorMessage = nil
        self.compatibilityMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        
        do {
            let fileData = try Data(contentsOf: url)
            // ModuleLoader erkennt das Format am Inhalt (MOD, S3M, XM und IT).
            let mod = try ModuleLoader.parse(data: fileData)
            // Dateiname (ohne UUID-Praefix der Temp-Kopie und ohne Endung) als
            // Fallback-Titel, falls das Modul kein Titelfeld gesetzt hat.
            let fallbackName = (cleanFilename(url) as NSString).deletingPathExtension
            coordinator.setMod(mod, fallbackName: fallbackName)
            if !mod.compatibilityWarnings.isEmpty {
                self.compatibilityMessage = mod.compatibilityWarnings.joined(separator: "\n")
            }
            // Stabilen Namen fuer "zuletzt gespielt" merken (ueberlebt Neustart).
            self.lastPlayedSongName = cleanFilename(url)
            // "ZULETZT GESPIELT"-Liste hier zentral pflegen, damit JEDER Ladepfad
            // (Playlist-Klick, Weiter/Zurueck, Autostart, Drop, Recent-Klick) sie
            // aktualisiert — vorher nur selectPlaylistSong, weshalb sie oft
            // veraltet stehen blieb. Duplikat zuerst entfernen -> rueckt nach oben.
            recentSongs.removeAll { $0 == url }
            recentSongs.insert(url, at: 0)
            if recentSongs.count > 10 { recentSongs.removeLast() }
            return true
        } catch {
            self.errorMessage = "Parser-Fehler bei '\(cleanFilename(url))': \(error.localizedDescription)"
            print("Parser-Fehler: \(error)")
            return false
        }
    }
    
    private func cleanFilename(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.count > 36 {
            let index = name.index(name.startIndex, offsetBy: 36)
            if name[index] == "_" {
                return String(name[name.index(after: index)...])
            }
        }
        return name
    }
    
    nonisolated private static func isModFile(_ url: URL) -> Bool {
        PlaylistScanner.isModFile(url)
    }

    private func loadLocalAudioFolder() {
        let fm = FileManager.default
        var candidateDirs: [URL] = []
        // Primaere Quelle: der in den Einstellungen (Cmd+,) konfigurierte
        // Autoplay-Ordner. Nicht gesetzt = nur die Fallbacks unten.
        if !autoplayFolderPath.isEmpty {
            candidateDirs.append(URL(fileURLWithPath: (autoplayFolderPath as NSString).expandingTildeInPath, isDirectory: true))
        }
        // Fallbacks wie bisher: audio/-Ordner neben Arbeitsverzeichnis bzw. App.
        candidateDirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("audio"))
        // Bundle.main.bundlePath ist immer ein (non-optional) String.
        let appDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        candidateDirs.append(appDir.appendingPathComponent("audio"))
        for dir in candidateDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Nur nehmen, wenn (rekursiv) wirklich Mods oder Archive drin sind —
            // sonst den naechsten Kandidaten probieren. Den eigentlichen Scan
            // (inkl. Hierarchie + Archive) macht dann handleDroppedURLs.
            guard PlaylistScanner.directoryContainsPlayableContent(dir) else { continue }
            handleDroppedURLs([dir], autoPlay: true)
            return
        }
    }
    
    private func triggerDemoPlay() {
        let demoMod = ModParser.generateDemoMod()
        coordinator.setMod(demoMod)
        coordinator.play()
    }

    // Erstes Datei-/Ordner-Argument von der Kommandozeile (`SavageModPlayer <pfad>`).
    // Ignoriert Flags und die Prozess-Serial-Args (`-psn_…`, `-NSDocument…`), die
    // macOS beim Bundle-Start injiziert; nimmt den ersten existierenden Pfad mit
    // unterstützter Endung oder ein Verzeichnis. Ermöglicht headless Auto-Play
    // (Tests/CPU-Messung) ohne GUI-Bedienung.
    private static func launchFileArgument() -> URL? {
        for arg in CommandLine.arguments.dropFirst() {
            guard !arg.hasPrefix("-") else { continue }
            let url = URL(fileURLWithPath: arg)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue || ModuleLoader.supportedExtensions.contains(url.pathExtension.lowercased()) {
                return url
            }
        }
        return nil
    }

    // MARK: - Keyboard handling (Leertaste/Pfeile/ESC aus dem HUD)
    private func installKeyMonitor() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Nicht in Textfelder (Suche/Export) eingreifen. Der Feld-Editor eines
            // fokussierten SwiftUI-TextField IST eine NSText-Subklasse (NSTextView),
            // daher greift dieser Guard tatsaechlich — kein toter Code.
            // codereview-ok: NSText-Guard ist funktional, kein toter Zweig (2026-07-02)
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            switch event.keyCode {
            case 49: // Leertaste
                togglePlayback()
                return nil
            case 124: // Pfeil rechts
                nextTrack()
                return nil
            case 123: // Pfeil links
                prevTrack()
                return nil
            case 53: // ESC
                if showAboutModal || showKeyboardHUD || showExportDialog {
                    showAboutModal = false
                    showKeyboardHUD = false
                    showExportDialog = false
                    return nil
                }
                return event
            default:
                return event
            }
        }
        #endif
    }

    private func removeKeyMonitor() {
        #if os(macOS)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        #endif
    }

    // MARK: - Media-Tasten (F7/F8/F9 bzw. Touch Bar / AirPods)
    // Registriert die App im System als "Now Playing"-App: Play/Pause- und
    // Titel-Sprung-Kommandos der Media-Tasten landen dann hier. Die Handler
    // posten dieselben Notifications wie die Menuepunkte — die onReceive-
    // Blöcke oben verarbeiten beide Quellen einheitlich auf dem Main-Thread.
    private func setupMediaRemoteCommands() {
        guard !mediaCommandsConfigured else { return }
        mediaCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuPlayStop"), object: nil)
            return .success
        }
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("mediaPlay"), object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("mediaPause"), object: nil)
            return .success
        }
        center.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuStop"), object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuNextTrack"), object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuPrevTrack"), object: nil)
            return .success
        }
    }

    // Haelt die "Now Playing"-Infos des Systems aktuell (Titel, Dauer,
    // Position, laeuft/pausiert) — Voraussetzung dafuer, dass die Media-Tasten
    // an diese App geroutet werden.
    private func updateNowPlayingInfo() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard coordinator.activeMod != nil else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        let activelyPlaying = coordinator.isPlaying && !coordinator.isPaused
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: coordinator.trackName,
            MPMediaItemPropertyPlaybackDuration: coordinator.visualizerState.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: coordinator.visualizerState.elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: activelyPlaying ? 1.0 : 0.0
        ]
        infoCenter.playbackState = coordinator.isPlaying
            ? (coordinator.isPaused ? .paused : .playing)
            : .stopped
    }

    // MARK: - Notification helper
    private func setupNotifications() {
        #if os(macOS)
        // SwiftPM startet die App als nacktes Executable ohne .app-Bundle.
        // UserNotifications crasht in diesem Fall beim Zugriff auf
        // current(), deshalb werden Notifications dort übersprungen.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func fireNotification(for track: String) {
        #if os(macOS)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = "Amiga ModPlayer spielt:"
        content.body = track
        let request = UNNotificationRequest(identifier: "modplayer.track", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    // MARK: - WAV Export helper
    private func runWavExport() {
        guard let mod = coordinator.activeMod else { return }
        let sep = coordinator.stereoSeparation
        let interp = coordinator.useInterpolation
        let pal = coordinator.palClock
        let limit = exportSecondsLimit
        let playerCoordinator = coordinator
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.wav]
        savePanel.nameFieldStringValue = coordinator.trackName.replacingOccurrences(of: " ", with: "_") + ".wav"
        savePanel.title = "Song als WAV exportieren..."
        
        savePanel.begin { response in
            if response == .OK, let destURL = savePanel.url {
                self.isExporting = true
                self.exportStatusMessage = "Rendert offline..."
                
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try playerCoordinator.exportActiveModToWav(
                            mod: mod,
                            stereoSeparation: sep,
                            useInterpolation: interp,
                            palClock: pal,
                            destinationURL: destURL,
                            durationSeconds: limit
                        )
                        DispatchQueue.main.async {
                            self.isExporting = false
                            self.exportStatusMessage = "Erfolgreich gesichert!"
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.isExporting = false
                            self.exportStatusMessage = "Export-Fehler: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
    
    private func runInstrumentSampleExport(index: Int) {
        guard let mod = coordinator.activeMod, index < mod.instruments.count, let inst = mod.instruments[index] else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.wav]
        let name = inst.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "sample_\(index)" : inst.name
        savePanel.nameFieldStringValue = name.replacingOccurrences(of: " ", with: "_") + ".wav"
        savePanel.title = "Instrumenten-Sample als WAV sichern..."
        
        savePanel.begin { response in
            if response == .OK, let destURL = savePanel.url {
                do {
                    try coordinator.exportInstrumentToWav(index: index, destinationURL: destURL)
                    self.errorMessage = "Sample \(index) exportiert!"
                } catch {
                    self.errorMessage = "Fehler: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - UI Components
    
    // Eine Zeile der Playlist: Ordner-Zeile (klick = auf-/zuklappen) oder
    // Titel-Zeile (klick = abspielen). Die Einrueckung folgt der Baumtiefe.
    @ViewBuilder
    private func playlistRowView(_ row: PlaylistRow) -> some View {
        let indent = CGFloat(row.depth) * 14

        switch row.kind {
        case .folder(let name, let path, let expanded):
            Button(action: {
                if expanded { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.spaceTextSecondary)
                        .frame(width: 10)
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundColor(Color.accent(theme))
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12 + indent)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundColor(theme == .workbench ? .lightTextPrimary : .spaceTextSecondary)
            }
            .buttonStyle(PremiumHoverButtonStyle(theme: theme))

        case .file(let fileURL):
            let playlistIndex = playlist.firstIndex(of: fileURL) ?? -1
            let isPlayingSong = playlistIndex == currentPlaylistIndex

            Button(action: { selectPlaylistSong(at: playlistIndex) }) {
                HStack(spacing: 8) {
                    Image(systemName: isPlayingSong ? "speaker.wave.2.fill" : "music.note")
                        .font(.system(size: 11))
                        .foregroundColor(isPlayingSong ? (Color.accent(theme)) : .spaceTextSecondary)

                    Text(cleanFilename(fileURL))
                        .font(.system(size: 11, weight: isPlayingSong ? .bold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12 + indent)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: theme == .workbench ? 0 : 6)
                        .fill(
                            isPlayingSong
                            ? (theme == .workbench ? Color.lightAccent.opacity(0.2) : Color.spaceAccent.opacity(0.15))
                            : Color.clear
                        )
                )
                .foregroundColor(isPlayingSong ? (theme == .workbench ? .lightAccent : .white) : (theme == .workbench ? .lightTextPrimary : .spaceTextSecondary))
            }
            .buttonStyle(PremiumHoverButtonStyle(theme: theme))
        }
    }

    private var playlistSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.spaceTextSecondary)
                TextField("Titel filtern...", text: $playlistSearchQuery)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 11))
                    // Kein Autofokus: macOS macht das erste Textfeld sonst zum
                    // First Responder und der Cursor blinkt dauerhaft in der
                    // Sidebar. Fokus bekommt das Feld erst per Klick.
                    .focused($searchFieldFocused)
                if !playlistSearchQuery.isEmpty {
                    Button(action: { playlistSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(6)
            .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground)
            .cornerRadius(theme == .workbench ? 0 : 6)
            .padding([.horizontal, .top], 8)
            
            if playlist.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 36))
                        .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.3) : .spaceAccent.opacity(0.4))
                    
                    Text("Playlist leer")
                        .font(.system(size: 13, weight: .bold))
                    
                    Text("Dateien oder Ordner per Drag & Drop reinziehen.")
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.spaceTextSecondary)
                        .padding(.horizontal, 12)
                    
                    Button("Demo abspielen") {
                        triggerDemoPlay()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accent(theme))
                    .foregroundColor(.white)
                    .cornerRadius(theme == .workbench ? 0 : 6)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack {
                    Text("TITEL (\(filteredPlaylist.count))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme == .workbench ? .lightAccent : .spaceAccentGlow)
                    Spacer()
                    Button("Leeren") {
                        coordinator.stop()
                        playlist.removeAll()
                        playlistTree = nil
                        expandedFolders.removeAll()
                        folderPathByURL.removeAll()
                        currentPlaylistIndex = -1
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme == .workbench ? .lightAccent : .spaceTextSecondary)
                    .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(theme == .workbench ? Color.lightSurface.opacity(0.5) : Color.spaceBackground.opacity(0.5))
                
                // ScrollViewReader: erlaubt programmatisches Scrollen zum aktuell
                // laufenden Titel. Noetig, weil ein Titelwechsel auch ohne Klick in
                // die Liste passieren kann (Start mit Shuffle, "Naechster/Voriger
                // Titel", Zufallssprung) — dann soll der spielende Eintrag sichtbar
                // sein, statt irgendwo ausserhalb des sichtbaren Bereichs zu liegen.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(playlistRows) { row in
                                playlistRowView(row)
                            }
                        }
                    }
                    // Bei jedem Wechsel des laufenden Titels zu diesem Eintrag scrollen
                    // (mittig). Die ForEach-Eintraege sind ueber die Datei-URL (id:
                    // \.self) adressierbar; scrollTo trifft sie damit direkt. Liegt der
                    // Titel gerade nicht im gefilterten Suchergebnis, passiert nichts.
                    .onChange(of: currentPlaylistIndex) { idx in
                        guard idx >= 0, idx < playlist.count else { return }
                        withAnimation {
                            // Zeilen-ID der Datei-Zeile ist die URL als String
                            // (siehe PlaylistRow); der Ordner-Pfad zum Titel ist
                            // durch expandAncestors bereits aufgeklappt.
                            proxy.scrollTo(playlist[idx].absoluteString, anchor: .center)
                        }
                    }
                }
                
                if !recentSongs.isEmpty {
                    // Ziehbarer Trenner: nach oben ziehen vergrößert die "Zuletzt
                    // gespielt"-Sektion (und schrumpft die Playlist darüber).
                    ResizableDivider(width: $recentHeight, range: 48...360,
                                     theme: theme, axis: .horizontal, inverted: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ZULETZT GESPIELT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.spaceTextSecondary)
                            .padding(.horizontal, 8)

                        // Scrollbar, zeigt alle Einträge (früher fix nur 4). Höhe
                        // per Handle oben einstellbar.
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(recentSongs, id: \.self) { url in
                                    Button(action: {
                                        // Veraltete Temp-URL (Datei weg)? Eintrag verwerfen statt
                                        // eine tote URL in die Playlist zu haengen.
                                        guard FileManager.default.fileExists(atPath: url.path) else {
                                            recentSongs.removeAll { $0 == url }
                                            return
                                        }
                                        if let idx = playlist.firstIndex(of: url) {
                                            selectPlaylistSong(at: idx)
                                        } else {
                                            // Titel ist nicht mehr Teil der Playlist (z.B. nach
                                            // "Leeren") — direkt laden statt ihn in die
                                            // hierarchische Liste zu zwaengen.
                                            if loadModFile(from: url) {
                                                currentPlaylistIndex = -1
                                                coordinator.play()
                                            }
                                        }
                                    }) {
                                        Text(cleanFilename(url))
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .foregroundColor(.spaceTextSecondary.opacity(0.8))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .frame(height: CGFloat(recentHeight))
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
    
    private var instrumentsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let mod = coordinator.activeMod {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(1..<32) { i in
                            if i < mod.instruments.count, let inst = mod.instruments[i] {
                                Button(action: { coordinator.previewInstrument(index: i) }) {
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", i))
                                            .foregroundColor(theme == .workbench ? .lightAccent : .codeInstrument)
                                            .font(.system(size: 11, weight: .bold))
                                            .frame(width: 18)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(inst.name.isEmpty ? "Instrument \(i)" : inst.name)
                                                    .font(.system(size: 11, weight: .bold))
                                                    .lineLimit(1)
                                                Spacer()
                                                
                                                if (inst.primarySample?.pcm.count ?? 0) > 0 {
                                                    // Save individual instrument to WAV
                                                    Button(action: { runInstrumentSampleExport(index: i) }) {
                                                        Image(systemName: "square.and.arrow.down")
                                                            .font(.system(size: 9))
                                                            .foregroundColor(.spaceTextSecondary)
                                                    }
                                                    .buttonStyle(PlainButtonStyle())
                                                }
                                            }
                                            
                                            // Visual progress bar of length
                                            GeometryReader { geo in
                                                let lengthRatio = min(1.0, Double(inst.primarySample?.pcm.count ?? 0) / 65536.0)
                                                ZStack(alignment: .leading) {
                                                    Rectangle()
                                                        .fill(theme == .workbench ? Color.lightTextPrimary.opacity(0.1) : Color.white.opacity(0.03))
                                                    Rectangle()
                                                        .fill(Color.accent(theme))
                                                        .frame(width: geo.size.width * CGFloat(lengthRatio))
                                                }
                                            }
                                            .frame(height: 3)
                                            .cornerRadius(1)
                                            
                                            Text(String(format: "Len: %d B | Fine: %d | Vol: %d", inst.primarySample?.pcm.count ?? 0, inst.primarySample?.finetune ?? 0, inst.primarySample?.volume ?? 0))
                                                .font(.system(size: 8.5))
                                                .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.6) : .spaceTextSecondary)
                                        }
                                    }
                                    // Padding + contentShape INS Label ziehen, damit
                                    // die GANZE Zeile (auch der Leerraum neben dem Namen)
                                    // die Vorschau ausloest — nicht nur der Text. Der
                                    // verschachtelte DL-Button faengt seine Klicks selbst
                                    // ab und bleibt ausgenommen.
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                                // Light-Mode: nur duenner Rahmen ohne Fuellung,
                                // Hover hebt die Zeile weiss hervor. Der dunkle
                                // Fuellton passte nicht ins helle Theme.
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme == .workbench
                                              ? (hoveredInstrumentIndex == i ? Color.white : Color.clear)
                                              : (hoveredInstrumentIndex == i ? Color.spaceAccent.opacity(0.08) : Color.spaceBackground.opacity(0.3)))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(theme == .workbench ? Color.lightTextSecondary.opacity(0.35) : Color.clear, lineWidth: 1)
                                )
                                .onHover { hovering in
                                    hoveredInstrumentIndex = hovering ? i : nil
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            } else {
                Spacer()
                Text("Kein Song geladen")
                    .font(.system(size: 12))
                    .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.4) : .spaceTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
    }
    
    // Kurzes Format-Kuerzel fuer das Badge neben dem Songtitel.
    private var formatBadgeText: String {
        switch coordinator.activeMod?.format {
        case .s3m: return "S3M"
        case .xm: return "FASTTRACKER II"
        case .it: return "IMPULSE TRACKER"
        case .multichannel: return "MULTICHANNEL"
        case .soundtracker: return "SOUNDTRACKER"
        default: return "PROTRACKER"
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    let titleFont: Font = theme == .workbench
                        ? .system(size: 20, weight: .bold) : .title2
                    let titleColor: Color = theme == .workbench ? .lightAccent : .white

                    // Format-Badge LINKS vor dem Titel (feste Groesse). Bewusst vor
                    // dem Titel, damit der (bei Ueberlaenge scrollende) Titel den
                    // restlichen Platz fuellen kann, ohne das Badge zu verdraengen —
                    // und ohne bei kurzen Titeln eine grosse Luecke zum Badge zu lassen.
                    if theme == .cyber {
                        Text(formatBadgeText)
                            .font(.system(size: 8, weight: .black))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.spaceAccent)
                            .foregroundColor(.black)
                            .cornerRadius(3)
                    }

                    // Titel als Laufschrift: scrollt, wenn er breiter als der Platz
                    // ist, sonst steht er einfach links.
                    MarqueeText(text: coordinator.trackName, font: titleFont, color: titleColor)
                }

                HStack(spacing: 16) {
                    if let mod = coordinator.activeMod {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                            Text(String(format: "CH: %d", mod.usedChannelCount))
                                .fixedSize()
                        }
                        .fixedSize()
                        .help("Genutzte Kanäle: zählt die Pattern-Kanäle, die im Song tatsächlich Noten, Instrumente, Lautstärke- oder Effektbefehle enthalten. Reservierte, komplett leere Kanäle werden nicht mitgezählt.")
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "metronome")
                        // fixedSize: verhindert, dass "BPM: 125" bei knappem Platz
                        // (langer Songtitel darueber) auf zwei Zeilen umbricht.
                        Text(String(format: "BPM: %d", coordinator.bpm))
                            .fixedSize()

                        // Steppers
                        Button(action: {
                            if coordinator.bpm > 32 { coordinator.bpm -= 1 }
                        }) {
                            Image(systemName: "minus.square")
                        }.buttonStyle(PlainButtonStyle())

                        Button(action: {
                            if coordinator.bpm < 300 { coordinator.bpm += 1 }
                        }) {
                            Image(systemName: "plus.square")
                        }.buttonStyle(PlainButtonStyle())
                    }
                    .fixedSize()
                    .help("BPM (Beats per Minute): Wiedergabe-Tempo. Amiga-Standard ist 125. Mit −/+ veraenderbar; ein Song kann sein Tempo per Effekt auch selbst umstellen. Bei Songwechsel wird der Header-Wert des neuen Moduls gesetzt.")
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                        Text(String(format: "SPD: %d", coordinator.speed))
                            .fixedSize()

                        Button(action: {
                            if coordinator.speed > 1 { coordinator.speed -= 1 }
                        }) {
                            Image(systemName: "minus.square")
                        }.buttonStyle(PlainButtonStyle())

                        Button(action: {
                            if coordinator.speed < 31 { coordinator.speed += 1 }
                        }) {
                            Image(systemName: "plus.square")
                        }.buttonStyle(PlainButtonStyle())
                    }
                    .fixedSize()
                    .help("Speed: Ticks pro Pattern-Zeile (Amiga-Standard 6). Kleiner = die Zeilen laufen schneller durch, groesser = langsamer. Zusammen mit BPM bestimmt das die effektive Geschwindigkeit.")
                    if let mod = coordinator.activeMod {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note.list")
                            PatPositionText(transport: coordinator.transport, length: mod.length)
                        }
                        .fixedSize()
                        .help("Pattern-Position: aktuelles Pattern und Gesamtzahl in der Abspielliste des Songs. Ein Pattern ist ein Notenblock (meist 64 Zeilen); der Song spielt sie in dieser Reihenfolge ab.")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.8) : .spaceTextSecondary)
            }
            // Der Titelblock ist das EINE flexible Element in der Kopfzeile und
            // fuellt den Platz bis zu den rechten Bedienelementen (ersetzt den
            // frueheren Spacer). So bekommt ein langer Songtitel viel mehr Breite,
            // bevor er gekuerzt wird. WICHTIG: kein layoutPriority hier — das wuerde
            // den fixen rechten Buttons die Breite entziehen (0 pt -> vertikal
            // umgebrochener Text). Als flexibles Element mit Prioritaet 0 nimmt der
            // Block nur den Rest, den die intrinsisch breiten Buttons uebriglassen.
            .frame(maxWidth: .infinity, alignment: .leading)

            // Theme Selector
            HStack(spacing: 4) {
                ForEach(PlayerTheme.allCases) { t in
                    Button(action: { theme = t }) {
                        Text(t == .workbench ? "LIGHT" : "DARK")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                theme == t
                                ? (Color.accent(t))
                                : (theme == .workbench ? Color.lightSurfaceAlt : Color.spaceSurface.opacity(0.5))
                            )
                            .foregroundColor(theme == t ? Color.white : (theme == .workbench ? Color.lightTextPrimary : Color.spaceTextSecondary))
                            .cornerRadius(theme == .workbench ? 0 : 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(3)
            .background(theme == .workbench ? Color.lightSurface : Color.spaceBackground.opacity(0.6))
            .cornerRadius(theme == .workbench ? 0 : 6)
            
            // File Open Button
            Button(action: { showFileImporter = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                    Text("ÖFFNEN")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accent(theme))
                .foregroundColor(.white)
                .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(PremiumHoverButtonStyle(theme: theme))
            .cornerRadius(theme == .workbench ? 0 : 6)
        }
    }
    
    private var vuVisualizersView: some View {
        VStack(spacing: 8) {
            // Obere Zeile: adaptive Kanal-Oszilloskope über die VOLLE Breite.
            // (Play/Pause liegt jetzt als Disk unten im Transport-Balken.)
            // Die verfuegbare Breite wird gleichmaessig auf alle Kanaele verteilt
            // — wenige Kanaele => breite Oszis, viele => schmaler, bis zu einer
            // Mindestbreite; darunter (sehr viele Kanaele) wird dezent horizontal
            // gescrollt.
            // Kanal-Oszilloskope + VU: eigener 30-Hz-Beobachter (ChannelStripsView),
            // damit die Scope-Updates nicht die ganze MainView.body neu rendern.
            ChannelStripsView(
                visualizer: coordinator.visualizerState,
                coordinator: coordinator,
                channelCount: coordinator.channelCount,
                theme: theme
            )

            // Untere Zeile: kompakte Optionsleiste (aus der oberen Zeile
            // ausgelagert, damit die Oszis dort die volle Breite bekommen).
            HStack(spacing: 16) {
                Toggle("LED FILTER", isOn: $coordinator.ledFilterActive)
                    .toggleStyle(CheckboxToggleStyle(theme: theme))
                    .help("Amiga-LED-Filter: zuschaltbarer Tiefpass bei ~3,2 kHz, der die Höhen kappt — der dumpfere Originalklang, wie wenn am echten Amiga die Power-LED leuchtete.")

                Toggle("HI-FI INT.", isOn: $coordinator.useInterpolation)
                    .toggleStyle(CheckboxToggleStyle(theme: theme))
                    .help("Hi-Fi-Interpolation: glättet die Samples beim Resampling (weicherer Klang). Ausgeschaltet klingt es wie die Original-Hardware — roher 8-Bit-Sound mit hörbarem Aliasing.")

                HStack(spacing: 6) {
                    Text("LOOP:")
                        .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)

                    Picker("", selection: $loopMode) {
                        ForEach(LoopMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(DefaultPickerStyle())
                    .labelsHidden()
                    .fixedSize()
                    // Control-Optik ans App-Theme koppeln (sonst im Dark-Theme
                    // auf hellem System kaum lesbar).
                    .colorScheme(theme == .workbench ? .light : .dark)
                    .help("Was nach dem Songende passiert: Playlist fortsetzen, den Song wiederholen oder stoppen.")
                }

                Spacer()
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(theme == .workbench ? Color.lightSurface.opacity(0.3) : Color.spaceSurface.opacity(0.5))
        .cornerRadius(theme == .workbench ? 0 : 8)
    }
    private var dropZonePrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 20) {
                // Glowing Icon
                ZStack {
                    if theme == .cyber {
                        Circle()
                            .fill(Color.spaceAccent.opacity(0.15))
                            .frame(width: 100, height: 100)
                            .blur(radius: 10)
                    }
                    
                    Image(systemName: dragOver ? "arrow.down.doc.fill" : "opticaldisc.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color.accent(theme))
                        .rotationEffect(.degrees(dragOver ? 180 : (isDiskAnimating ? 360 : 0)))
                        .scaleEffect(dragOver ? 1.2 : 1.0)
                        .shadow(color: theme == .workbench ? Color.clear : Color.spaceAccent.opacity(0.5), radius: 8)
                }
                
                VStack(spacing: 8) {
                    Text("PROTRACKER MOD PLAYER")
                        .font(theme == .workbench ? .system(size: 16, weight: .bold) : .system(size: 18, weight: .bold, design: .default))
                        .foregroundColor(theme == .workbench ? .lightAccent : .white)
                        .tracking(theme == .cyber ? 2.0 : 0)
                    
                    Text("Ziehe .mod Dateien oder Ordner direkt in dieses Fenster")
                        .font(theme == .workbench ? .system(size: 12) : .system(size: 13, weight: .medium))
                        .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.8) : .spaceTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                
                HStack(spacing: 12) {
                    Button(action: { showFileImporter = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.rectangle.on.folder")
                            Text("DATEIEN AUSWÄHLEN")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.accent(theme))
                        .foregroundColor(.white)
                        .cornerRadius(theme == .workbench ? 0 : 8)
                    }
                    .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                    
                    Button(action: { triggerDemoPlay() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle")
                            Text("DEMO ABSPIELEN")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(theme == .workbench ? 0 : 8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.vertical, 40)
            .padding(.horizontal, 30)
            .background(
                Group {
                    if theme == .cyber {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.spaceSurface.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        LinearGradient(
                                            colors: dragOver ? [.spaceAccent, .spaceAccentGlow] : [.white.opacity(0.1), .white.opacity(0.02)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: dragOver ? 2 : 1
                                    )
                            )
                    } else {
                        Rectangle()
                            .fill(Color.lightSurface.opacity(0.2))
                            .border(dragOver ? Color.lightAccent : Color.lightTextPrimary, width: 2)
                    }
                }
            )
            .shadow(color: theme == .workbench ? Color.clear : Color.black.opacity(0.3), radius: 20)
            
            if let errorMsg = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMsg)
                        .foregroundColor(.red)
                }
                .font(.system(size: 11))
                .padding(.top, 4)
            }
            Spacer()
        }
        .background(theme == .workbench ? Color.lightSurfaceAlt : Color.clear)
    }
    
    // Master Oscilloscope visualizer showing master L/R mix output
    private var masterOscilloscopeView: some View {
        HStack(spacing: 16) {
            Text("MASTER OSCILLOSCOPE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)
                .frame(width: 140, alignment: .leading)
            
            // Master-Oszilloskop: eigener 30-Hz-Beobachter (siehe ChannelStripsView).
            MasterScopeCanvas(visualizer: coordinator.visualizerState, theme: theme)
            
            // Stereo Separation bleed adjustment slider
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)

                Slider(value: $coordinator.stereoSeparation, in: 0.0...1.0)
                    .accentColor(Color.accent(theme))
                    .frame(width: 80)
                    // Tooltip auch direkt am Slider: ein Slider verschluckt die
                    // Hover-Events, sodass das .help() der umgebenden HStack beim
                    // Zeigen auf den Slider-Track allein nicht ausgeloest wird.
                    .help("Stereo-Separation: 100 % = hartes Amiga-Panning (Kanäle ganz links/rechts), 0 % = Mono. Dazwischen wird Übersprechen beigemischt, das Kopfhörer-Ermüdung vermeidet. Am deutlichsten mit Kopfhörern hörbar; über Laptop-Lautsprecher kaum.")

                Text(String(format: "%d%%", Int(coordinator.stereoSeparation * 100)))
                    .font(.system(size: 9))
                    .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .help("Stereo-Separation: 100 % = hartes Amiga-Panning (Kanäle ganz links/rechts), 0 % = Mono. Dazwischen wird Übersprechen beigemischt, das Kopfhörer-Ermüdung vermeidet. Am deutlichsten mit Kopfhörern hörbar; über Laptop-Lautsprecher kaum.")

            // PAL/NTSC verändert nur die Paula-basierten MOD-Formate. S3M, XM
            // und IT verwenden eigene, feste Frequenzmodelle; dort blenden wir
            // die wirkungslose Steuerung aus statt einen scheinbaren Schalter zu
            // zeigen.
            if usesAmigaClock {
                palClockSelector
            }
        }
    }

    private var usesAmigaClock: Bool {
        switch coordinator.activeMod?.format {
        case .protracker, .soundtracker, .multichannel:
            return true
        default:
            return false
        }
    }

    private var palClockSelector: some View {
        HStack(spacing: 4) {
            Button("PAL (3.546MHz)") {
                coordinator.palClock = true
            }
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(coordinator.palClock ? Color.accent(theme) : Color.clear)
            .foregroundColor(coordinator.palClock ? .white : inactiveControlColor)
            .cornerRadius(4)
            .buttonStyle(PlainButtonStyle())
            .help("PAL-Paula-Takt (3,546 MHz) wie bei europäischen Amigas — die Referenz-Tonhöhe und -Geschwindigkeit der meisten Module.")

            Button("NTSC (3.580MHz)") {
                coordinator.palClock = false
            }
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(!coordinator.palClock ? Color.accent(theme) : Color.clear)
            .foregroundColor(!coordinator.palClock ? .white : inactiveControlColor)
            .cornerRadius(4)
            .buttonStyle(PlainButtonStyle())
            .help("NTSC-Paula-Takt (3,580 MHz) wie bei US-Amigas — Module klingen minimal höher und laufen etwas schneller als mit PAL.")
        }
        .padding(2)
        .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceBackground.opacity(0.4))
        .cornerRadius(6)
    }

    private var inactiveControlColor: Color {
        theme == .workbench ? .lightTextSecondary : .spaceTextSecondary
    }
    
    // Einheitliche Optik der kleinen Transport-Buttons (Stop, Positions- und
    // Titel-Spruenge) — rund im Dark-, eckig im Light-Theme.
    private func transportButtonLabel(systemName: String) -> some View {
        ZStack {
            if theme == .cyber {
                Circle()
                    .fill(Color.spaceSurface)
                    .overlay(Circle().stroke(Color.spaceAccent.opacity(0.3), lineWidth: 1))
            } else {
                // Volle Akzentfarbe wie der Play-Button — das abgeschwaechte
                // Orange sah im Light-Mode wie "deaktiviert" aus.
                Rectangle()
                    .fill(Color.lightAccent)
            }
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundColor(.white)
        }
        .frame(width: 30, height: 30)
    }

    private var controlPanelView: some View {
        HStack(spacing: 24) {
            // Left block: Play controls
            HStack(spacing: 8) {
                // Play/Pause = rotierende Disk (eigener View mit lokalem Rotations-
                // State + Timer, damit die 30-Hz-Drehung NICHT die ganze MainView.body
                // neu rendert — das war die CPU-Hauptursache, 2026-07-09).
                SpinningDiskButton(
                    isPlaying: coordinator.isPlaying,
                    isPaused: coordinator.isPaused,
                    enabled: coordinator.activeMod != nil,
                    theme: theme,
                    onTap: { togglePlayback() }
                )

                // Stop button (setzt an den Songanfang zurueck)
                Button(action: {
                    stopPlayback()
                }) {
                    transportButtonLabel(systemName: "stop.fill")
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(!coordinator.isPlaying)
                .help("Stopp: Wiedergabe beenden — der nächste Start beginnt wieder am Songanfang.")

                // −10s / +10s: schneller Sprung innerhalb des Songs (springt
                // zeilengenau über die aktuelle Zeilendauer). Praktisch, um ohne
                // langes Durchhören an eine Stelle zu gelangen.
                Button(action: { coordinator.seek(bySeconds: -10) }) {
                    transportButtonLabel(systemName: "gobackward.10")
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(!coordinator.isPlaying)
                .help("10 Sekunden zurückspringen.")

                Button(action: { coordinator.seek(bySeconds: 10) }) {
                    transportButtonLabel(systemName: "goforward.10")
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(!coordinator.isPlaying)
                .help("10 Sekunden vorspringen.")

                Divider()
                    .frame(height: 20)

                // Previous button (Playlist-Titel)
                Button(action: {
                    prevTrack()
                }) {
                    transportButtonLabel(systemName: "backward.end.fill")
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(playlist.isEmpty)
                .help("Vorheriger Titel der Playlist (⌘← oder Pfeil links).")

                // Next button (Playlist-Titel)
                Button(action: {
                    nextTrack()
                }) {
                    transportButtonLabel(systemName: "forward.end.fill")
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(playlist.isEmpty)
                .help("Nächster Titel der Playlist (⌘→ oder Pfeil rechts).")

                // Shuffle-Toggle (iTunes-Symbol): zufaellige statt sequenzielle
                // Titel-Wechsel. Aktiv = Akzentfarbe.
                Button(action: {
                    shuffleEnabled.toggle()
                }) {
                    ZStack {
                        if theme == .cyber {
                            Circle()
                                .fill(shuffleEnabled ? Color.spaceAccent : Color.spaceSurface)
                                .overlay(Circle().stroke(Color.spaceAccent.opacity(0.3), lineWidth: 1))
                        } else {
                            Rectangle()
                                .fill(shuffleEnabled ? Color.lightAccent : Color.lightSurfaceAlt)
                        }
                        Image(systemName: "shuffle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(shuffleEnabled ? (theme == .cyber ? .black : .white) : (theme == .workbench ? .lightTextSecondary : .spaceTextSecondary))
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(playlist.isEmpty)
                .help(shuffleEnabled
                      ? "Zufallswiedergabe ist AN: Titel-Wechsel und Songende springen zufällig durch die Playlist."
                      : "Zufallswiedergabe ist AUS: die Playlist spielt der Reihe nach.")
            }
            
            // Middle block: Progress Timeline
            if let mod = coordinator.activeMod {
                HStack(spacing: 12) {
                    // Verstrichene Zeit: eigener 30-Hz-Beobachter (tickt ohne die
                    // MainView.body neu zu rendern).
                    ElapsedTimeText(visualizer: coordinator.visualizerState)

                    // Zeitsprung zurueck — bequeme Alternative zum Slider.
                    Button(action: { coordinator.seek(bySeconds: -15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 14))
                            .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!coordinator.isPlaying)
                    .help("15 Sekunden zurückspringen (zeilengenau; bei Tempo-Wechseln näherungsweise).")

                    // Der Slider springt pro Song-Position und funktioniert auch
                    // im gestoppten Zustand: Play startet dann ab der gewaehlten
                    // Stelle.
                    // WICHTIG: Der Range darf NIE leer sein. Bei Modulen mit nur
                    // EINER Song-Position (mod.length == 1) ergäbe 0...0 einen
                    // leeren Bereich — SwiftUIs Slider löst dann eine precondition
                    // aus und die App STÜRZT AB (2026-07-09, durch kurze XM
                    // aufgedeckt). Darum untere Grenze < obere garantieren
                    // (max(1, …)), den Wert in den Bereich klemmen und den Slider
                    // bei nur einer Position deaktivieren (es gibt nichts zu wählen).
                    // Positions-Slider beobachtet transport (row-rate), nicht coordinator.
                    PositionSlider(transport: coordinator.transport, mod: mod, theme: theme,
                                   onSeek: { coordinator.seek(toPosition: $0) })

                    // Zeitsprung vor.
                    Button(action: { coordinator.seek(bySeconds: 30) }) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 14))
                            .foregroundColor(theme == .workbench ? .lightTextSecondary : .spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!coordinator.isPlaying)
                    .help("30 Sekunden vorspringen (zeilengenau; bei Tempo-Wechseln näherungsweise).")

                    TotalTimeText(visualizer: coordinator.visualizerState)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
                Text("Kein Song geladen")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme == .workbench ? .lightTextPrimary.opacity(0.4) : .spaceTextSecondary)
                Spacer()
            }
            
            // Right block: Volume Fader + WAV + Keyboard + Info
            HStack(spacing: 12) {
                // Keyboard short cuts HUD helper
                Button(action: { showKeyboardHUD = true }) {
                    Image(systemName: "keyboard")
                        .foregroundColor(.spaceTextSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Info Guru modal button
                Button(action: { showAboutModal = true }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.spaceTextSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                
                if coordinator.activeMod != nil {
                    // Exporter wav button
                    Button(action: { runWavExport() }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(isExporting ? .green : .spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Volume slider with glow
                HStack(spacing: 6) {
                    Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme == .workbench ? .lightTextPrimary : .spaceTextSecondary)
                    
                    Slider(value: Binding(
                        get: { volume },
                        set: { volume = $0; coordinator.setVolume(Float($0)) }
                    ), in: 0...1.0)
                    .accentColor(Color.accent(theme))
                    .frame(width: 90)
                    .shadow(color: theme == .cyber ? Color.spaceAccent.opacity(volume * 0.8) : Color.clear, radius: 4)
                }
            }
        }
    }
    
    // Custom Guru Meditation retro about modal view
    private var guruMeditationAboutView: some View {
        ZStack {
            Color.black.opacity(0.85)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                Text("SOFTWARE FAILURE. Click button to continue.")
                    .font(.system(.body))
                    .foregroundColor(.red)
                    .bold()
                
                VStack(spacing: 4) {
                    Text("Guru Meditation #00000004.0000404C")
                        .font(.system(.title3))
                        .foregroundColor(.red)
                        .bold()
                }
                .padding()
                .border(Color.red, width: 3)
                .background(Color.black)
                .overlay(
                    Rectangle()
                        .stroke(Color.red, lineWidth: 1)
                        .padding(2)
                )
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("SAVAGE PROTRACKER PLAYER - NATIVE APPLE SWIFT")
                        .bold()
                        .foregroundColor(.spaceAccent)

                    Text("• Engine: AVAudioEngine + lock-free AVAudioSourceNode")
                    Text("• Formate: ProTracker MOD, Multichannel, Soundtracker, S3M")
                    Text("• Clock Rate: Configurable PAL (3.546MHz) / NTSC (3.580MHz)")
                    Text("• Mixing model: Authentic Nearest or linear Interpolated (Hifi)")
                    Text("• Design: Classic Light & Graphite Dark Themes")
                    Text("• Features: Quick-Look-Plugin, WAV-Export, Media-Tasten")

                    Divider().background(Color.spaceAccent.opacity(0.3))

                    Text("© 2026 Daniel Müller — Autor & Maintainer")
                        .foregroundColor(.spaceAccentGlow)
                    Text("WTFPL — Quellcode: github.com/DanielMuellerIR/savage_modplayer")
                }
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding()
                .background(Color.spaceSurface.opacity(0.4))
                .cornerRadius(6)
                
                Button("SCHLIESSEN") {
                    showAboutModal = false
                }
                .font(.system(.body))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.lightAccent)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(32)
            .background(Color.black)
            .border(Color.red, width: 4)
            .frame(width: 550)
        }
    }
    
    // Keyboard HUD Sheet View
    private var keyboardHUDView: some View {
        ZStack {
            Color.black.opacity(0.6)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                Text("TASTATUR-KURZBEFEHLE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.accent(theme))
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("LEERTASTE")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text("Abspielen / Pause")
                    }
                    HStack {
                        Text("⌘ .")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text("Stopp (zurück zum Anfang)")
                    }
                    HStack {
                        Text("PFEIL RECHTS")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text("Nächster Titel")
                    }
                    HStack {
                        Text("PFEIL LINKS")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text("Vorheriger Titel")
                    }
                    HStack {
                        Text("ESC")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text("Menüs schließen")
                    }
                }
                .font(.system(size: 11))
                .padding()
                
                Button("SCHLIESSEN") {
                    showKeyboardHUD = false
                }
                .font(.system(.body))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.accent(theme))
                .cornerRadius(theme == .workbench ? 0 : 6)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(24)
            .background(theme == .workbench ? Color.lightSurfaceAlt : Color.spaceSurface)
            .border(theme == .workbench ? Color.lightTextPrimary : Color.spaceAccent.opacity(0.3), width: theme == .workbench ? 2 : 1)
            .cornerRadius(theme == .workbench ? 0 : 12)
            .frame(width: 380)
        }
    }
    
    // WAV offline exporter dialog
    private var wavExporterDialog: some View {
        ZStack {
            Color.black.opacity(0.5)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 16) {
                Text("OFFLINE-WAV-EXPORT")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.accent(theme))
                
                Text("Exportiert den gesamten Track offline in eine WAV Datei.")
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.spaceTextSecondary)
                
                Picker("Dauer begrenzen:", selection: $exportSecondsLimit) {
                    Text("1 Minute").tag(60.0)
                    Text("3 Minuten").tag(180.0)
                    Text("5 Minuten").tag(300.0)
                    Text("10 Minuten").tag(600.0)
                }
                .pickerStyle(DefaultPickerStyle())
                .font(.system(size: 10))
                
                HStack(spacing: 12) {
                    Button("ABBRECHEN") {
                        showExportDialog = false
                    }
                    .font(.system(size: 10))
                    
                    Button("STARTEN") {
                        showExportDialog = false
                        runWavExport()
                    }
                    .font(.system(size: 10))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
            }
            .padding(20)
            .background(Color.spaceSurface)
            .cornerRadius(10)
            .frame(width: 320)
        }
    }
    
    // Blur drag-and-drop indicator
    private var dragDropOverlayView: some View {
        ZStack {
            Color.black.opacity(0.4)
                .blur(radius: 20)
            
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.spaceAccent, lineWidth: 3)
                .padding(30)
            
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.spaceAccent)
                Text("MOD DATEIEN HIER ABLEGEN")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .allowsHitTesting(false)
    }
}

struct TabButton: View {
    let title: String
    let tag: Int
    @Binding var selection: Int
    let theme: PlayerTheme
    
    var body: some View {
        let isSelected = selection == tag
        Button(action: { selection = tag }) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(
                        isSelected
                        ? (theme == .workbench ? Color.lightAccent : Color.white)
                        : (theme == .workbench ? Color.lightTextPrimary.opacity(0.5) : Color.spaceTextSecondary.opacity(0.7))
                    )
                
                Rectangle()
                    .fill(
                        isSelected
                        ? (Color.accent(theme))
                        : Color.clear
                    )
                    .frame(height: 2)
                    .shadow(color: isSelected && theme == .cyber ? Color.spaceAccent.opacity(0.8) : Color.clear, radius: 4)
            }
            // Volle Breite + vertikales Polster + contentShape: der ganze
            // Tab-Bereich (nicht nur der Text) schaltet um.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    let theme: PlayerTheme
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? (Color.accent(theme)) : .spaceTextSecondary)
                configuration.label
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Laufschrift (Marquee) fuer zu lange Titel

// Preference-Keys zum Messen von Textgroesse und Container-Breite (ohne das
// Layout zu beeinflussen — die Messung laeuft ueber transparente GeometryReader).
private struct MarqueeTextSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct MarqueeContainerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Einzeiliger Titel, der als Laufschrift scrollt, wenn er breiter als der
// verfuegbare Platz ist. Ablauf pro Runde: 4 s am Anfang stehen, gleichmaessig
// nach links bis zum Ende scrollen, 4 s am Ende stehen, ohne Animation an den
// Anfang zurueckspringen, wieder 4 s stehen — und von vorn.
// Diese View wird nur im Ueberlauf-Fall verwendet (ViewThatFits zeigt sonst den
// statischen Text), deshalb wird hier immer gescrollt, sobald gemessen ist.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var textHeight: CGFloat = 24  // vernuenftiger Startwert gegen Flackern
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scrollTask: Task<Void, Never>? = nil

    // Scroll-Tempo (Punkte pro Sekunde) und Steh-Dauer an den Enden.
    private let pointsPerSecond: Double = 40
    private let dwellNanos: UInt64 = 4_000_000_000  // 4 Sekunden

    var body: some View {
        // Color.clear ist die flexible Basis: sie fuellt die verfuegbare Breite,
        // FORDERT sie aber nicht als Ideal-Breite. Ein fixedSize-Text als Basis
        // wuerde dagegen seine volle Breite als Ideal melden und die Kopfzeile
        // aufblaehen (rechte Bedienelemente/Sidebar aus dem Fenster gedrueckt).
        // Der eigentliche Titel liegt als linksbuendiges Overlay darueber, laeuft
        // bei Ueberlaenge nach links heraus (offset) und wird geclippt.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: textHeight, maxHeight: textHeight)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()  // volle Breite/Hoehe, kein Kuerzen
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: MarqueeTextSizeKey.self, value: g.size)
                        }
                    )
                    .offset(x: offset)
            }
            .clipped()  // ueberstehenden Titel abschneiden
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: MarqueeContainerWidthKey.self, value: g.size.width)
                }
            )
            .onPreferenceChange(MarqueeTextSizeKey.self) { s in
                textWidth = s.width
                textHeight = s.height
                restartScroll()
            }
            .onPreferenceChange(MarqueeContainerWidthKey.self) { w in
                containerWidth = w
                restartScroll()
            }
            .onChange(of: text) { _ in restartScroll() }
            .onDisappear { scrollTask?.cancel() }
    }

    // Startet die Scroll-Schleife neu (nach Mess- oder Titelaenderung). Passt der
    // Text (kein Ueberlauf), bleibt er einfach stehen.
    private func restartScroll() {
        scrollTask?.cancel()
        offset = 0
        let distance = textWidth - containerWidth
        guard distance > 1, containerWidth > 0 else { return }

        let duration = Double(distance) / pointsPerSecond
        scrollTask = Task { @MainActor in
            while !Task.isCancelled {
                // 4 s am Anfang stehen
                try? await Task.sleep(nanoseconds: dwellNanos)
                if Task.isCancelled { break }
                // gleichmaessig nach links bis zum Ende scrollen
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                if Task.isCancelled { break }
                // 4 s am Ende stehen
                try? await Task.sleep(nanoseconds: dwellNanos)
                if Task.isCancelled { break }
                // ohne Animation an den Anfang zurueckspringen; die naechste
                // Schleifenrunde beginnt wieder mit der 4-s-Startpause
                offset = 0
            }
        }
    }
}
