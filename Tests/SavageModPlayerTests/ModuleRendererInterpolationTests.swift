import XCTest
@testable import SavageModPlayerCore

/// Beweist, dass die Interpolationswahl bis in den echten Offline-Renderer
/// gelangt. Das synthetische Modul braucht weder Testdatei noch Audiogeraet.
final class ModuleRendererInterpolationTests: XCTestCase {

    // Ein nicht konstantes Loop-Sample und die gebrochene Abspielposition der
    // MOD-Periode sorgen dafuer, dass linear und nearest verschieden klingen.
    private func makeInterpolationMod() -> Mod {
        let bytes: [Int8] = [0, 120, -96, 72, -48, 104, -80, 40]
        let instrument = Instrument(
            index: 1,
            name: "Interpolation",
            length: bytes.count,
            finetune: 0,
            volume: 64,
            repeatOffset: 0,
            repeatLength: bytes.count,
            bytes: bytes,
            isLooped: true
        )
        let note = Note(instrument: 1, period: 428, effectId: 0, effectData: 0)
        let pattern = Pattern(rows: [Row(notes: [note])])
        return Mod(
            name: "interpolation",
            length: 1,
            patternTable: [0],
            instruments: [nil, instrument],
            patterns: [pattern],
            channelCount: 1
        )
    }

    private func pcmPeak(_ wav: Data) -> Int {
        guard wav.count > 45 else { return 0 }
        var peak = 0
        for offset in stride(from: 44, to: wav.count - 1, by: 2) {
            let bits = UInt16(wav[offset]) | (UInt16(wav[offset + 1]) << 8)
            peak = max(peak, abs(Int(Int16(bitPattern: bits))))
        }
        return peak
    }

    func testRenderWavInterpolationOptionChangesRawPCM() throws {
        let mod = makeInterpolationMod()
        let defaultWav = try ModuleRenderer.renderWavData(
            mod: mod, maxDurationSeconds: 0.02, normalize: false)
        let interpolatedWav = try ModuleRenderer.renderWavData(
            mod: mod, maxDurationSeconds: 0.02, normalize: false,
            useInterpolation: true)
        let nearestWav = try ModuleRenderer.renderWavData(
            mod: mod, maxDurationSeconds: 0.02, normalize: false,
            useInterpolation: false)

        XCTAssertEqual(defaultWav, interpolatedWav,
                       "Der Default muss Quick Looks bisherige Interpolation bewahren")
        XCTAssertEqual(nearestWav.count, interpolatedWav.count,
                       "Die Interpolation darf die Renderlaenge nicht veraendern")
        XCTAssertGreaterThan(pcmPeak(nearestWav), 100,
                             "Auch nearest muss hoerbares PCM rendern")
        XCTAssertNotEqual(nearestWav.dropFirst(44), interpolatedWav.dropFirst(44),
                          "--no-interp muss den PCM-Payload tatsaechlich veraendern")
    }
}
