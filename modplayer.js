// Standalone Amiga ProTracker MOD Player
// Bündelt: Mod-Parser, Loader und ModPlayer in einem ES-Modul.
// Originalcode aus dem p_fraktal-Projekt extrahiert und entschlackt.
//
// Aufbau für Anfänger:
//   - Instrument / Note / Row / Pattern / Mod = Klassen, die das .mod-Binärformat dekodieren.
//   - loadMod()         = lädt eine MOD-Datei per fetch() und gibt ein Mod-Objekt zurück.
//   - ModPlayer         = startet den AudioWorklet, schickt das Mod-Objekt rein und gibt Events raus.
//
// Das eigentliche Abspielen passiert im AudioWorklet (mod-player-worklet.js).
// Hier wird nur geparst und kommuniziert.

// ─── MOD-Parser ────────────────────────────────────────────────────────────────

// Ein Instrument (= Sample) im MOD-Header. Insgesamt 31 Stück, je 30 Bytes Header.
export class Instrument {
  constructor(modfile, index, sampleStart) {
    // Header liegt bei Offset 20 + index*30, ist 30 Bytes lang.
    const data = new Uint8Array(modfile, 20 + index * 30, 30);
    // Name: erste 22 Bytes, null-bytes ignorieren.
    const nameBytes = data.slice(0, 22).filter(a => !!a);
    this.index = index;
    this.name = String.fromCodePoint(...Array.from(nameBytes)).trim();
    // Länge ist Big-Endian Word in 16-bit Words, also *2 für Bytes.
    this.length = 2 * (data[22] * 256 + data[23]);
    // Finetune: signed nibble (-8..7), wird als 0..15 gespeichert.
    this.finetune = data[24];
    if (this.finetune > 7) this.finetune -= 16;
    this.volume = data[25];
    this.repeatOffset = 2 * (data[26] * 256 + data[27]);
    this.repeatLength = 2 * (data[28] * 256 + data[29]);

    // Sample-Daten als Int8Array; sicherheitshalber Grenzen prüfen.
    const actualSampleStart = Math.min(sampleStart, modfile.byteLength);
    const actualLength = Math.min(this.length, modfile.byteLength - actualSampleStart);
    this.bytes = new Int8Array(modfile, actualSampleStart, actualLength);
    this.isLooped = this.repeatOffset !== 0 || this.repeatLength > 2;
  }
}

// Eine einzelne Note in einer Pattern-Zeile (4 Bytes pro Note pro Kanal).
export class Note {
  constructor(noteData) {
    // Instrument-Nummer ist auf die oberen Nibbles von Byte 0 und 2 verteilt.
    this.instrument = (noteData[0] & 0xf0) | (noteData[2] >> 4);
    // Period (Tonhöhe) = unteres Nibble Byte 0 + Byte 1, 12-bit.
    this.period = (noteData[0] & 0x0f) * 256 + noteData[1];
    let effectId = noteData[2] & 0x0f;
    let effectData = noteData[3];
    // Erweiterter Effekt 0xE: ID liegt im oberen Nibble der Daten.
    if (effectId === 0x0e) {
      effectId = 0xe0 | (effectData >> 4);
      effectData &= 0x0f;
    }
    this.rawEffect = ((noteData[2] & 0x0f) << 8) | noteData[3];
    this.effectId = effectId;
    this.effectData = effectData;
    this.effectHigh = effectData >> 4;
    this.effectLow = effectData & 0x0f;
    this.hasEffect = effectId || effectData;
  }
}

// Eine Zeile im Pattern (4 Kanäle = 16 Bytes).
export class Row {
  constructor(rowData) {
    this.notes = [];
    for (let i = 0; i < 16; i += 4) {
      this.notes.push(new Note(rowData.slice(i, i + 4)));
    }
  }
}

// Ein Pattern = 64 Zeilen á 16 Byte = 1024 Bytes.
export class Pattern {
  constructor(modfile, index) {
    const data = new Uint8Array(modfile, 1084 + index * 1024, 1024);
    this.rows = [];
    for (let i = 0; i < 64; ++i) {
      this.rows.push(new Row(data.slice(i * 16, i * 16 + 16)));
    }
  }
}

