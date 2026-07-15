import Foundation

// Nur die SwiftUI-App beobachtet diesen Zustand; unter Linux (kein Combine, keine
// GUI) gibt es weder Beobachter noch Nutzen. Der Renderkern in RenderEngine.swift
// schreibt seine VU-/Wave-Daten in rohe Float-Puffer und braucht diese Klasse nicht.
#if canImport(Combine)
import Combine

// Hochfrequenter (30 Hz) Visualisierungs-Zustand — bewusst vom ModPlayerCoordinator
// GETRENNT. Diese Werte (VU-Pegel, Kanal-/Master-Oszilloskope, Spielzeit) setzt der
// VU-Timer 30×/s neu. Lägen sie als @Published direkt auf dem Coordinator, würde
// JEDE Aktualisierung die GESAMTE `MainView.body` (2000+ Zeilen: Playlist, Tracker-
// Grid, Header, Regler …) neu evaluieren — genau das war die Haupt-CPU-Last
// (~80–100 % bei 32-Kanal-XM). Als eigenes ObservableObject beobachten nur die
// Oszilloskop-/VU-/Zeit-Subviews diese Werte; `MainView` selbst rendert dann nur
// noch im Zeilen-Takt (~8 Hz, aus `currentRow`/`currentPosition`) neu.
@MainActor
public final class VisualizerState: ObservableObject {
    // Geglättete VU-Pegel je Kanal (0..1). Länge = Kanalzahl des aktiven Moduls.
    @Published public var vuLevels: [Float] = []
    // Rollende Kanal-Oszilloskope: je Kanal 32 zuletzt ausgegebene Samples.
    @Published public var channelWaveforms: [[Float]] = []
    // Master-Oszilloskop: 128 zuletzt gemischte (L+R)/2-Samples.
    @Published public var masterSamples: [Float] = [Float](repeating: 0, count: 128)
    // Verstrichene Spielzeit / geschätzte Gesamtdauer in Sekunden.
    @Published public var elapsedTime: Double = 0.0
    @Published public var totalDuration: Double = 0.0

    public init() {}

    // Kanal-abhängige Puffer beim Songwechsel passend dimensionieren.
    public func resize(channelCount: Int) {
        vuLevels = [Float](repeating: 0, count: channelCount)
        channelWaveforms = (0..<channelCount).map { _ in [Float](repeating: 0, count: 32) }
    }

    // Signalisiert den beobachtenden Subviews eine Änderung, die nicht über die
    // 30-Hz-Puffer läuft (z.B. Mute/Solo-Umschalten im gestoppten Zustand, wenn der
    // VU-Timer nicht tickt) — sonst aktualisierte sich die Streifen-Optik erst beim
    // nächsten Play.
    public func nudge() {
        objectWillChange.send()
    }
}

// Song-Position (Pattern-Order-Index) und aktuelle Zeile — die zweite hochfrequente
// Achse, ebenfalls vom Coordinator GETRENNT. currentRow ändert sich im Zeilentakt
// (bei schnellen Songs ~20×/s). Lägen die Werte als @Published auf dem Coordinator,
// würde JEDE Zeile die GESAMTE MainView.body neu evaluieren (Sidebar, Header,
// Marker-Map, Regler) — DAS war die eigentliche CPU-Grundlast (2026-07-09, gemessen:
// ~74 % „Floor" auch ohne Grid/Oszilloskope). Nur die wenigen positionsabhängigen
// Subviews (Tracker-Grid, Positions-Slider, PAT-Anzeige, Marker-Map) beobachten
// diesen State; MainView selbst rendert dann nur noch bei seltenen Änderungen
// (Songwechsel, Play/Pause, Theme) neu.
@MainActor
public final class TransportState: ObservableObject {
    @Published public var currentPosition = 0
    @Published public var currentRow = 0
    public init() {}
}

#endif
