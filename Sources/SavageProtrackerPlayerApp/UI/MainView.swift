import SwiftUI
import SavageProtrackerPlayerCore
import UniformTypeIdentifiers
import UserNotifications

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
    @State private var theme: PlayerTheme = .cyber
    @State private var volume: Float = 0.6
    @State private var loopMode: LoopMode = .none
    
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
    
    // Dynamic Master Oscilloscope history
    @State private var masterOscilloscope: [CGFloat] = [CGFloat](repeating: 0, count: 40)
    
    // Active Preview hover card
    @State private var hoveredInstrumentIndex: Int? = nil
    
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
                    Group {
                        #if os(macOS)
                        if theme == .cyber {
                            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                        } else {
                            Color.amigaBlue
                        }
                        #else
                        theme == .workbench ? Color.amigaBlue : Color.spaceSurface
                        #endif
                    }
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
                        if let mod = coordinator.activeMod {
                            let patternIndex = mod.patternTable[min(mod.length - 1, max(0, coordinator.currentPosition))]
                            let pattern = mod.patterns[patternIndex]
                            
                            TrackerGridView(pattern: pattern, currentRow: coordinator.currentRow, theme: theme)
                                .padding()
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
                .background(
                    Group {
                        #if os(macOS)
                        if theme == .cyber {
                            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                        } else {
                            Color.amigaDarkBlue
                        }
                        #else
                        theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground
                        #endif
                    }
                )
            }
            .frame(minWidth: 1080, minHeight: 720)
            .foregroundColor(theme == .workbench ? Color.amigaWhite : Color.spaceTextPrimary)
            .font(theme == .workbench ? .system(.body, design: .monospaced) : .body)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, UTType(filenameExtension: "mod")].compactMap { $0 },
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
            .overlay(
                Group {
                    if theme == .workbench {
                        CRTScanlinesOverlay()
                        CRTVignetteOverlay()
                    }
                }
            )
            .onAppear {
                isDiskAnimating = coordinator.isPlaying
                setupNotifications()
            }
            .onChange(of: coordinator.isPlaying) { isPlaying in
                isDiskAnimating = isPlaying
            }
            .onChange(of: coordinator.trackName) { newTrackName in
                if coordinator.isPlaying {
                    fireNotification(for: newTrackName)
                }
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
    
    private func togglePlayback() {
        guard coordinator.activeMod != nil else { return }
        if coordinator.isPlaying {
            coordinator.stop()
        } else {
            coordinator.play()
        }
    }
    
    private func nextTrack() {
        guard !playlist.isEmpty else { return }
        let nextIndex = currentPlaylistIndex + 1
        if nextIndex < playlist.count {
            selectPlaylistSong(at: nextIndex)
        } else if loopMode == .playlist {
            selectPlaylistSong(at: 0)
        }
    }
    
    private func prevTrack() {
        guard !playlist.isEmpty else { return }
        let prevIndex = currentPlaylistIndex - 1
        if prevIndex >= 0 {
            selectPlaylistSong(at: prevIndex)
        } else if loopMode == .playlist {
            selectPlaylistSong(at: playlist.count - 1)
        }
    }
    
    // MARK: - Playlists & File Handling
    
    private func handleDroppedURLs(_ urls: [URL]) {
        self.errorMessage = nil
        var modFiles: [URL] = []
        let fm = FileManager.default
        
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ModPlayerTemp", isDirectory: true)
        try? fm.removeItem(at: tempDir)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let keys: [URLResourceKey] = [.isRegularFileKey]
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            let fileAccessed = fileURL.startAccessingSecurityScopedResource()
                            if fileURL.pathExtension.lowercased() == "mod" {
                                let uniquePrefix = UUID().uuidString
                                let destURL = tempDir.appendingPathComponent("\(uniquePrefix)_\(fileURL.lastPathComponent)")
                                try? fm.removeItem(at: destURL)
                                do {
                                    try fm.copyItem(at: fileURL, to: destURL)
                                    modFiles.append(destURL)
                                } catch {
                                    print("Fehler beim Kopieren: \(error)")
                                }
                            }
                            if fileAccessed {
                                fileURL.stopAccessingSecurityScopedResource()
                            }
                        }
                    }
                } else if url.pathExtension.lowercased() == "mod" {
                    let uniquePrefix = UUID().uuidString
                    let destURL = tempDir.appendingPathComponent("\(uniquePrefix)_\(url.lastPathComponent)")
                    try? fm.removeItem(at: destURL)
                    do {
                        try fm.copyItem(at: url, to: destURL)
                        modFiles.append(destURL)
                    } catch {
                        print("Fehler beim Kopieren: \(error)")
                    }
                }
            }
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        if modFiles.isEmpty {
            self.errorMessage = "Keine passenden .mod Dateien gefunden."
            return
        }
        
        modFiles.sort(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        
        self.playlist = modFiles
        self.selectedSidebarTab = 0 // Playlist fokussieren
        
        if let first = modFiles.first {
            self.currentPlaylistIndex = 0
            loadModFile(from: first)
        }
    }
    
    private func selectPlaylistSong(at index: Int) {
        guard index >= 0 && index < playlist.count else { return }
        self.currentPlaylistIndex = index
        let songUrl = playlist[index]
        loadModFile(from: songUrl)
        
        // Add to history
        if !recentSongs.contains(songUrl) {
            recentSongs.insert(songUrl, at: 0)
            if recentSongs.count > 10 {
                recentSongs.removeLast()
            }
        }
    }
    
    private func loadModFile(from url: URL) {
        self.errorMessage = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        
        do {
            let fileData = try Data(contentsOf: url)
            let mod = try ModParser.parse(data: fileData)
            coordinator.setMod(mod)
        } catch {
            self.errorMessage = "Parser-Fehler bei '\(cleanFilename(url))': \(error.localizedDescription)"
            print("Parser-Fehler: \(error)")
        }
    }
    
    private func cleanFilename(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.count > 37 {
            let index = name.index(name.startIndex, offsetBy: 37)
            if name[index] == "_" {
                return String(name[name.index(after: index)...])
            }
        }
        return name
    }
    
    private func triggerDemoPlay() {
        let demoMod = ModParser.generateDemoMod()
        coordinator.setMod(demoMod)
        coordinator.play()
    }
    
    // MARK: - Notification helper
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func fireNotification(for track: String) {
        let content = UNMutableNotificationContent()
        content.title = "Amiga ModPlayer spielt:"
        content.body = track
        let request = UNNotificationRequest(identifier: "modplayer.track", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    // MARK: - WAV Export helper
    private func runWavExport() {
        guard coordinator.activeMod != nil else { return }
        
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
                        try coordinator.exportActiveModToWav(destinationURL: destURL, durationSeconds: exportSecondsLimit)
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
                    
                    Button("Retro Demo abspielen") {
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
                    VStack(spacing: 2) {
                        ForEach(0..<filteredPlaylist.count, id: \.self) { idx in
                            let fileURL = filteredPlaylist[idx]
                            let isPlayingSong = idx == currentPlaylistIndex
                            
                            Button(action: { selectPlaylistSong(at: idx) }) {
                                HStack(spacing: 8) {
                                    Image(systemName: isPlayingSong ? "speaker.wave.2.fill" : "music.note")
                                        .font(.system(size: 11))
                                        .foregroundColor(isPlayingSong ? (theme == .workbench ? .amigaOrange : .spaceAccent) : .spaceTextSecondary)
                                    
                                    Text(cleanFilename(fileURL))
                                        .font(.system(size: 11, weight: isPlayingSong ? .bold : .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
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
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                selectPlaylistSong(at: idx)
                            })
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
                                if let idx = playlist.firstIndex(of: url) {
                                    selectPlaylistSong(at: idx)
                                } else {
                                    playlist.append(url)
                                    selectPlaylistSong(at: playlist.count - 1)
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
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(hoveredInstrumentIndex == i ? Color.spaceAccent.opacity(0.08) : Color.spaceBackground.opacity(0.3))
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
    
    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(coordinator.trackName)
                        .font(theme == .workbench ? .system(size: 20, weight: .bold, design: .monospaced) : .title2)
                        .foregroundColor(theme == .workbench ? .amigaOrange : .white)
                        .lineLimit(1)
                    
                    // Cyber Neon badge
                    if theme == .cyber {
                        Text("PROTRACKER")
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
                .foregroundColor(coordinator.palClock ? .white : .spaceTextSecondary)
                .cornerRadius(4)
                .buttonStyle(PlainButtonStyle())
                
                Button("NTSC (7.16MHz)") {
                    coordinator.palClock = false
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(!coordinator.palClock ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent) : Color.clear)
                .foregroundColor(!coordinator.palClock ? .white : .spaceTextSecondary)
                .cornerRadius(4)
                .buttonStyle(PlainButtonStyle())
            }
            .padding(2)
            .background(Color.spaceBackground.opacity(0.4))
            .cornerRadius(6)
            
            // Theme Selector
            HStack(spacing: 4) {
                ForEach(PlayerTheme.allCases) { t in
                    Button(action: { theme = t }) {
                        Text(t == .workbench ? "RETRO" : "CYBER")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                theme == t
                                ? (theme == .workbench ? Color.amigaOrange : Color.spaceAccent)
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
                    .onAppear {
                        // Increment rotation
                        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                            if isDiskAnimating {
                                diskRotation += 4.0
                            }
                        }
                    }
                
                Circle()
                    .fill(theme == .workbench ? Color.amigaDarkBlue : Color.spaceBackground)
                    .frame(width: 8, height: 8)
            }
            .opacity(coordinator.isPlaying ? 1.0 : 0.4)
            .animation(.easeInOut, value: coordinator.isPlaying)
            
            Divider()
                .background(theme == .workbench ? Color.amigaWhite.opacity(0.2) : Color.spaceAccent.opacity(0.2))
                .frame(height: 48)
            
            // 4 Peak Level VU Meters with Mute/Solo and Oscilloscope under them
            ForEach(0..<4) { i in
                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 4) {
                        // VU segmented LED
                        VUMeterView(value: coordinator.vuLevels[i], theme: theme)
                            .frame(width: 24, height: 50)
                        
                        // Rolling channel oscilloscope waveform path
                        GeometryReader { geo in
                            Path { path in
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
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(3)
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
            
            Divider()
                .background(theme == .workbench ? Color.amigaWhite.opacity(0.2) : Color.spaceAccent.opacity(0.2))
                .frame(height: 48)
            
            // Audio Option synthesis parameters panel
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Toggle("LED FILTER", isOn: $coordinator.ledFilterActive)
                        .toggleStyle(CheckboxToggleStyle(theme: theme))
                    
                    Toggle("HI-FI INT.", isOn: $coordinator.useInterpolation)
                        .toggleStyle(CheckboxToggleStyle(theme: theme))
                }
                
                HStack(spacing: 12) {
                    Text("LOOP MODE:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.spaceTextSecondary)
                    
                    Picker("", selection: $loopMode) {
                        ForEach(LoopMode.allCases) { m in
                            Text(m.rawValue.uppercased()).tag(m)
                        }
                    }
                    .pickerStyle(DefaultPickerStyle())
                    .frame(width: 140)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(6)
            .background(Color.spaceBackground.opacity(0.4))
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
                .foregroundColor(.spaceTextSecondary)
                .frame(width: 140, alignment: .leading)
            
            GeometryReader { geo in
                Path { path in
                    let count = masterOscilloscope.count
                    guard count > 0 else { return }
                    let step = geo.size.width / CGFloat(count - 1)
                    
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.5))
                    for idx in 0..<count {
                        let val = masterOscilloscope[idx]
                        // Bouncing lines centered on y = height/2
                        let offset = geo.size.height * 0.45 * val
                        let x = CGFloat(idx) * step
                        path.addLine(to: CGPoint(x: x, y: geo.size.height * 0.5 - offset))
                        path.move(to: CGPoint(x: x, y: geo.size.height * 0.5 + offset))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.5))
                }
                .stroke(theme == .workbench ? Color.amigaOrange : Color.spaceAccent, lineWidth: 1.5)
            }
            .frame(height: 32)
            .background(Color.black.opacity(0.3))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.spaceAccent.opacity(0.15), lineWidth: 1)
            )
            .onAppear {
                // Update oscilloscope rolling buffer from active coordinator VU peaks
                Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
                    let leftPeak = coordinator.vuLevels[0] + coordinator.vuLevels[3]
                    let rightPeak = coordinator.vuLevels[1] + coordinator.vuLevels[2]
                    let mixPeak = CGFloat(min(1.0, (leftPeak + rightPeak) * 0.6))
                    
                    var newOsc = masterOscilloscope
                    newOsc.removeFirst()
                    newOsc.append(mixPeak)
                    self.masterOscilloscope = newOsc
                }
            }
            
            // Stereo Separation bleed adjustment slider
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundColor(.spaceTextSecondary)
                
                Slider(value: $coordinator.stereoSeparation, in: 0.0...1.0)
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    .frame(width: 80)
                
                Text(String(format: "%d%%", Int(coordinator.stereoSeparation * 100)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.spaceTextSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
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
                                        colors: coordinator.isPlaying ? [.red.opacity(0.8), .red] : [.spaceAccent, .spaceAccentGlow],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: (coordinator.isPlaying ? Color.red : Color.spaceAccent).opacity(0.4), radius: 6)
                        } else {
                            Rectangle()
                                .fill(Color.amigaOrange)
                        }
                        
                        Image(systemName: coordinator.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 18)
                .disabled(coordinator.activeMod == nil)
                
                // Previous button
                Button(action: {
                    prevTrack()
                }) {
                    ZStack {
                        if theme == .cyber {
                            Circle()
                                .fill(Color.spaceSurface)
                                .overlay(Circle().stroke(Color.spaceAccent.opacity(0.3), lineWidth: 1))
                        } else {
                            Rectangle()
                                .fill(Color.amigaOrange.opacity(0.3))
                        }
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(playlist.isEmpty)
                
                // Next button
                Button(action: {
                    nextTrack()
                }) {
                    ZStack {
                        if theme == .cyber {
                            Circle()
                                .fill(Color.spaceSurface)
                                .overlay(Circle().stroke(Color.spaceAccent.opacity(0.3), lineWidth: 1))
                        } else {
                            Rectangle()
                                .fill(Color.amigaOrange.opacity(0.3))
                        }
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                .cornerRadius(theme == .workbench ? 0 : 15)
                .disabled(playlist.isEmpty)
            }
            
            // Middle block: Progress Timeline
            if let mod = coordinator.activeMod {
                HStack(spacing: 12) {
                    Text(formatTime(coordinator.elapsedTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.spaceTextSecondary)
                    
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.currentPosition) },
                            set: { coordinator.seek(toPosition: Int($0)) }
                        ),
                        in: 0...Double(max(0, mod.length - 1)),
                        step: 1.0
                    )
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    
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
                        get: { Double(volume) },
                        set: { volume = Float($0); coordinator.setVolume(volume) }
                    ), in: 0...1.0)
                    .accentColor(theme == .workbench ? .amigaOrange : .spaceAccent)
                    .frame(width: 90)
                    .shadow(color: theme == .cyber ? Color.spaceAccent.opacity(Double(volume) * 0.8) : Color.clear, radius: 4)
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
                    Text("• Design: Custom Amiga 1.3 Workbench & Obsidian Dark Themes")
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
