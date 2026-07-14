# Ausgelagerte AGENTS-Chronik bis 2026-07-12

Status: historisch, nicht als aktive Anweisung laden. Basis der Auslagerung:
`main@4cdd338`; der vollständige frühere Root-Wortlaut bleibt mit
`git show 4cdd338:AGENTS.md` reproduzierbar.

## Warum ausgelagert

Die frühere Root-`AGENTS.md` wuchs auf 73.594 Byte und wurde vom Projektkontext
nach 32.768 Byte trunkiert. Dadurch fehlten gerade spätere Regeln. Dauerregeln
stehen nun kompakt in `AGENTS.md`; Testdetails in `docs/testing.md`; echte
Restarbeit in `tasks/backlog.md`.

## Abgeschlossene Projektetappen

- Todos 1–24: Repo-/Produktaufbau, HTML-/Swift-Umbenennung, App-/DMG-Skripte,
  Assets, Echtzeit-Oszilloskope, UI/Performance, Tests, README, Crashfixes,
  Playlist/Theme, GitHub-Vorbereitung, Signatur/Notarisierung und Auftritt.
- 2026-06-25 bis 2026-07-02: Parser-/DSP-/UI-Audit, MOD-Parität,
  Multichannel-MOD, Soundtracker-15 und S3M bis Release 1.3.1.
- 2026-07-08: Code-Review-Runde 1.4.2–1.4.4 mit Parser-, DSP-, UI- und
  Buildkorrekturen. Optionale Anti-Click-/JS-Interpolation blieb bewusst offen.
- 2026-07-09: XM M0–M5, strikter Parser, Hüllkurven, Offline-CLI,
  Referenzvergleiche, Effekt-Memory, CPU-/Canvas-Umbau, GUI-/DSP-Fixes und
  Länge-1-Regression. Seltene Amiga-Frequenz/Pxy-Feinheiten blieben optional.
- 2026-07-10 bis 2026-07-11: IT M0–M10 einschließlich IT214/215,
  Instrument-/Samplemodus, 256er-Voice-Pool, NNA/DCT/DCA, Filter, Effekte,
  Quick Look und öffentlicher Integration. Dauerhafte Entscheidungen und
  Messwerte bleiben im abgeschlossenen IT-Task.
- 2026-07-12: UI-Plan 1–10. Light-/Dark-Politur, Transport, Font-Zoom,
  Tooltips, reale IT-Toleranzen und responsiver Compact-Player wurden bis
  1.5.41 abgeschlossen; 1.5.42 synchronisierte das Single-File-HTML.

## Erhaltene Quellen

- Nutzerrelevante Historie: `RELEASE_NOTES.md` und `RELEASE_NOTES.de.md`.
- IT-Architektur, Gates und Capability-Audit:
  `tasks/2026-07-10-it-support/`.
- Linux-Idee: `tasks/2026-07-05-linux-port/plan.md`.
- Aktuelle Restarbeit: `tasks/backlog.md`.
- Test-/Quick-Look-/Notary-Verfahren: `docs/testing.md`.

Veraltete persönliche Fleet-/Hydrierhinweise und absolute lokale Pfade wurden
nicht in dieses öffentliche Archiv kopiert. Sie waren keine Produktregel.
