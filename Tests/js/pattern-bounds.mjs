// Headless-Test für den Bounds-Check im Pattern-Konstruktor (modplayer.js),
// getrieben durch den ECHTEN Parser-Einstieg parseModBuffer — also denselben
// Pfad, den auch der Drag&Drop-Upload nimmt.
//
// Regressionsschutz für Code-Review-Fund #1 (2026-07-05): Eine abgeschnittene
// MOD-Datei kann mehr Patterns deklarieren, als tatsächlich Bytes vorhanden
// sind. Früher warf `new Uint8Array(modfile, offset, 1024)` dann eine
// RangeError ("Invalid typed array length: 1024"), die im async Drop-Handler
// unbehandelt blieb. Der Konstruktor liefert jetzt 64 leere Rows (wie der
// Swift-Parser). Live gegen eine echte, gekürzte MOD verifiziert; dieser Test
// verwendet eine selbst-erzeugte MOD-Struktur, um unabhängig von den
// (gitignorierten) audio/-Dateien zu bleiben.
//
// Aufruf (headless): node Tests/js/pattern-bounds.mjs  → Exit 0 = grün.

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const modplayerPath = join(here, '..', '..', 'modplayer.js');
// modplayer.js berührt `window` nur in Methoden (nie beim Import) → in Node ladbar.
const { parseModBuffer } = await import(modplayerPath);

// Baut eine minimale, aber strukturell gültige 4-Kanal-MOD:
// gültige "M.K."-Signatur bei Offset 1080, Songlänge + Pattern-Tabelle so, dass
// `patternCount` Patterns (Index 0..patternCount-1) erwartet werden. Sample-Header
// bleiben Null (Länge 0). `totalBytes` steuert, ob die Pattern-Daten vollständig
// in die Datei passen oder abgeschnitten sind.
function makeMod(totalBytes, patternCount = 1) {
    const ab = new ArrayBuffer(totalBytes);
    const u8 = new Uint8Array(ab);
    u8[950] = patternCount;                       // Songlänge (Anzahl Positionen)
    for (let i = 0; i < patternCount; ++i) u8[952 + i] = i; // Pattern-Tabelle: Position i -> Pattern i
    u8[1080] = 0x4D; u8[1081] = 0x2E;             // "M."
    u8[1082] = 0x4B; u8[1083] = 0x2E;             // "K."
    return ab;
}

let failures = 0;
function check(name, cond) {
    if (cond) {
        console.log(`  ok   ${name}`);
    } else {
        console.error(`  FAIL ${name}`);
        failures++;
    }
}

// --- Fall 1: abgeschnittene Datei (Pattern 0 ragt über das Dateiende) ---
// 1 deklariertes Pattern braucht Bytes 1084..2108, Datei ist nur 1184 Bytes.
const truncated = makeMod(1184, 1);
let mod1, threw = false;
try {
    mod1 = parseModBuffer(truncated, 'truncated');
} catch (e) {
    threw = true;
    console.error(`  (Exception: ${e.constructor.name}: ${e.message})`);
}
check('abgeschnittene MOD parst ohne RangeError', !threw);
check('abgeschnittene MOD liefert 1 Pattern', mod1?.patterns?.length === 1);
check('abgeschnittenes Pattern hat 64 Rows', mod1?.patterns?.[0]?.rows?.length === 64);
check('leere Row hat 4 Notes', mod1?.patterns?.[0]?.rows?.[0]?.notes?.length === 4);

// --- Fall 2: vollständige Datei (Pattern-Daten passen) parst weiterhin ---
const full = makeMod(1084 + 1024, 1);
let mod2, threwFull = false;
try {
    mod2 = parseModBuffer(full, 'full');
} catch (e) {
    threwFull = true;
}
check('vollständige MOD parst', !threwFull);
check('vollständige MOD liefert 1 Pattern', mod2?.patterns?.length === 1);

if (failures > 0) {
    console.error(`\n${failures} Test(s) fehlgeschlagen.`);
    process.exit(1);
}
console.log('\nAlle Pattern-Bounds-Tests grün.');
