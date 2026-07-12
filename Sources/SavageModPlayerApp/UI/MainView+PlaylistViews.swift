import SwiftUI
import SavageModPlayerCore
import UniformTypeIdentifiers
import UserNotifications
import MediaPlayer

// Playlist-Seitenleiste der MainView: gefilterte/gebaumte Playlist-Zeilen,
// Playlist- und Instrumenten-Sidebar.
extension MainView {
    var filteredPlaylist: [URL] {
        var result = playlist
        // Favoriten-Filter (Stern) und Textsuche greifen beide NUR die Anzeige
        // ab; die volle `playlist` bleibt für Auswahl/Auto-Next unangetastet.
        if favoritesOnly {
            result = result.filter { isFavorite($0) }
        }
        if !playlistSearchQuery.isEmpty {
            result = result.filter { cleanFilename($0).localizedCaseInsensitiveContains(playlistSearchQuery) }
        }
        return result
    }

    // MARK: - Favoriten

    // UserDefaults-Schlüssel der gemerkten Favoriten (bereinigte Dateinamen).
    static let favoritesDefaultsKey = "savage.favoriteTracks"

    // Ist dieser Titel als Favorit markiert? Vergleich über den bereinigten
    // Dateinamen (stabil über Temp-Kopien/Neustarts hinweg).
    func isFavorite(_ url: URL) -> Bool {
        favorites.contains(cleanFilename(url))
    }

    // Favoriten aus UserDefaults laden (beim App-Start, siehe .onAppear).
    func loadFavorites() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: MainView.favoritesDefaultsKey) ?? [])
    }

    // Favorit an-/abschalten und sofort persistieren.
    func toggleFavorite(_ url: URL) {
        let key = cleanFilename(url)
        if favorites.contains(key) {
            favorites.remove(key)
        } else {
            favorites.insert(key)
        }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: MainView.favoritesDefaultsKey)
    }

    // Eine sichtbare Zeile der Playlist-Sidebar: entweder ein auf-/zuklappbarer
    // Ordner (bzw. ein wie ein Ordner dargestelltes Archiv) oder ein Titel.
    // Datei-Zeilen nutzen die URL als ID — darauf zielt auch das programmatische
    // Scrollen zum laufenden Titel (scrollTo).
    struct PlaylistRow: Identifiable {
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
    var playlistRows: [PlaylistRow] {
        // Bei aktiver Suche ODER aktivem Favoriten-Filter eine flache
        // Trefferliste zeigen — die Ordner-Hierarchie wäre dabei nur im Weg.
        if !playlistSearchQuery.isEmpty || favoritesOnly {
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
    
    // MARK: - UI Components
    
    // Eine Zeile der Playlist: Ordner-Zeile (klick = auf-/zuklappen) oder
    // Titel-Zeile (klick = abspielen). Die Einrueckung folgt der Baumtiefe.
    @ViewBuilder
    func playlistRowView(_ row: PlaylistRow) -> some View {
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
            let fav = isFavorite(fileURL)

            // Zeile = Abspiel-Button (Icon + Titel) + separater Stern-Button
            // (Favorit an/aus), beide auf gemeinsamem Zeilen-Hintergrund. Zwei
            // Geschwister-Buttons statt eines verschachtelten, damit Klick auf
            // den Stern NICHT den Titel startet.
            HStack(spacing: 0) {
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
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .contentShape(Rectangle())
                    .foregroundColor(isPlayingSong ? (theme == .workbench ? .lightAccent : .white) : (theme == .workbench ? .lightTextPrimary : .spaceTextSecondary))
                }
                .buttonStyle(PremiumHoverButtonStyle(theme: theme))

                // Stern: gelb = Favorit, sonst dezent. Immer sichtbar, damit man
                // jeden Titel direkt markieren kann.
                Button(action: { toggleFavorite(fileURL) }) {
                    Image(systemName: fav ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(fav
                                         ? .yellow
                                         : (theme == .workbench ? .lightTextSecondary.opacity(0.5) : .spaceTextSecondary.opacity(0.5)))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(fav ? "Favorit entfernen" : "Als Favorit markieren")
            }
            .background(
                RoundedRectangle(cornerRadius: theme == .workbench ? 0 : 6)
                    .fill(
                        isPlayingSong
                        ? (theme == .workbench ? Color.lightAccent.opacity(0.2) : Color.spaceAccent.opacity(0.15))
                        : Color.clear
                    )
            )
        }
    }

    var playlistSidebar: some View {
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
                    // Umschalter „nur Favoriten": gelber Stern = aktiv.
                    Button(action: { favoritesOnly.toggle() }) {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(favoritesOnly ? .yellow : (theme == .workbench ? .lightAccent : .spaceTextSecondary))
                    }
                    .buttonStyle(PremiumHoverButtonStyle(theme: theme))
                    .help(favoritesOnly ? "Alle Titel zeigen" : "Nur Favoriten zeigen")
                    .padding(.trailing, 4)
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
    
    var instrumentsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let mod = coordinator.activeMod {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(mod.playableInstrumentIndices, id: \.self) { i in
                            if let inst = mod.instruments[i],
                               let previewSample = mod.previewSelection(instrumentIndex: i)?.sample {
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
                                                
                                                if !previewSample.pcm.isEmpty {
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
                                                let lengthRatio = min(1.0, Double(previewSample.pcm.count) / 65536.0)
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
                                            
                                            Text(String(format: "Len: %d B | Fine: %d | Vol: %d", previewSample.pcm.count, previewSample.finetune, previewSample.volume))
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

}
