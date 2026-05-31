// ─────────────────────────────────────────────────────────────────────────────
// App-Logik des Standalone-ProTracker-Players.
//
// Dieses Skript wird im finalen Single-File-Build inline ins <script>-Tag
// eingebettet. Es setzt voraus, dass folgende Symbole bereits im selben
// Scope existieren (vom Build-Skript davor injiziert):
//
//   - parseModBuffer(buffer, label)   ← aus modplayer.js
//   - ModPlayer                       ← Klasse aus modplayer.js
//   - WORKLET_BLOB_URL                ← Blob-URL des AudioWorklet-Quelltexts
//
// Aufbau:
//   1. Hilfsfunktionen für Note-Namen und Hex-Formatierung.
//   2. DOM-Refs (alle IDs aus body.html).
//   3. State (aktuell geladenes Mod, aktuelle Position/Zeile, VU-Pegel).
//   4. Event-Wiring (File-Picker, Folder-Picker, Mod-Dropdown, Volume, Play).
//   5. Drag & Drop inklusive Ordner-Traversal.
//   6. File-Laden + Rendering von Tracker und Instrument-Liste.
//   7. VU-Meter-Loop via requestAnimationFrame.
// ─────────────────────────────────────────────────────────────────────────────

// ─── 1. Note-Namen / Hex-Formatierung ────────────────────────────────────────

// Amiga-Period-Tabelle: jeweils 12 Halbtöne pro Oktave, 4 Oktaven.
// Index → Notenname. Die Werte sind die rohen Period-Zahlen, die der
// Paula-Chip benutzt. Niedrigere Period = höhere Tonhöhe.
const PERIODS = [
  856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
  428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
  214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
  107, 101,  95,  90,  85,  80,  75,  71,  67,  63,  60,  56
];
const NOTE_NAMES = [
  'C-1', 'C#1', 'D-1', 'D#1', 'E-1', 'F-1', 'F#1', 'G-1', 'G#1', 'A-1', 'A#1', 'B-1',
  'C-2', 'C#2', 'D-2', 'D#2', 'E-2', 'F-2', 'F#2', 'G-2', 'G#2', 'A-2', 'A#2', 'B-2',
  'C-3', 'C#3', 'D-3', 'D#3', 'E-3', 'F-3', 'F#3', 'G-3', 'G#3', 'A-3', 'A#3', 'B-3',
  'C-4', 'C#4', 'D-4', 'D#4', 'E-4', 'F-4', 'F#4', 'G-4', 'G#4', 'A-4', 'A#4', 'B-4'
];

// Sucht den nächstgelegenen Eintrag in PERIODS und gibt den passenden
// Notennamen zurück. Toleranz: 30 Period-Einheiten (sonst "---").
function getNoteName(period) {
  if (period <= 0) return '---';
  let bestIdx = -1, bestDiff = 999999;
  for (let i = 0; i < PERIODS.length; i++) {
    const diff = Math.abs(PERIODS[i] - period);
    if (diff < bestDiff) { bestDiff = diff; bestIdx = i; }
  }
  return (bestIdx !== -1 && bestDiff < 30) ? NOTE_NAMES[bestIdx] : '---';
}

const fmtHex = (n, w) => n.toString(16).toUpperCase().padStart(w, '0');
const fmtInst = (note) => note.instrument === 0 ? '--' : fmtHex(note.instrument, 2);
const fmtFx = (note) => note.rawEffect === 0 ? '000' : fmtHex(note.rawEffect, 3);

// ─── 2. DOM-Refs ─────────────────────────────────────────────────────────────

const $ = (id) => document.getElementById(id);
const playerEl = $('player');
const playBtn = $('play-btn');
const fileInput = $('file-input');
const folderInput = $('folder-input');
const modSelect = $('mod-select');
const volumeSlider = $('volume');
const titleEl = $('title-name');
const rowsContainer = $('rows');
const instList = $('instruments');
const posDisplay = $('pos-display');
const statusRow = $('status-row');
const statusState = $('status-state');
const statusBpm = $('status-bpm');
const statusSpeed = $('status-speed');
const statusName = $('status-name');
const statusFile = $('status-file');
const footerState = $('footer-state');
const vuBars = [0, 1, 2, 3].map(i => $(`vu-${i}`));
const positionScrubber = $('position-scrubber');
const playlistLabel = $('playlist-label');
const playlistMode = $('playlist-mode');
const dragHint = $('drag-hint');
const themeBtn = $('theme-btn');