// Das gesamte MOD-File.
export class Mod {
  constructor(modfile) {
    // Songname: erste 20 Bytes des Files.
    const nameArray = new Uint8Array(modfile, 0, 20);
    const nameBytes = nameArray.filter(a => !!a);
    this.name = String.fromCodePoint(...Array.from(nameBytes)).trim();

    // Anzahl der Pattern-Positionen + die Reihenfolge (PatternTable).
    this.length = new Uint8Array(modfile, 950, 1)[0];
    this.patternTable = new Uint8Array(modfile, 952, this.length);

    // Höchste verwendete Pattern-Nummer bestimmt die Größe.
    const maxPatternIndex = Math.max(...Array.from(this.patternTable));

    // Index 0 ist leer (Instrumente werden ab 1 referenziert).
    this.instruments = [null];
    let sampleStart = 1084 + (maxPatternIndex + 1) * 1024;
    for (let i = 0; i < 31; ++i) {
      const instr = new Instrument(modfile, i, sampleStart);
      this.instruments.push(instr);
      sampleStart += instr.length;
    }

    this.patterns = [];
    for (let i = 0; i <= maxPatternIndex; ++i) {
      this.patterns.push(new Pattern(modfile, i));
    }
  }
}

// ─── Loader ────────────────────────────────────────────────────────────────────

