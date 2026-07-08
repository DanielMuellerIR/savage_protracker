// Headless-Test für den Bounds-Check im Pattern-Konstruktor (modplayer.js).
//
// Regressionsschutz für Code-Review-Fund #1 (2026-07-05): Eine kaputte oder
// abgeschnittene MOD-Datei kann mehr Patterns deklarieren, als tatsächlich
// Bytes vorhanden sind. Früher warf `new Uint8Array(modfile, offset, 1024)`
// dann eine RangeError, die im async Drop-Handler unbehandelt blieb. Der
// Konstruktor liefert jetzt stattdessen 64 leere Rows (wie der Swift-Parser).
//
// Aufruf (headless): node Tests/js/pattern-bounds.mjs  → Exit 0 = grün.

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const modplayerPath = join(here, '..', '..', 'modplayer.js');

// modplayer.js berührt `window` nur in Methoden (nie beim Import) → in Node ladbar.
const { Pattern } = await import(modplayerPath);

let failures = 0;
function check(name, cond) {
    if (cond) {
        console.log(`  ok   ${name}`);
    } else {
        console.error(`  FAIL ${name}`);
        failures++;
    }
}

// --- Fall 1: abgeschnittene Datei (Pattern-Slice passt NICHT mehr rein) ---
// Header (1084 Bytes) + nur 512 statt 1024 Bytes für Pattern 0.
const truncated = new ArrayBuffer(1084 + 512);
let truncPattern;
let threw = false;
try {
    truncPattern = new Pattern(truncated, 0);
} catch (e) {
    threw = true;
}
check('abgeschnittene Datei wirft keine RangeError', !threw);
check('abgeschnittene Datei liefert 64 Rows', truncPattern?.rows?.length === 64);
check('leere Row hat 4 Notes', truncPattern?.rows?.[0]?.notes?.length === 4);

// --- Fall 2: vollständige Datei (Pattern-Slice passt) parst weiterhin ---
const full = new ArrayBuffer(1084 + 1024);
let fullPattern;
let threwFull = false;
try {
    fullPattern = new Pattern(full, 0);
} catch (e) {
    threwFull = true;
}
check('vollständige Datei wirft nicht', !threwFull);
check('vollständige Datei liefert 64 Rows', fullPattern?.rows?.length === 64);

if (failures > 0) {
    console.error(`\n${failures} Test(s) fehlgeschlagen.`);
    process.exit(1);
}
console.log('\nAlle Pattern-Bounds-Tests grün.');