// ─── 3. State ────────────────────────────────────────────────────────────────

const player = new ModPlayer();
let currentMod = null;
let currentFilename = '';
let currentPosition = 0;
let lastPosition = 0;
let previousVolume = 1.0;
let currentRow = 0;
let activeRowEl = null;
let rowHeight = 15;
let containerHeight = 200;
// vuLevels = das, was tatsächlich gezeichnet wird (geglättet).
// vuTargets = der letzte rohe Peak-Wert aus dem Worklet (kommt ~47x/sec).
// Der rAF-Loop bewegt vuLevels zeitlich gedämpft Richtung vuTargets.
const vuLevels = [0, 0, 0, 0];
const vuTargets = [0, 0, 0, 0];

// Initial-Volume aus dem Slider lesen (Default in body.html ist 1 = max).
player.setVolume(Number(volumeSlider.value));

// ─── 4. Event-Wiring ─────────────────────────────────────────────────────────

fileInput.addEventListener('change', (e) => {
  player.resumeContext();
  const file = e.target.files[0];
  if (file) {
    addMods([file]);
    loadFile(file);
  }
});

// Ordner-Picker: alle .mod-Dateien aus dem gewählten Verzeichnis sammeln,
// erste laden, Rest landet im Dropdown. Browser darf nicht von sich aus
// scannen — die User-Geste durch den Picker ist Pflicht.
folderInput.addEventListener('change', (e) => {
  player.resumeContext();
  const all = Array.from(e.target.files || []);
  const mods = all.filter(f => isModName(f.name));
  if (!mods.length) {
    showError('Keine .mod-Dateien im Ordner gefunden.');
    return;
  }
  addMods(mods);
  loadFile(mods[0]);
});

volumeSlider.addEventListener('input', (e) => {
  player.setVolume(Number(e.target.value));
});

playBtn.addEventListener('click', async () => {
  if (!currentMod) return;
  if (player.playing) {
    player.stop();
    setPlayingUI(false);
  } else {
    try {
      player.resumeContext();
      const startPos = currentPosition;
      lastPosition = startPos; // Letzte Position vor Wiedergabe zurücksetzen
      await player.play();
      // Beim Starten direkt auf die aktuelle Slider-Position springen
      player.setPosition(startPos, 0);
      setPlayingUI(true);
    } catch (err) {
      console.error('play() fehlgeschlagen:', err);
      showError('Wiedergabe fehlgeschlagen: ' + err.message);
    }
  }
});

// Drag/Klick auf der Timeline setzt die Song-Position (Pattern)
positionScrubber.addEventListener('input', (e) => {
  if (!currentMod) return;
  const pos = Number(e.target.value);
  player.setPosition(pos, 0);
  currentPosition = pos;
  lastPosition = pos; // Springen aktualisiert letzte bekannte Position
  currentRow = 0; // Springen setzt Zeile auf 0 zurück
  renderPattern();
  posDisplay.textContent = `POS: ${String(pos + 1).padStart(2, '0')}/${String(currentMod.length).padStart(2, '0')}`;
  statusRow.textContent = `00/63`;
});

// ─── Mod-Liste / Dropdown ────────────────────────────────────────────────────

// Sammelt alle vom Nutzer gelieferten MOD-Dateien (Picker, Folder, Drop)
// und füllt das Dropdown. Browser darf das aktuelle Verzeichnis NICHT
// von sich aus scannen — User-Geste ist Pflicht (Datei-Dialog, Drop, ...).
const modList = []; // Einträge: { name, file }

// Erkennt sowohl moderne *.mod-Endungen als auch klassische Amiga-
// Namen wie "mod.songname" (Präfix-Konvention ohne Endung).
function isModName(name) {
  const n = name.toLowerCase();
  return n.endsWith('.mod') || n.startsWith('mod.');
}

