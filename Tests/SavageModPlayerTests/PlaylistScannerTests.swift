import XCTest
@testable import SavageModPlayerCore

// Tests fuer den Playlist-Scanner: Hierarchie-Erfassung beim Einsammeln,
// Baum-Aufbau/Sortierung, flache Abspiel-Reihenfolge und das unsichtbare
// Entpacken von Zip-/7z-Archiven (via System-bsdtar).
final class PlaylistScannerTests: XCTestCase {

    // Frisches Arbeitsverzeichnis pro Test; wird in tearDown geloescht.
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PlaylistScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeFile(_ relativePath: String) throws -> URL {
        let url = workDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x78]).write(to: url)
        return url
    }

    private var tempDir: URL {
        workDir.appendingPathComponent("scan-temp", isDirectory: true)
    }

    // MARK: - Einsammeln mit Hierarchie

    func testCollectEntriesKeepsFolderHierarchy() throws {
        _ = try makeFile("root.mod")
        _ = try makeFile("Chiptunes/tune.mod")
        _ = try makeFile("Chiptunes/Deep/nested.s3m")
        _ = try makeFile("Chiptunes/notes.txt") // kein Mod — muss ignoriert werden

        let entries = PlaylistScanner.collectEntries(from: [workDir], tempDir: tempDir)

        XCTAssertEqual(entries.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.displayName, $0.folderPath) })
        XCTAssertEqual(byName["root.mod"], [])
        XCTAssertEqual(byName["tune.mod"], ["Chiptunes"])
        XCTAssertEqual(byName["nested.s3m"], ["Chiptunes", "Deep"])
        // Kopien liegen im Temp-Ziel, nicht im Quellordner.
        for entry in entries {
            XCTAssertTrue(entry.url.path.hasPrefix(tempDir.path))
        }
    }

    // MARK: - Baum & flache Reihenfolge

    func testBuildTreeSortsAndFlattenMatchesDisplayOrder() throws {
        func entry(_ name: String, _ path: [String]) -> PlaylistScanner.Entry {
            PlaylistScanner.Entry(url: URL(fileURLWithPath: "/x/\(path.joined(separator: "_"))_\(name)"),
                                  displayName: name, folderPath: path)
        }
        let entries = [
            entry("zzz.mod", []),
            entry("b.mod", ["Beta"]),
            entry("a2.mod", ["Alpha"]),
            entry("a10.mod", ["Alpha"]),
            entry("deep.mod", ["Alpha", "Inner"]),
        ]
        let tree = PlaylistScanner.buildTree(entries)

        // Ebene 1: Ordner alphabetisch, Dateien danach.
        XCTAssertEqual(tree.subfolders.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(tree.files.map(\.displayName), ["zzz.mod"])
        // Numerisch-natuerliche Sortierung innerhalb eines Ordners (a2 vor a10).
        XCTAssertEqual(tree.subfolders[0].files.map(\.displayName), ["a2.mod", "a10.mod"])
        // Pfad-IDs sind die "/"-verbundenen Komponenten.
        XCTAssertEqual(tree.subfolders[0].subfolders[0].path, "Alpha/Inner")

        // Flache Abspiel-Reihenfolge = Tiefensuche in Anzeige-Reihenfolge:
        // Alpha/Inner/deep, Alpha/a2, Alpha/a10, Beta/b, dann Wurzel-Dateien.
        let flat = PlaylistScanner.flattenedFiles(tree).map(\.displayName)
        XCTAssertEqual(flat, ["deep.mod", "a2.mod", "a10.mod", "b.mod", "zzz.mod"])
    }

    // MARK: - Archive

    // Beide Fixtures enthalten: Coolpack/alpha.mod, Coolpack/sub/beta.mod,
    // Coolpack/readme.txt (Nicht-Mod, muss ignoriert werden).
    private static let zipFixtureBase64 = "UEsDBAoAAAAAABF95VwAAAAAAAAAAAAAAAAJABwAQ29vbHBhY2svVVQJAAPSXkpq0l5KanV4CwABBPUBAAAEAAAAAFBLAwQKAAAAAAARfeVcAAAAAAAAAAAAAAAADQAcAENvb2xwYWNrL3N1Yi9VVAkAA9JeSmrSXkpqdXgLAAEE9QEAAAQAAAAAUEsDBAoAAAAAABF95VyDFtyMAQAAAAEAAAAVABwAQ29vbHBhY2svc3ViL2JldGEubW9kVVQJAAPSXkpq0l5KanV4CwABBPUBAAAEAAAAAHhQSwMECgAAAAAAEX3lXIMW3IwBAAAAAQAAABMAHABDb29scGFjay9yZWFkbWUudHh0VVQJAAPSXkpq0l5KanV4CwABBPUBAAAEAAAAAHhQSwMECgAAAAAAEX3lXIMW3IwBAAAAAQAAABIAHABDb29scGFjay9hbHBoYS5tb2RVVAkAA9JeSmrSXkpqdXgLAAEE9QEAAAQAAAAAeFBLAQIeAwoAAAAAABF95VwAAAAAAAAAAAAAAAAJABgAAAAAAAAAEADtQQAAAABDb29scGFjay9VVAUAA9JeSmp1eAsAAQT1AQAABAAAAABQSwECHgMKAAAAAAARfeVcAAAAAAAAAAAAAAAADQAYAAAAAAAAABAA7UFDAAAAQ29vbHBhY2svc3ViL1VUBQAD0l5KanV4CwABBPUBAAAEAAAAAFBLAQIeAwoAAAAAABF95VyDFtyMAQAAAAEAAAAVABgAAAAAAAEAAACkgYoAAABDb29scGFjay9zdWIvYmV0YS5tb2RVVAUAA9JeSmp1eAsAAQT1AQAABAAAAABQSwECHgMKAAAAAAARfeVcgxbcjAEAAAABAAAAEwAYAAAAAAABAAAApIHaAAAAQ29vbHBhY2svcmVhZG1lLnR4dFVUBQAD0l5KanV4CwABBPUBAAAEAAAAAFBLAQIeAwoAAAAAABF95VyDFtyMAQAAAAEAAAASABgAAAAAAAEAAACkgSgBAABDb29scGFjay9hbHBoYS5tb2RVVAUAA9JeSmp1eAsAAQT1AQAABAAAAABQSwUGAAAAAAUABQCuAQAAdQEAAAAA"
    private static let sevenZipFixtureBase64 = "N3q8ryccAATZ8ns+mQAAAAAAAAAiAAAAAAAAAKxU7hQBAAJ4eHgAAACBMweuD84lflFCynNIGZqoUZTnWFv8ZmYGcG13U53ZggeBDAzB8o5I0anqwxnW/rhjcps9sIvSAoEiOVrO6+r7ZZVEQtnNAcSLzgb6BFxP+wgEOb4uJbOflweo3aMUoAy0Z7Bg1mOI5QcyHrl3sDtLu/afdnufYpe2vkwzcjoasFLGjLA8Fy+v6omM20gAAAAXBgcBCYCSAAcLAQABIwMBAQVdABAAAAyBMgoB+cP6zwAA"

    private func runArchiveTest(base64: String, filename: String) throws {
        let archiveURL = workDir.appendingPathComponent(filename)
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: archiveURL)

        let entries = PlaylistScanner.collectEntries(from: [archiveURL], tempDir: tempDir)

        // Das Archiv erscheint als Ordner-Komponente OHNE Endung ("fixture"),
        // sein Innenleben als normale Hierarchie; readme.txt bleibt aussen vor.
        XCTAssertEqual(entries.count, 2, "erwartet alpha.mod + beta.mod aus \(filename)")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.displayName, $0.folderPath) })
        let archiveNode = (filename as NSString).deletingPathExtension
        XCTAssertEqual(byName["alpha.mod"], [archiveNode, "Coolpack"])
        XCTAssertEqual(byName["beta.mod"], [archiveNode, "Coolpack", "sub"])
    }

    func testZipArchiveIsScannedLikeAFolder() throws {
        try runArchiveTest(base64: Self.zipFixtureBase64, filename: "fixture.zip")
    }

    func test7zArchiveIsScannedLikeAFolder() throws {
        try runArchiveTest(base64: Self.sevenZipFixtureBase64, filename: "fixture.7z")
    }

    func testCorruptArchiveIsSkippedWithoutEntries() throws {
        let archiveURL = workDir.appendingPathComponent("broken.zip")
        try Data("kein echtes archiv".utf8).write(to: archiveURL)
        let entries = PlaylistScanner.collectEntries(from: [archiveURL], tempDir: tempDir)
        XCTAssertTrue(entries.isEmpty)
    }

    func testDirectoryContainsPlayableContentSeesModsAndArchives() throws {
        _ = try makeFile("Leer/nur-text.txt")
        XCTAssertFalse(PlaylistScanner.directoryContainsPlayableContent(workDir.appendingPathComponent("Leer")))
        _ = try makeFile("MitMod/deep/song.mod")
        XCTAssertTrue(PlaylistScanner.directoryContainsPlayableContent(workDir.appendingPathComponent("MitMod")))
    }
}
