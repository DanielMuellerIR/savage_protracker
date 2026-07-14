# Aktiver Projekt-Backlog

Stand: 2026-07-14 · Basis: `main@4cdd338`, Version 1.5.42.

Diese Datei ist die einzige aktive Projektliste. Erledigte Chronik liegt in
Release Notes, abgeschlossenen Tasks und `archive/`.

## Priorisiert

1. **GUI-Smoke für Dateiargument untersuchen.** Ein früherer Lauf mit
   `open --args <mod>` zeigte kein Hauptfenster, während der Autoplay-Ordnerpfad
   funktionierte. Mit einer rechtlich unbedenklichen lokalen Datei reproduzieren,
   App-Lifecycle und Argumentdispatch trennen, headless Tests ergänzen und danach
   einen freigegebenen GUI-Smoke durchführen.
2. **Visualizer-Bildrate als Opt-in-Einstellung.** Default bleibt 30 Hz und damit
   volle Optik. Optionen etwa 30/24/15/10 Hz speisen den Full-Mode-
   `vuUpdateInterval`; CPU-Gewinn auf demselben Host/Modul vor und nach der
   Änderung messen. Compact bleibt 5 Hz.

## Optionaler Feinschliff

- **Full-Mode-`@Published`-Churn:** Erst messen, dann gegebenenfalls Uhr und
  Visualizer-Datenpfad trennen. Ziel 2–4 % Gewinn ohne reduzierte 30-Hz-Optik;
  keine spekulative Audio-DSP-Optimierung, weil diese nur etwa 3–4 % ausmachte.
- **Seltene XM-Semantik:** echte Amiga-Periodentabelle für XM mit `flags bit0=0`
  und Pxy-Effekt-Memory. Mit synthetischen Tests plus lokalem XM-Korpus absichern;
  lineare XM und bestehende Effect-Memory-Regeln dürfen nicht regressieren.
- **Audioqualität:** optionale Anti-Click-Hüllkurve und JavaScript-
  Sampleinterpolation nur mit hörbarem A/B-, Timing- und Swift-Paritätsnachweis.
- **Linux-Port:** getrenntes Vorhaben gemäß
  [2026-07-05-linux-port/plan.md](2026-07-05-linux-port/plan.md); keine
  Nebenbei-Portierung im macOS-/Quick-Look-Scope.

## Nicht offen

Compact-Header/Layout, UI-Plan 1–10, IT M0–M10, Capability-Härtung und Release
1.5.42 sind abgeschlossen. Historische Start-/Branch-Anweisungen im IT-Task sind
superseded und kein Auftrag für eine neue Session.