function addMods(files) {
  let added = 0;
  for (const f of files) {
    if (!isModName(f.name)) continue;
    // Duplikate (gleicher Name + gleiche Größe) überspringen.
    if (modList.some(m => m.name === f.name && m.file.size === f.size)) continue;
    modList.push({ name: f.name, file: f });
    added++;
  }
  if (added) refreshModSelect();
}

function refreshModSelect() {
  modList.sort((a, b) => a.name.localeCompare(b.name));
  modSelect.innerHTML = '';
  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = `— ${modList.length} MOD${modList.length === 1 ? '' : 's'} —`;
  modSelect.appendChild(placeholder);
  modList.forEach((m, i) => {
    const o = document.createElement('option');
    o.value = String(i);
    o.textContent = m.name;
    modSelect.appendChild(o);
  });
  const hasMods = modList.length > 0;
  modSelect.style.display = hasMods ? '' : 'none';
  playlistLabel.style.display = hasMods ? '' : 'none';
  dragHint.style.display = hasMods ? 'none' : '';
}

modSelect.addEventListener('change', (e) => {
  player.resumeContext();
  const v = e.target.value;
  if (v === '') return;
  const idx = Number(v);
  const entry = modList[idx];
  if (entry) loadFile(entry.file);
});

// Markiert den aktuell geladenen Eintrag im Dropdown (per Name+Size-Match).
function syncModSelectSelection(file) {
  const idx = modList.findIndex(m => m.name === file.name && m.file.size === file.size);
  if (idx >= 0) modSelect.value = String(idx);
}

// ─── Tastatur-Shortcuts ────────────────────────────────────────────────────────
window.addEventListener('keydown', (e) => {
  if (document.activeElement && (
      document.activeElement.tagName === 'INPUT' && document.activeElement.type !== 'range' && document.activeElement.type !== 'checkbox' ||
      document.activeElement.tagName === 'SELECT')) {
    return;
  }

  const key = e.key.toLowerCase();

  // Space -> Play/Stop
  if (e.key === ' ' || e.key === 'Spacebar') {
    e.preventDefault();
    if (playBtn && !playBtn.disabled) playBtn.click();
  }

  // M -> Mute/Unmute
  if (key === 'm') {
    e.preventDefault();
    const curVol = Number(volumeSlider.value);
    if (curVol > 0) {
      previousVolume = curVol;
      volumeSlider.value = 0;
      player.setVolume(0);
    } else {
      volumeSlider.value = previousVolume;
      player.setVolume(previousVolume);
    }
  }

  // Pfeiltasten Links/Rechts -> Position springen
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    e.preventDefault();
    if (!currentMod) return;
    const dir = e.key === 'ArrowLeft' ? -1 : 1;
    const newPos = Math.max(0, Math.min(currentMod.length - 1, currentPosition + dir));
    if (newPos !== currentPosition) {
      player.setPosition(newPos, 0);
      currentPosition = newPos;
      lastPosition = newPos;
      currentRow = 0;
      positionScrubber.value = String(newPos);
      renderPattern();
      posDisplay.textContent = `POS: ${String(newPos + 1).padStart(2, '0')}/${String(currentMod.length).padStart(2, '0')}`;
      statusRow.textContent = `00/63`;
    }
  }

  // Pfeiltasten Oben/Unten -> Vorheriger/Nächster Song
  if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    e.preventDefault();
    if (modList.length <= 1) return;
    player.resumeContext();
    const currentIdx = modList.findIndex(m => m.name === currentFilename);
    if (currentIdx >= 0) {
      const dir = e.key === 'ArrowUp' ? -1 : 1;
      const nextIdx = (currentIdx + dir + modList.length) % modList.length;
      loadFile(modList[nextIdx].file);
    }
  }
});

// ─── 5. Drag & Drop ──────────────────────────────────────────────────────────

