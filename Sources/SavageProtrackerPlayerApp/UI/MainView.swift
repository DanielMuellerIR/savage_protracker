import SwiftUI
import SavageProtrackerPlayerCore
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
    
    // Sidebar tabs
    @State private var selectedSidebarTab: Int = 0 // 0 = Playlist, 1 = Instrumente
    
    // Playlist states
    @State private var playlist: [URL] = []
    @State private var currentPlaylistIndex: Int = -1
    
    // Search & Filter
    @State private var playlistSearchQuery: String = ""
    
    // Recent Songs History
    @State private var recentSongs: [URL] = []
    
    @State private var showFileImporter = false
    @State private var dragOver = false
    @State private var errorMessage: String? = nil
    
    // Keyboard HUD & About Overlay Modals
    @State private var showKeyboardHUD = false
    @State private var showAboutModal = false
    
    // WAV Export Panel
    @State private var isExporting = false
    @State private var showExportDialog = false
    @State private var exportSecondsLimit: Double = 180.0
    @State private var exportStatusMessage: String? = nil
    
    // Disk rotation state
    @State private var diskRotation: Double = 0.0
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
                    .background(theme == .workbench ? Color.amigaBlue : Color.clear)
                    
                    Divider()
                        .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.2))
                    
                    if selectedSidebarTab == 0 {
                        playlistSidebar
                    } else {
                        instrumentsSidebar
                    }
                }
                .frame(width: 260)
                .background(
                    theme == .workbench ? Color.amigaBlue : Color.spaceSurface
                )
                
                Divider()
                    .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.3))
                
                // Main Panel
                VStack(spacing: 0) {
                    // Header (Track Title and Metadata)
                    headerView
                        .padding()
                        .background(theme == .workbench ? Color.amigaBlue : Color.spaceSurface.opacity(0.4))
                    
                    Divider()
                        .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.2))
                    
                    // Pattern Position Marker Map list
                    if let mod = coordinator.activeMod {
                        patternMarkerMap(mod: mod)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .background(theme == .workbench ? Color.amigaBlue.opacity(0.3) : Color.spaceBackground.opacity(0.4))
                        Divider()
                            .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.1))
                    }
                    
                    // VU Visualizers & Synthesis Options Panel
                    vuVisualizersView
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground.opacity(0.2))
                    
                    Divider()
                        .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.1))
                    
                    // Scrolling Tracker Grid or Empty State Drop Zone
                    VStack(spacing: 0) {
                        // Defensiv gegen leere/korrupte Mods: length, patternTable und
                        // der daraus gelesene patternIndex werden vor dem Zugriff geprueft
                        // (sonst patternTable[-1] / patterns[ausserhalb] -> Crash).
                        // codereview-ok: defensiv by-design — patternTable wird direkt danach indiziert; der isEmpty/length-Guard verhindert patternTable[-1]-Crash (2026-07-01)
                        if let mod = coordinator.activeMod,
                           mod.length > 0,
                           !mod.patternTable.isEmpty {
                            let tableIdx = max(0, min(mod.length - 1, coordinator.currentPosition))
                            let patternIndex = mod.patternTable[max(0, min(mod.patternTable.count - 1, tableIdx))]
                            if patternIndex >= 0, patternIndex < mod.patterns.count {
                                TrackerGridView(pattern: mod.patterns[patternIndex], currentRow: coordinator.currentRow, theme: theme)
                                    .padding()
                            } else {
                                dropZonePrompt
                                    .padding()
                            }
                        } else {
                            dropZonePrompt
                                .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme == .workbench ? Color.amigaDarkBlue : Color.clear)
                    
                    Divider()
                        .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.2))
                    
                    // Master Oscilloscope & Separation Sliders
                    masterOscilloscopeView
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground.opacity(0.3))
                    
                    Divider()
                        .background(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.3))
                    
                    // Toolbar Control Panel
                    controlPanelView
                        .padding()
                        .background(theme == .workbench ? Color.amigaBlue : Color.spaceSurface.opacity(0.4))
                }
                .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground)
            }
            .frame(minWidth: 1080, minHeight: 720)
            .foregroundColor(theme == .workbench ? Color.amigaWhite : Color.spaceTextPrimary)
            .font(theme == .workbench ? .system(.body, design: .monospaced) : .body)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, UTType(filenameExtension: "mod"), UTType(filenameExtension: "s3m")].compactMap { $0 },
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    handleDroppedURLs(urls)
                case .failure(let error):
                    self.errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
                }
            }
            .onDrop(of: ["public.file-url"], isTargeted: $dragOver) { providers in
                let container = DropURLsContainer()
                let dispatchGroup = DispatchGroup()
                
                for provider in providers {
                    dispatchGroup.enter()
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                        if let data = item as? Data {
                            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                                if let path = plist as? String {
                                    container.append(URL(fileURLWithPath: path))
                                } else if let array = plist as? [String] {
                                    for path in array {
                                        container.append(URL(fileURLWithPath: path))
                                    }
                                }
                            } else if let path = String(data: data, encoding: .utf8) {
                                container.append(URL(fileURLWithPath: path))
                            }
                        } else if let url = item as? URL {
                            container.append(url)
                        } else if let string = item as? String {
                            container.append(URL(fileURLWithPath: string))
                        }
                        dispatchGroup.leave()
                    }
                }
                
                dispatchGroup.notify(queue: .main) {
                    let urls = container.urls
                    if !urls.isEmpty {
                        handleDroppedURLs(urls)
                    }
                }
                return true
            }
            .onAppear {
                isDiskAnimating = coordinator.isPlaying
                setupNotifications()
                installKeyMonitor()
                setupMediaRemoteCommands()
                startOrStopDiskSpin()
                // Gespeicherte Lautstaerke in den Coordinator spiegeln, damit der
                // erste play()-Aufruf sie auf den Mixer anwenden kann.
                coordinator.setVolume(Float(volume))
                loadLocalAudioFolder()
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
                startOrStopDiskSpin()
            }
            // Pause haelt auch die Disk-Animation an (isPlaying bleibt true).
            .onChange(of: coordinator.isPaused) { isPaused in
                isDiskAnimating = coordinator.isPlaying && !isPaused
                startOrStopDiskSpin()
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

    private func nextTrack() {
        guard !playlist.isEmpty else { return }
        // Transportzustand erhalten: setMod() in loadModFile ruft stop(), daher
        // VOR dem Wechsel merken, ob gerade aktiv (nicht pausiert) gespielt wurde.
        let wasPlaying = coordinator.isPlaying && !coordinator.isPaused
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
    
    private func handleDroppedURLs(_ urls: [URL]) {
        self.errorMessage = nil
        // Dateisystem-Traversal + Kopieren laufen im Hintergrund — ein grosser
        // Ordner-Drop blockierte sonst den Main-Thread (Beachball). Nur die
        // @State-Mutation und das Laden der ersten Datei kehren auf den Main-Thread
        // zurueck.
        DispatchQueue.global(qos: .userInitiated).async {
            let modFiles = MainView.copyModFilesToTemp(urls)
            DispatchQueue.main.async {
                guard !modFiles.isEmpty else {
                    self.errorMessage = "Keine passenden .mod/.s3m Dateien gefunden."
                    return
                }
                let sorted = self.sortedByDisplayName(modFiles)
                self.playlist = sorted
                self.selectedSidebarTab = 0 // Playlist fokussieren
                self.currentPlaylistIndex = 0
                // Headless-/Agent-Steuerung: "--autoplay [filter]" startet die
                // Wiedergabe sofort (optional den ersten Titel, dessen Name den
                // Filter enthaelt) — fuer Screenshots und Smoke-Tests ohne Klicks.
                if let autoplayIndex = Self.autoplayIndex(in: sorted) {
                    self.selectPlaylistSong(at: autoplayIndex, autoPlay: true)
                } else {
                    self.loadModFile(from: sorted[0])
                }
            }
        }
    }

    // Wertet das Kommandozeilen-Argument "--autoplay [filter]" aus. Liefert den
    // Playlist-Index des zu startenden Titels oder nil (kein Autoplay gewuenscht).
    nonisolated private static func autoplayIndex(in urls: [URL]) -> Int? {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--autoplay") else { return nil }
        let next = flagIndex + 1
        if next < args.count, !args[next].hasPrefix("--") {
            let filter = args[next].lowercased()
            if let match = urls.firstIndex(where: { $0.lastPathComponent.lowercased().contains(filter) }) {
                return match
            }
        }
        return 0
    }

    // Hintergrund-Worker: kopiert alle .mod-Dateien aus den gedroppten URLs (inkl.
    // Ordner-Rekursion) in ein frisches Temp-Unterverzeichnis und liefert die Liste.
    // Beruehrt KEINEN @State — laeuft sicher abseits des Main-Threads.
    nonisolated private static func copyModFilesToTemp(_ urls: [URL]) -> [URL] {
        var modFiles: [URL] = []
        let fm = FileManager.default
        // Pro Drop ein eigenes Unterverzeichnis statt das gemeinsame zu loeschen:
        // sonst entwertet ein neuer Drop die Temp-URLs frueherer Baetche.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ModPlayerTemp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

        func copyIfMod(_ fileURL: URL) {
            guard isModFile(fileURL) else { return }
            let destURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(fileURL.lastPathComponent)")
            do {
                try fm.copyItem(at: fileURL, to: destURL)
                modFiles.append(destURL)
            } catch {
                print("Fehler beim Kopieren: \(error)")
            }
        }

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            let fileAccessed = fileURL.startAccessingSecurityScopedResource()
                            copyIfMod(fileURL)
                            if fileAccessed { fileURL.stopAccessingSecurityScopedResource() }
                        }
                    }
                } else {
                    copyIfMod(url)
                }
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        return modFiles
    }
    
    private func selectPlaylistSong(at index: Int, autoPlay: Bool = true) {
        guard index >= 0 && index < playlist.count else { return }
        self.currentPlaylistIndex = index
        let songUrl = playlist[index]
        if loadModFile(from: songUrl) {
            // Nur abspielen, wenn gewuenscht — sonst startet z.B. Weiterblaettern
            // im pausierten Zustand ungewollt die Wiedergabe.
            if autoPlay { coordinator.play() }
        }
        
        // Add to history
        if !recentSongs.contains(songUrl) {
            recentSongs.insert(songUrl, at: 0)
            if recentSongs.count > 10 {
                recentSongs.removeLast()
            }
        }
    }
    
    @discardableResult
    private func loadModFile(from url: URL) -> Bool {
        self.errorMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        
        do {
            let fileData = try Data(contentsOf: url)
            // ModuleLoader erkennt das Format am Inhalt (MOD-Varianten, S3M).
            let mod = try ModuleLoader.parse(data: fileData)
            coordinator.setMod(mod)
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
    
    private func sortedByDisplayName(_ urls: [URL]) -> [URL] {
        urls.sorted {
            cleanFilename($0).localizedStandardCompare(cleanFilename($1)) == .orderedAscending
        }
    }

    nonisolated private static func isModFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        return ModuleLoader.supportedExtensions.contains(ext) || name.hasPrefix("mod.")
    }
    
    private func loadLocalAudioFolder() {
        let fm = FileManager.default
        var candidateDirs: [URL] = []
        candidateDirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("audio"))
        if let bundlePath = Bundle.main.bundlePath as String? {
            let appDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            candidateDirs.append(appDir.appendingPathComponent("audio"))
        }
        for dir in candidateDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let mods = sortedByDisplayName(contents.filter { Self.isModFile($0) })
            if mods.isEmpty { continue }
            handleDroppedURLs(mods)
            return
        }
    }
    
    private func triggerDemoPlay() {
        let demoMod = ModParser.generateDemoMod()
        coordinator.setMod(demoMod)
        coordinator.play()
    }

    // Ein Kanal-Streifen (VU-Meter, Mini-Oszilloskop, Mute/Solo) — von der
    // dynamischen Kanal-Leiste pro Kanal aufgerufen. Die Index-Guards fangen
    // den kurzen Moment ab, in dem channelCount schon aktualisiert ist, aber
    // vuLevels/channelWaveforms noch die alte Länge haben.
    @ViewBuilder
    private func channelStripView(_ i: Int) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                // VU segmented LED
                VUMeterView(value: i < coordinator.vuLevels.count ? coordinator.vuLevels[i] : 0, theme: theme)
                    .frame(width: 24, height: 50)

                // Rolling channel oscilloscope waveform path
                GeometryReader { geo in
                    Path { path in
                        guard i < coordinator.channelWaveforms.count else { return }
                        let history = coordinator.channelWaveforms[i]
                        guard history.count > 0 else { return }
                        let step = geo.size.width / CGFloat(history.count - 1)
                        path.move(to: CGPoint(x: 0, y: geo.size.height * CGFloat(0.5 - history[0] * 0.5)))
                        for idx in 1..<history.count {
                            path.addLine(to: CGPoint(x: CGFloat(idx) * step, y: geo.size.height * CGFloat(0.5 - history[idx] * 0.5)))
                        }
                    }
                    .stroke(theme == .workbench ? Color.amigaOrange : Color.spaceAccent, lineWidth: 1.2)
                }
                .frame(width: 44, height: 50)
                // Wie das Master-Oszilloskop: im Light-Mode weisser Hintergrund
                // mit dezentem Rahmen (einheitliche Scope-Optik).
                .background(theme == .workbench ? Color.white : Color.black.opacity(0.2))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(theme == .workbench ? Color.amigaGrey.opacity(0.35) : Color.clear, lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                Text("CH \(i + 1)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.7) : .spaceTextSecondary)

                // MUTE / SOLO buttons
                Button("M") {
                    coordinator.toggleMute(channelIndex: i)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3)
                .background(coordinator.isMuted(channelIndex: i) ? Color.red : Color.clear)
                .foregroundColor(coordinator.isMuted(channelIndex: i) ? .white : .red)
                .cornerRadius(2)

                Button("S") {
                    coordinator.toggleSolo(channelIndex: i)
                }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3)
                .background(coordinator.isSoloed(channelIndex: i) ? Color.green : Color.clear)
                .foregroundColor(coordinator.isSoloed(channelIndex: i) ? .white : .green)
                .cornerRadius(2)
            }
        }
    }
    
    // MARK: - Disk spin (deklarativ statt Timer)
    // Treibt die Drehung des Disk-Icons rein ueber eine SwiftUI-Animation —
    // kein run-loop-Timer, der leakt und im Idle CPU/Akku frisst.
    private func startOrStopDiskSpin() {
        #if os(macOS)
        // isDiskAnimating (statt coordinator.isPlaying) beruecksichtigt auch
        // Pause: die Disk steht, sobald kein Ton laeuft.
        if isDiskAnimating {
            diskRotation = 0
            withAnimation(.linear(duration: 2.7).repeatForever(autoreverses: false)) {
                diskRotation = 360
            }
        } else {
            // repeatForever zuverlaessig abbrechen: Wert OHNE Animation setzen
            // (ein withAnimation-Override liess die Drehung teils weiterlaufen).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                diskRotation = 0
            }
        }
        #endif
    }

    // MARK: - Keyboard handling (Leertaste/Pfeile/ESC aus dem HUD)
    private func installKeyMonitor() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Nicht in Textfelder (Suche/Export) eingreifen.
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
            MPMediaItemPropertyPlaybackDuration: coordinator.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: coordinator.elapsedTime,
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
    
    // MARK: - Time helper
    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && !sec.isNaN else { return "00:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    // MARK: - UI Components
    
    private var playlistSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.spaceTextSecondary)
                TextField("Titel filtern...", text: $playlistSearchQuery)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 11, design: .monospaced))
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
            .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground)
            .cornerRadius(theme == .workbench ? 0 : 6)
            .padding([.horizontal, .top], 8)
            
            if playlist.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 36))
                        .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.3) : .spaceAccent.opacity(0.4))
                    
                    Text("Playlist leer")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    
                    Text("Dateien oder Ordner per Drag & Drop reinziehen.")
                        .font(.system(size: 10, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.spaceTextSecondary)
                        .padding(.horizontal, 12)
                    
                    Button("Demo abspielen") {
                        triggerDemoPlay()
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                    .foregroundColor(.white)
                    .cornerRadius(theme == .workbench ? 0 : 6)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack {
                    Text("TITEL (\(filteredPlaylist.count))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme == .workbench ? .amigaOrange : .spaceAccentGlow)
                    Spacer()
                    Button("Leeren") {
                        coordinator.stop()
                        playlist.removeAll()
                        currentPlaylistIndex = -1
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaOrange : .spaceTextSecondary)
                    .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(theme == .workbench ? Color.amigaBlue.opacity(0.5) : Color.spaceBackground.opacity(0.5))
                
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredPlaylist, id: \.self) { fileURL in
                            let playlistIndex = playlist.firstIndex(of: fileURL) ?? -1
                            let isPlayingSong = playlistIndex == currentPlaylistIndex
                            
                            Button(action: { selectPlaylistSong(at: playlistIndex) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: isPlayingSong ? "speaker.wave.2.fill" : "music.note")
                                        .font(.system(size: 11))
                                        .foregroundColor(isPlayingSong ? (theme == .workbench ? .amigaOrange : .spaceAccent) : .spaceTextSecondary)
                                    
                                    Text(cleanFilename(fileURL))
                                        .font(.system(size: 11, weight: isPlayingSong ? .bold : .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: theme == .workbench ? 0 : 6)
                                        .fill(
                                            isPlayingSong
                                            ? (theme == .workbench ? Color.amigaOrange.opacity(0.2) : Color.spaceAccent.opacity(0.15))
                                            : Color.clear
                                        )
                                )
                                .foregroundColor(isPlayingSong ? (theme == .workbench ? .amigaOrange : .white) : (theme == .workbench ? .amigaWhite : .spaceTextSecondary))
                            }
                            .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                        }
                    }
                }
                
                if !recentSongs.isEmpty {
                    Divider().background(Color.spaceAccent.opacity(0.2))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ZULETZT GESPIELT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.spaceTextSecondary)
                            .padding(.horizontal, 8)
                        
                        ForEach(recentSongs.prefix(4), id: \.self) { url in
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
                                    playlist.append(url)
                                    playlist = sortedByDisplayName(playlist)
                                    if let idx = playlist.firstIndex(of: url) {
                                        selectPlaylistSong(at: idx)
                                    }
                                }
                            }) {
                                Text(cleanFilename(url))
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundColor(.spaceTextSecondary.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
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
                                            .foregroundColor(theme == .workbench ? .amigaOrange : .codeInstrument)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .frame(width: 18)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(inst.name.isEmpty ? "Instrument \(i)" : inst.name)
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .lineLimit(1)
                                                Spacer()
                                                
                                                if inst.length > 0 {
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
                                                let lengthRatio = min(1.0, Double(inst.length) / 65536.0)
                                                ZStack(alignment: .leading) {
                                                    Rectangle()
                                                        .fill(theme == .workbench ? Color.amigaWhite.opacity(0.1) : Color.white.opacity(0.03))
                                                    Rectangle()
                                                        .fill(theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                                                        .frame(width: geo.size.width * CGFloat(lengthRatio))
                                                }
                                            }
                                            .frame(height: 3)
                                            .cornerRadius(1)
                                            
                                            Text(String(format: "Len: %d B | Fine: %d | Vol: %d", inst.length, inst.finetune, inst.volume))
                                                .font(.system(size: 8.5, design: .monospaced))
                                                .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.6) : .spaceTextSecondary)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
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
                                        .stroke(theme == .workbench ? Color.amigaGrey.opacity(0.35) : Color.clear, lineWidth: 1)
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
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.4) : .spaceTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
    }
    
    // Kurzes Format-Kuerzel fuer das Badge neben dem Songtitel.
    private var formatBadgeText: String {
        switch coordinator.activeMod?.format {
        case .s3m: return "S3M"
        case .multichannel: return "MULTICHANNEL"
        case .soundtracker: return "SOUNDTRACKER"
        default: return "PROTRACKER"
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(coordinator.trackName)
                        .font(theme == .workbench ? .system(size: 20, weight: .bold, design: .monospaced) : .title2)
                        .foregroundColor(theme == .workbench ? .amigaOrange : .white)
                        .lineLimit(1)
                    
                    if theme == .cyber {
                        // Format-Badge des aktiven Moduls (nicht mehr statisch
                        // "PROTRACKER" — seit 1.3.0 spielt die App auch S3M & Co.).
                        Text(formatBadgeText)
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.spaceAccent)
                            .foregroundColor(.black)
                            .cornerRadius(3)
                    }
                }
                
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "metronome")
                        Text(String(format: "BPM: %d", coordinator.bpm))
                        
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
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                        Text(String(format: "SPD: %d", coordinator.speed))
                        
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
                    if let mod = coordinator.activeMod {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note.list")
                            Text(String(format: "PAT: %d/%d", coordinator.currentPosition + 1, mod.length))
                        }
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.8) : .spaceTextSecondary)
            }
            
            Spacer()
            
            // PAL / NTSC Clock Toggle selector
            HStack(spacing: 4) {
                Button("PAL (7.09MHz)") {
                    coordinator.palClock = true
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(coordinator.palClock ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent) : Color.clear)
                // Inaktive Beschriftung theme-abhängig: das Dark-Grau war im
                // Light-Mode auf dem hellen Kasten unlesbar.
                .foregroundColor(coordinator.palClock ? .white : (theme == .workbench ? .amigaGrey : .spaceTextSecondary))
                .cornerRadius(4)
                .buttonStyle(PlainButtonStyle())
                .help("PAL-Paula-Takt (3,546 MHz) wie bei europäischen Amigas — die Referenz-Tonhöhe und -Geschwindigkeit der meisten Module.")

                Button("NTSC (7.16MHz)") {
                    coordinator.palClock = false
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(!coordinator.palClock ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent) : Color.clear)
                .foregroundColor(!coordinator.palClock ? .white : (theme == .workbench ? .amigaGrey : .spaceTextSecondary))
                .cornerRadius(4)
                .buttonStyle(PlainButtonStyle())
                .help("NTSC-Paula-Takt (3,580 MHz) wie bei US-Amigas — Module klingen minimal höher und laufen etwas schneller als mit PAL.")
            }
            .padding(2)
            .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground.opacity(0.4))
            .cornerRadius(6)
            
            // Theme Selector
            HStack(spacing: 4) {
                ForEach(PlayerTheme.allCases) { t in
                    Button(action: { theme = t }) {
                        Text(t == .workbench ? "LIGHT" : "DARK")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                theme == t
                                ? (t == .workbench ? Color.amigaOrange : Color.spaceAccent)
                                : (theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface.opacity(0.5))
                            )
                            .foregroundColor(theme == t ? Color.white : (theme == .workbench ? Color.amigaWhite : Color.spaceTextSecondary))
                            .cornerRadius(theme == .workbench ? 0 : 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(3)
            .background(theme == .workbench ? Color.amigaBlue : Color.spaceBackground.opacity(0.6))
            .cornerRadius(theme == .workbench ? 0 : 6)
            
            // File Open Button
            Button(action: { showFileImporter = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                    Text("ÖFFNEN")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                .foregroundColor(.white)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(PremiumHoverButtonStyle(theme: theme))
            .cornerRadius(theme == .workbench ? 0 : 6)
        }
    }
    
    private var vuVisualizersView: some View {
        HStack(spacing: 16) {
            // Spinning Disk Indicator
            ZStack {
                Circle()
                    .fill(theme == .workbench ? Color.amigaWhite.opacity(0.1) : Color.spaceSurface)
                    .frame(width: 54, height: 54)
                    .shadow(color: theme == .workbench ? Color.clear : Color.spaceAccent.opacity(0.3), radius: 6)
                
                Image(systemName: "opticaldisc.fill")
                    .font(.system(size: 42))
                    .foregroundColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    .rotationEffect(.degrees(diskRotation))
                
                Circle()
                    .fill(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground)
                    .frame(width: 8, height: 8)
            }
            .opacity(coordinator.isPlaying ? 1.0 : 0.4)
            .animation(.easeInOut, value: coordinator.isPlaying)
            
            Divider()
                .background(theme == .workbench ? Color.amigaWhite.opacity(0.2) : Color.spaceAccent.opacity(0.2))
                .frame(height: 48)
            
            // Peak Level VU Meters with Mute/Solo and Oscilloscope under them.
            // Kanalzahl ist dynamisch (4 bei MOD, mehr bei 6CHN/8CHN/S3M);
            // ab 5 Kanälen scrollt die Leiste horizontal, damit das Layout
            // nicht explodiert.
            if coordinator.channelCount <= 4 {
                ForEach(0..<coordinator.channelCount, id: \.self) { i in
                    channelStripView(i)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 16) {
                        ForEach(0..<coordinator.channelCount, id: \.self) { i in
                            channelStripView(i)
                        }
                    }
                }
                .frame(maxWidth: 4 * 96)
            }

            Divider()
                .background(theme == .workbench ? Color.amigaWhite.opacity(0.2) : Color.spaceAccent.opacity(0.2))
                .frame(height: 48)
            
            // Audio Option synthesis parameters panel
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Toggle("LED FILTER", isOn: $coordinator.ledFilterActive)
                        .toggleStyle(CheckboxToggleStyle(theme: theme))
                        .help("Amiga-LED-Filter: zuschaltbarer Tiefpass bei ~3,2 kHz, der die Höhen kappt — der dumpfere Originalklang, wie wenn am echten Amiga die Power-LED leuchtete.")

                    Toggle("HI-FI INT.", isOn: $coordinator.useInterpolation)
                        .toggleStyle(CheckboxToggleStyle(theme: theme))
                        .help("Hi-Fi-Interpolation: glättet die Samples beim Resampling (weicherer Klang). Ausgeschaltet klingt es wie die Original-Hardware — roher 8-Bit-Sound mit hörbarem Aliasing.")
                }

                HStack(spacing: 8) {
                    Text("LOOP:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)

                    // Keine feste Breite und kein ALLCAPS mehr: der Picker
                    // nimmt sich die Breite, die der laengste Eintrag braucht,
                    // statt "WIEDERHOLE..." abzuschneiden.
                    Picker("", selection: $loopMode) {
                        ForEach(LoopMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(DefaultPickerStyle())
                    .labelsHidden()
                    .fixedSize()
                    // Das native Popup folgt sonst dem System-Erscheinungsbild:
                    // Im Dark-Theme der App war der gewaehlte Wert auf hellem
                    // System kaum lesbar. Control-Optik ans App-Theme koppeln.
                    .colorScheme(theme == .workbench ? .light : .dark)
                    .help("Was nach dem Songende passiert: Playlist fortsetzen, den Song wiederholen oder stoppen.")
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(6)
            // Im Light-Mode ohne Kasten — der dunkle Hintergrund wirkte dort
            // wie ein Fremdkoerper.
            .background(theme == .workbench ? Color.clear : Color.spaceBackground.opacity(0.4))
            .cornerRadius(6)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(theme == .workbench ? Color.amigaBlue.opacity(0.3) : Color.spaceSurface.opacity(0.5))
        .cornerRadius(theme == .workbench ? 0 : 8)
    }
    
    // Pattern playlist mini-map visualizer
    private func patternMarkerMap(mod: Mod) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<mod.length, id: \.self) { idx in
                    let isCurrent = idx == coordinator.currentPosition
                    let patNum = mod.patternTable[idx]
                    
                    Button(action: { coordinator.seek(toPosition: idx) }) {
                        VStack(spacing: 2) {
                            Text(String(format: "%02d", idx))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                            Text("P\(patNum)")
                                .font(.system(size: 7, design: .monospaced))
                        }
                        .frame(width: 24, height: 26)
                        .background(
                            isCurrent
                            ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                            : (theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface)
                        )
                        .foregroundColor(isCurrent ? .white : .spaceTextSecondary)
                        .cornerRadius(3)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.vertical, 2)
        }
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
                        .foregroundColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                        .rotationEffect(.degrees(dragOver ? 180 : (isDiskAnimating ? 360 : 0)))
                        .scaleEffect(dragOver ? 1.2 : 1.0)
                        .shadow(color: theme == .workbench ? Color.clear : Color.spaceAccent.opacity(0.5), radius: 8)
                }
                
                VStack(spacing: 8) {
                    Text("PROTRACKER MOD PLAYER")
                        .font(theme == .workbench ? .system(size: 16, weight: .bold, design: .monospaced) : .system(size: 18, weight: .bold, design: .default))
                        .foregroundColor(theme == .workbench ? .amigaOrange : .white)
                        .tracking(theme == .cyber ? 2.0 : 0)
                    
                    Text("Ziehe .mod Dateien oder Ordner direkt in dieses Fenster")
                        .font(theme == .workbench ? .system(size: 12, design: .monospaced) : .system(size: 13, weight: .medium))
                        .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.8) : .spaceTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                
                HStack(spacing: 12) {
                    Button(action: { showFileImporter = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.rectangle.on.folder")
                            Text("DATEIEN AUSWÄHLEN")
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                        .foregroundColor(.white)
                        .cornerRadius(theme == .workbench ? 0 : 8)
                    }
                    .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                    
                    Button(action: { triggerDemoPlay() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle")
                            Text("DEMO ABSPIELEN")
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
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
                            .fill(Color.amigaBlue.opacity(0.2))
                            .border(dragOver ? Color.amigaOrange : Color.amigaWhite, width: 2)
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
                .font(.system(size: 11, design: .monospaced))
                .padding(.top, 4)
            }
            
            Spacer()
        }
        .background(theme == .workbench ? Color.amigaDarkBlue : Color.clear)
    }
    
    // Master Oscilloscope visualizer showing master L/R mix output
    private var masterOscilloscopeView: some View {
        HStack(spacing: 16) {
            Text("MASTER OSCILLOSCOPE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)
                .frame(width: 140, alignment: .leading)
            
            GeometryReader { geo in
                Path { path in
                    let samples = coordinator.masterSamples
                    guard samples.count > 0 else { return }
                    let step = geo.size.width / CGFloat(samples.count - 1)
                    
                    path.move(to: CGPoint(x: 0, y: geo.size.height * CGFloat(0.5 - Double(samples[0]) * 0.5)))
                    for idx in 1..<samples.count {
                        let val = Double(samples[idx])
                        let x = CGFloat(idx) * step
                        let y = geo.size.height * CGFloat(0.5 - val * 0.5)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(theme == .workbench ? Color.amigaOrange : Color.spaceAccent, lineWidth: 1.5)
            }
            .frame(height: 32)
            // Light-Mode: weisser Hintergrund statt des dunklen Streifens.
            .background(theme == .workbench ? Color.white : Color.black.opacity(0.3))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme == .workbench ? Color.amigaGrey.opacity(0.35) : Color.spaceAccent.opacity(0.15), lineWidth: 1)
            )
            
            // Stereo Separation bleed adjustment slider
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)

                Slider(value: $coordinator.stereoSeparation, in: 0.0...1.0)
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    .frame(width: 80)

                Text(String(format: "%d%%", Int(coordinator.stereoSeparation * 100)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .help("Stereo-Separation: 100 % = hartes Amiga-Panning (Kanäle ganz links/rechts), 0 % = Mono. Dazwischen wird Übersprechen beigemischt, das Kopfhörer-Ermüdung vermeidet. Am deutlichsten mit Kopfhörern hörbar; über Laptop-Lautsprecher kaum.")
        }
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
                    .fill(Color.amigaOrange)
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
                // Play / Stop button
                Button(action: {
                    togglePlayback()
                }) {
                    ZStack {
                        if theme == .cyber {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.spaceAccent, .spaceAccentGlow],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: Color.spaceAccent.opacity(0.4), radius: 6)
                        } else {
                            Rectangle()
                                .fill(Color.amigaOrange)
                        }

                        // Play/Pause-Toggle: pausiert (fortsetzbar), stoppt NICHT.
                        Image(systemName: coordinator.isPlaying && !coordinator.isPaused ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 18)
                .disabled(coordinator.activeMod == nil)
                .help(coordinator.isPlaying && !coordinator.isPaused
                      ? "Pause — die Wiedergabe lässt sich an derselben Stelle fortsetzen (Leertaste)."
                      : "Abspielen bzw. pausierte Wiedergabe fortsetzen (Leertaste).")

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
            }
            
            // Middle block: Progress Timeline
            if let mod = coordinator.activeMod {
                HStack(spacing: 12) {
                    Text(formatTime(coordinator.elapsedTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.spaceTextSecondary)

                    // Zeitsprung zurueck — bequeme Alternative zum Slider.
                    Button(action: { coordinator.seek(bySeconds: -15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 14))
                            .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!coordinator.isPlaying)
                    .help("15 Sekunden zurückspringen (zeilengenau; bei Tempo-Wechseln näherungsweise).")

                    // Der Slider springt pro Song-Position und funktioniert auch
                    // im gestoppten Zustand: Play startet dann ab der gewaehlten
                    // Stelle.
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.currentPosition) },
                            set: { coordinator.seek(toPosition: Int($0)) }
                        ),
                        in: 0...Double(max(0, mod.length - 1)),
                        step: 1.0
                    )
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    .help("Song-Position wählen — funktioniert auch bei gestoppter Wiedergabe: Play startet dann ab dieser Stelle.")

                    // Zeitsprung vor.
                    Button(action: { coordinator.seek(bySeconds: 30) }) {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 14))
                            .foregroundColor(theme == .workbench ? .amigaGrey : .spaceTextSecondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!coordinator.isPlaying)
                    .help("30 Sekunden vorspringen (zeilengenau; bei Tempo-Wechseln näherungsweise).")

                    Text(formatTime(coordinator.totalDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.spaceTextSecondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
                Text("Kein Song geladen")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaWhite.opacity(0.4) : .spaceTextSecondary)
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
                        .foregroundColor(theme == .workbench ? .amigaWhite : .spaceTextSecondary)
                    
                    Slider(value: Binding(
                        get: { volume },
                        set: { volume = $0; coordinator.setVolume(Float($0)) }
                    ), in: 0...1.0)
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
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
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.red)
                    .bold()
                
                VStack(spacing: 4) {
                    Text("Guru Meditation #00000004.0000404C")
                        .font(.system(.title3, design: .monospaced))
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
                    Text("PROTRACKER PLAYER - NATIVE APPLE SWIFT")
                        .bold()
                        .foregroundColor(.spaceAccent)
                    
                    Text("• Engine: AVAudioEngine + lock-free AVAudioSourceNode")
                    Text("• Clock Rate: Configurable PAL PAL (7.09MHz) / NTSC (7.16MHz)")
                    Text("• Mixing model: Authentic Nearest or linear Interpolated (Hifi)")
                    Text("• Design: Classic Light & Graphite Dark Themes")
                    Text("• Features: WAV audio renderer exporter, notifications & keyboard HUD")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .padding()
                .background(Color.spaceSurface.opacity(0.4))
                .cornerRadius(6)
                
                Button("SCHLIESSEN") {
                    showAboutModal = false
                }
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.amigaOrange)
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
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                
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
                .font(.system(size: 11, design: .monospaced))
                .padding()
                
                Button("SCHLIESSEN") {
                    showKeyboardHUD = false
                }
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                .cornerRadius(theme == .workbench ? 0 : 6)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(24)
            .background(theme == .workbench ? Color.amigaDarkBlue : Color.spaceSurface)
            .border(theme == .workbench ? Color.amigaWhite : Color.spaceAccent.opacity(0.3), width: theme == .workbench ? 2 : 1)
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                
                Text("Exportiert den gesamten Track offline in eine WAV Datei.")
                    .font(.system(size: 10, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.spaceTextSecondary)
                
                Picker("Dauer begrenzen:", selection: $exportSecondsLimit) {
                    Text("1 Minute").tag(60.0)
                    Text("3 Minuten").tag(180.0)
                    Text("5 Minuten").tag(300.0)
                    Text("10 Minuten").tag(600.0)
                }
                .pickerStyle(DefaultPickerStyle())
                .font(.system(size: 10, design: .monospaced))
                
                HStack(spacing: 12) {
                    Button("ABBRECHEN") {
                        showExportDialog = false
                    }
                    .font(.system(size: 10, design: .monospaced))
                    
                    Button("STARTEN") {
                        showExportDialog = false
                        runWavExport()
                    }
                    .font(.system(size: 10, design: .monospaced))
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
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
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
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(
                        isSelected
                        ? (theme == .workbench ? Color.amigaOrange : Color.white)
                        : (theme == .workbench ? Color.amigaWhite.opacity(0.5) : Color.spaceTextSecondary.opacity(0.7))
                    )
                
                Rectangle()
                    .fill(
                        isSelected
                        ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
                        : Color.clear
                    )
                    .frame(height: 2)
                    .shadow(color: isSelected && theme == .cyber ? Color.spaceAccent.opacity(0.8) : Color.clear, radius: 4)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity)
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    let theme: PlayerTheme
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? (theme == .workbench ? .amigaOrange : .spaceAccent) : .spaceTextSecondary)
                configuration.label
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}