// Lädt eine MOD-Datei per URL und prüft Signatur.
export async function loadMod(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Fetch fehlgeschlagen: ${response.status} ${response.statusText} (${url})`);
  }
  const arrayBuffer = await response.arrayBuffer();
  return parseModBuffer(arrayBuffer, url);
}

// Parst einen bereits geladenen ArrayBuffer (z.B. aus File-Upload).
export function parseModBuffer(arrayBuffer, label = 'buffer') {
  if (arrayBuffer.byteLength < 1084) {
    throw new Error(`MOD zu klein (${arrayBuffer.byteLength} Bytes): ${label}`);
  }
  const sig = new Uint8Array(arrayBuffer, 1080, 4);
  const sigStr = String.fromCharCode(sig[0], sig[1], sig[2], sig[3]);
  const validSigs = ['M.K.', 'M!K!', 'FLT4', 'FLT8', '4CHN', '6CHN', '8CHN'];
  if (!validSigs.includes(sigStr)) {
    throw new Error(`Ungültige MOD-Signatur "${sigStr}": ${label}`);
  }
  return new Mod(arrayBuffer);
}

// ─── ModPlayer ─────────────────────────────────────────────────────────────────

// Tabelle: aus Period -> MIDI-Noten-Index (0..47), wird vom Worklet-Event
// bei "watchNotes" gebraucht, damit Aufrufer die Notennummer bekommen.
const notePerPeriod = new Array(65536);
for (let p = 0; p < 65536; p++) {
  notePerPeriod[p] = p < 124 ? null : 24 + Math.round(12 * Math.log2(428 / p));
}

export class ModPlayer {
  constructor() {
    this.mod = null;
    this.playing = false;
    this.audio = null;
    this.gain = null;
    this.worklet = null;
    this.volume = 0.3;
    this.workletUrl = 'mod-player-worklet.js';
    this.rowCallbacks = [];
    this.stopCallbacks = [];
    this.noteCallbacks = [];
    // levelCallbacks bekommen das echte Per-Channel-Peak-Array
    // ([p0,p1,p2,p3] in 0..~0.5) aus dem Worklet, ~47x pro Sekunde.
    // Damit zeigen die VU-Meter den tatsächlich gerade hörbaren Pegel,
    // nicht nur den Note-Trigger.
    this.levelCallbacks = [];
    this.singleCallbacks = {};
  }

  // Lädt eine MOD-Datei von einer URL.
  async load(url, workletUrl = 'mod-player-worklet.js') {
    this.unload();
    this.workletUrl = workletUrl;
    this.mod = await loadMod(url);
  }

  // Setzt ein bereits geparstes Mod direkt (für File-Upload).
  setMod(mod, workletUrl = 'mod-player-worklet.js') {
    this.unload();
    this.workletUrl = workletUrl;
    this.mod = mod;
  }

  // Setup für AudioContext + Worklet. Wird beim ersten play() ausgeführt.
  async setupAudio() {
    if (this.worklet) return;

    if (!this.audio) {
      const AC = window.AudioContext || window.webkitAudioContext;
      this.audio = new AC();
    }
    const ctx = this.audio;

    if (ctx.state === 'suspended') {
      try { await ctx.resume(); } catch (_) {}
    }

    // Stumme Dummy-Source für iOS-Audio-Unlock.
    try {
      const buffer = ctx.createBuffer(1, 1, 22050);
      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      source.start(0);
    } catch (_) {}

    this.gain = ctx.createGain();
    this.gain.gain.value = this.volume;

    const absoluteWorkletUrl = new URL(this.workletUrl, window.location.href).href;
    if (!ctx.__workletAdded) {
      await ctx.audioWorklet.addModule(absoluteWorkletUrl);
      ctx.__workletAdded = true;
    }
    this.worklet = new AudioWorkletNode(ctx, 'mod-player-worklet', {
      outputChannelCount: [2]
    });

    this.worklet.connect(this.gain).connect(ctx.destination);
    this.worklet.port.onmessage = this.onMessage.bind(this);

    if (this.rowCallbacks.length || Object.keys(this.singleCallbacks).length) {
      this.worklet.port.postMessage({ type: 'enableRowSubscription' });
    }
    if (this.stopCallbacks.length) {
      this.worklet.port.postMessage({ type: 'enableStopSubscription' });
    }
    if (this.noteCallbacks.length) {
      this.worklet.port.postMessage({ type: 'enableNoteSubscription' });
    }
    if (this.levelCallbacks.length) {
      this.worklet.port.postMessage({ type: 'enableLevelSubscription' });
    }
  }

  // Empfängt Events vom Worklet (row, stop, note).
  onMessage(event) {
    const { data } = event;
    if (data.type === 'row') {
      for (const cb of this.rowCallbacks) cb(data.position, data.rowIndex, data.bpm, data.speed);
      const key = data.position + ':' + data.rowIndex;
      if (key in this.singleCallbacks) {
        for (const cb of this.singleCallbacks[key]) cb();
      }
    } else if (data.type === 'stop') {
      for (const cb of this.stopCallbacks) cb();
    } else if (data.type === 'note') {
      for (const cb of this.noteCallbacks) {
        cb({
          channel: data.channel,
          sample: data.sample,
          volume: data.volume,
          note: notePerPeriod[data.period]
        });
      }
    } else if (data.type === 'levels') {
      // Realer Per-Channel-Peak. data.peaks ist [p0,p1,p2,p3].
      // Wir reichen das Array 1:1 weiter — Aufrufer interpretieren die
      // Skala (Maximum theoretisch 0.5, siehe Channel.nextOutput()).
      for (const cb of this.levelCallbacks) cb(data.peaks);
    }
  }

  watchRows(cb) {
    if (this.worklet) this.worklet.port.postMessage({ type: 'enableRowSubscription' });
    this.rowCallbacks.push(cb);
  }

  watchStop(cb) {
    if (this.worklet) this.worklet.port.postMessage({ type: 'enableStopSubscription' });
    this.stopCallbacks.push(cb);
  }

  watchNotes(cb) {
    if (this.worklet) this.worklet.port.postMessage({ type: 'enableNoteSubscription' });
    this.noteCallbacks.push(cb);
  }

  // Subscribed auf das echte Per-Channel-Peak-Array, das das Worklet
  // ca. 47x pro Sekunde schickt. cb(peaks: number[4]).
  watchLevels(cb) {
    if (this.worklet) this.worklet.port.postMessage({ type: 'enableLevelSubscription' });
    this.levelCallbacks.push(cb);
  }

  unload() {
    this.stop();
    if (this.worklet) {
      try { this.worklet.disconnect(); } catch (_) {}
    }
    this.mod = null;
    this.worklet = null;
    this.playing = false;
    this.rowCallbacks = [];
    this.stopCallbacks = [];
    this.noteCallbacks = [];
    this.levelCallbacks = [];
    this.singleCallbacks = {};
  }

  resumeContext() {
    if (!this.audio) {
      const AC = window.AudioContext || window.webkitAudioContext;
      this.audio = new AC();
    }
    if (this.audio.state === 'suspended') {
      this.audio.resume().catch(() => {});
    }
    try {
      const buffer = this.audio.createBuffer(1, 1, 22050);
      const source = this.audio.createBufferSource();
      source.buffer = buffer;
      source.connect(this.audio.destination);
      source.start(0);
    } catch (_) {}
  }

  async play() {
    if (this.playing) return;
    await this.setupAudio();
    if (!this.worklet) return;
    this.resumeContext();
    this.worklet.port.postMessage({
      type: 'play',
      mod: this.mod,
      sampleRate: this.audio.sampleRate
    });
    this.playing = true;
  }

  stop() {
    if (this.worklet) {
      this.worklet.port.postMessage({ type: 'stop' });
    }
    this.playing = false;
  }

  setVolume(v) {
    this.volume = v;
    // Psychoakustische (quadratische) Lautstärkeskalierung für besseres Hörempfinden
    if (this.gain) this.gain.gain.value = v * v;
  }

  // Springt zu einer bestimmten Position (Pattern-Index) und Zeile (Row) im Song.
  setPosition(position, row = 0) {
    if (this.worklet) {
      this.worklet.port.postMessage({ type: 'setRow', position, row });
    }
  }
}