// dragenter und dragover müssen preventDefault aufrufen, damit drop
// überhaupt feuert. dragDepth zählt die Verschachtelungstiefe der
// dragenter/dragleave-Events, damit das Overlay nicht flackert, wenn
// die Maus über innere Elemente fährt.
let dragDepth = 0;
window.addEventListener('dragenter', (e) => {
  e.preventDefault();
  dragDepth++;
  playerEl.classList.add('drag-over');
});
window.addEventListener('dragover', (e) => {
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
});
window.addEventListener('dragleave', (e) => {
  e.preventDefault();
  dragDepth--;
  if (dragDepth <= 0) {
    dragDepth = 0;
    playerEl.classList.remove('drag-over');
  }
});
window.addEventListener('drop', async (e) => {
  e.preventDefault();
  player.resumeContext();
  dragDepth = 0;
  playerEl.classList.remove('drag-over');
  try {
    const files = await collectDroppedFiles(e.dataTransfer);
    const mods = files.filter(f => isModName(f.name));
    if (!mods.length) {
      if (files.length) showError('Keine .mod-Dateien im Drop gefunden.');
      return;
    }
    addMods(mods);
    loadFile(mods[0]);
  } catch (err) {
    console.error('Drop-Verarbeitung fehlgeschlagen:', err);
    // Fallback: nur direkt gedroppte Files nehmen (z. B. wenn
    // webkitGetAsEntry fehlt). Ordner werden dabei ignoriert.
    const file = e.dataTransfer.files && e.dataTransfer.files[0];
    if (file) {
      addMods([file]);
      loadFile(file);
    }
  }
});

// Sammelt alle Files aus einem DataTransfer — inklusive Ordner (rekursiv).
// Browser-API: DataTransferItem.webkitGetAsEntry() liefert FileEntry oder
// DirectoryEntry. Ordner werden via DirectoryReader.readEntries()
// durchlaufen, das in Batches liefert (deshalb die while-Schleife).
async function collectDroppedFiles(dt) {
  const out = [];
  const items = dt.items;
  if (items && items.length && typeof items[0].webkitGetAsEntry === 'function') {
    const entries = [];
    for (const item of items) {
      const entry = item.webkitGetAsEntry();
      if (entry) entries.push(entry);
    }
    for (const entry of entries) await walkEntry(entry, out);
    return out;
  }
  // Fallback: API fehlt → nur direkt gedroppte Dateien, keine Ordner.
  for (const f of dt.files) out.push(f);
  return out;
}

async function walkEntry(entry, out) {
  if (entry.isFile) {
    const file = await new Promise((res, rej) => entry.file(res, rej));
    out.push(file);
    return;
  }
  if (entry.isDirectory) {
    const reader = entry.createReader();
    while (true) {
      const batch = await new Promise((res, rej) => reader.readEntries(res, rej));
      if (!batch.length) break;
      for (const child of batch) await walkEntry(child, out);
    }
  }
}

// ─── 6. File-Laden + Rendering ───────────────────────────────────────────────

async function loadFile(file) {
  try {
    const buf = await file.arrayBuffer();
    const mod = parseModBuffer(buf, file.name);
    player.stop();
    player.setMod(mod, WORKLET_BLOB_URL);
    setUpPlayerCallbacks();
    currentMod = mod;
    currentFilename = file.name;
    currentPosition = 0;
    lastPosition = 0;
    currentRow = 0;
    // Titelleiste zeigt jetzt den Dateinamen.
    titleEl.textContent = file.name;
    statusName.textContent = mod.name || '(unbenannt)';
    statusFile.title = file.name;
    statusFile.textContent = file.name;
    playBtn.disabled = false;
    syncModSelectSelection(file);
    renderInstruments();
    renderPattern();
    
    // Scrubber initialisieren und freischalten
    positionScrubber.max = mod.length - 1;
    positionScrubber.value = 0;
    positionScrubber.disabled = false;
    
    // Direkt abspielen (User-Geste durch File-Picker/Drop ist gerade aktiv).
    player.resumeContext();
    await player.play();
    setPlayingUI(true);
  } catch (err) {
    console.error('loadFile fehlgeschlagen:', err);
    showError('Fehler beim Laden: ' + err.message);
  }
}

function showError(msg) {
  rowsContainer.innerHTML = `<div class="error">${msg}</div>`;
}

function setPlayingUI(isPlaying) {
  playBtn.textContent = isPlaying ? 'STOP' : 'PLAY AUDIO';
  statusState.textContent = isPlaying ? 'PLAYING' : 'STOPPED';
  statusState.style.color = isPlaying ? '#008800' : '#888';
  footerState.textContent = isPlaying ? '▶ ACTIVE' : '■ IDLE';
  footerState.style.color = isPlaying ? '#008800' : '#888';
  
  if (!isPlaying) {
    statusBpm.textContent = '---';
    statusSpeed.textContent = '---';
  }
}

// Verbindet die Worklet-Events mit der UI:
//   watchRows   → Tracker-Spur scrollt, Position/Row-Anzeige aktualisiert.
//   watchLevels → echtes VU-Pegel-Array je Kanal aus dem Worklet.
//   watchStop   → UI in STOPPED-Status zurück.
function setUpPlayerCallbacks() {
  player.watchRows((pos, row, bpm, speed) => {
    const totalPatterns = currentMod?.length || 1;
    // Heuristik: wenn die Position rückwärts springt oder ein
    // Single-Pattern-Mod den Anfang erneut erreicht, gilt das als Ende.
    if (pos < lastPosition || (totalPatterns === 1 && row === 0 && currentRow === 63)) {
      player.stop();
      setPlayingUI(false);
      
      // Playlist Auto-Next Logik
      if (playlistMode && playlistMode.checked && modList.length > 1) {
        let nextIdx = 0;
        const currentIdx = modList.findIndex(m => m.name === currentFilename);
        if (currentIdx >= 0) {
          nextIdx = (currentIdx + 1) % modList.length;
        }
        const entry = modList[nextIdx];
        if (entry) {
          loadFile(entry.file);
          return;
        }
      }

      // Am Songende auf Anfang zurücksetzen
      currentPosition = 0;
      lastPosition = 0;
      currentRow = 0;
      positionScrubber.value = "0";
      renderPattern();
      return;
    }
    lastPosition = pos;
    currentRow = row;
    if (currentPosition !== pos) {
      currentPosition = pos;
      renderPattern();
      // Scrubber-Position synchronisieren
      positionScrubber.value = String(pos);
    } else {
      updateActiveRow(row);
    }
    statusRow.textContent = `${row.toString().padStart(2, '0')}/63`;
    posDisplay.textContent = `POS: ${String(pos + 1).padStart(2, '0')}/${String(currentMod.length).padStart(2, '0')}`;
    
    // BPM und Speed aktualisieren
    statusBpm.textContent = bpm ? String(bpm) : '---';
    statusSpeed.textContent = speed ? String(speed) : '---';
  });
  // VU-Pegel direkt aus dem Worklet: peaks ist [p0,p1,p2,p3], jeweils
  // |max| des Channel-Outputs seit dem letzten Post (~47x pro Sekunde).
  // Maximum-Skala: Channel.nextOutput() liefert int8-Samples
  // skaliert auf ±0.5 — deshalb das *2 fürs Mapping nach 0..1.
  //
  // Wir schreiben hier nur den rohen Zielwert in vuTargets[]. Die
  // eigentliche Glättung (asymmetrische EMA) macht der rAF-Loop, damit
  // schnelle Block-zu-Block-Schwankungen nicht als Flimmern sichtbar
  // werden.
  player.watchLevels((peaks) => {
    for (let i = 0; i < 4; i++) {
      vuTargets[i] = Math.min(1, peaks[i] * 2);
    }
  });
  player.watchStop(() => setPlayingUI(false));
}

function renderInstruments() {
  instList.innerHTML = '';
  if (!currentMod) return;
  // Index 0 ist im Mod leer (Instrumente werden ab 1 referenziert).
  currentMod.instruments.slice(1).forEach((inst, idx) => {
    const num = (idx + 1).toString(16).toUpperCase().padStart(2, '0');
    const name = inst ? inst.name : '';
    const div = document.createElement('div');
    div.className = 'inst-row';
    if (!name) div.classList.add('empty');
    div.innerHTML = `<span class="inst-num">${num}</span><span class="inst-name" title="${name}">${name || '---'}</span>`;
    instList.appendChild(div);
  });
}

function renderPattern() {
  if (!currentMod) return;
  const patternIdx = currentPosition < currentMod.patternTable.length ? currentMod.patternTable[currentPosition] : 0;
  const pattern = patternIdx < currentMod.patterns.length ? currentMod.patterns[patternIdx] : null;
  if (!pattern) {
    rowsContainer.innerHTML = '<div class="empty-rows">NO SEQUENCE DATA</div>';
    return;
  }
  // String-Concat per Array.join() — schneller als wiederholtes innerHTML+=.
  const parts = [];
  pattern.rows.forEach((row, absoluteRow) => {
    const isActive = absoluteRow === currentRow;
    parts.push(`<div class="mod-row" data-row-idx="${absoluteRow}" data-active="${isActive}"><span class="mod-row-idx">${fmtHex(absoluteRow, 2)}</span>`);
    row.notes.forEach((note) => {
      const noteName = getNoteName(note.period);
      const inst = fmtInst(note);
      const fx = fmtFx(note);
      const hasNote = noteName !== '---';
      const hasInst = inst !== '--';
      const hasFx = fx !== '000';
      parts.push(`<span class="mod-note-block${hasNote ? ' has-note' : ''}"><span class="mod-note-name">${noteName}</span> <span class="mod-inst${hasInst ? ' has-inst' : ''}">${inst}</span> <span class="mod-fx${hasFx ? ' has-fx' : ''}">${fx}</span></span>`);
    });
    parts.push('</div>');
  });
  rowsContainer.innerHTML = parts.join('');
  const firstRow = rowsContainer.querySelector('.mod-row');
  if (firstRow) {
    rowHeight = firstRow.clientHeight || 15;
    containerHeight = rowsContainer.clientHeight || 200;
  }
  activeRowEl = rowsContainer.querySelector('[data-active="true"]');
  scrollToActiveRow();
}

function updateActiveRow(row) {
  if (activeRowEl) activeRowEl.setAttribute('data-active', 'false');
  const next = rowsContainer.querySelector(`[data-row-idx="${row}"]`);
  if (next) {
    next.setAttribute('data-active', 'true');
    activeRowEl = next;
    scrollToActiveRow();
  }
}

function scrollToActiveRow() {
  if (!activeRowEl) return;
  const containerH = rowsContainer.clientHeight || 200;
  const rowTop = currentRow * rowHeight;
  rowsContainer.scrollTop = rowTop - (containerH / 2) + (rowHeight / 2);
}

// ─── 7. VU-Meter-Loop ────────────────────────────────────────────────────────

// Ein einziger requestAnimationFrame-Loop für alle 4 Meter.
//
// Zeitliche Glättung: asymmetrische exponentielle Mittelung.
//   - Attack (Anstieg)  schnell, damit das Meter Peaks erkennt.
//   - Release (Abfall)  langsam, damit das Auge sanftem Fall folgt.
// Faktoren in der Größenordnung „pro Frame bei ~60 fps":
//   ATTACK  = 0.35  → ~75 % Rise nach ~4 Frames (~66 ms).
//   RELEASE = 0.08  → halbiert sich in ~8 Frames (~130 ms).
// Werte bewusst konservativ — zu hohe Attack/Release-Werte führen
// wieder zum Flimmern, zu niedrige machen das Meter träge.
const VU_ATTACK = 0.35;
const VU_RELEASE = 0.08;

function tickVU() {
  for (let i = 0; i < 4; i++) {
    const target = vuTargets[i];
    const cur = vuLevels[i];
    // a = Geschwindigkeit, mit der wir uns dem Ziel nähern.
    const a = target > cur ? VU_ATTACK : VU_RELEASE;
    vuLevels[i] = cur + (target - cur) * a;

    const pct = Math.max(2, Math.round(vuLevels[i] * 100));
    const bar = vuBars[i];
    if (bar) {
      const h = `${pct}%`;
      // Nur schreiben, wenn sich was geändert hat — vermeidet Reflows.
      if (bar.style.height !== h) bar.style.height = h;
    }
  }
  requestAnimationFrame(tickVU);
}
requestAnimationFrame(tickVU);

// ─── Theme-Toggle (Dark vs Light Look) ────────────────────────────────────────
if (themeBtn) {
  themeBtn.addEventListener('click', () => {
    const isDark = playerEl.classList.toggle('theme-dark');
    themeBtn.textContent = isDark ? 'LIGHT' : 'DARK';
    localStorage.setItem('modplayer-theme', isDark ? 'dark' : 'light');
  });

  const savedTheme = localStorage.getItem('modplayer-theme');
  if (savedTheme === 'dark') {
    playerEl.classList.add('theme-dark');
    themeBtn.textContent = 'LIGHT';
  }
}
