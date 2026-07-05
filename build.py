#!/usr/bin/env python3
"""
build.py — bündelt alle Quellen zu einer einzigen, minifizierten savage-mod-player.html.

Quelldateien (alle im Repo, kein Build-Tool, keine Abhängigkeiten):

    modplayer.js                Mod-Parser + ModPlayer-Wrapper (ES-Modul)
    mod-player-worklet.js       AudioWorklet-Sample-Mixer
    src/styles.css              UI-Styles
    src/body.html               Body-Markup
    src/app.js                  App-Logik (DOM-Wiring, Drag&Drop, …)

Schritte:

    1. Quelldateien einlesen.
    2. ES-Modul-Keywords aus modplayer.js entfernen (Inline-Skript).
    3. JS / CSS / HTML konservativ minifizieren (stdlib-only Implementierung).
    4. Das AudioWorklet wird als String eingebettet und zur Laufzeit per
       Blob-URL geladen — so funktioniert es auch aus file:// heraus.
    5. Alles zu einer einzigen HTML-Datei zusammenfassen.

Aufruf:

    python3 build.py            # erzeugt savage-mod-player.html (minifiziert)
    python3 build.py --no-min   # ohne Minifizierung (zum Debuggen)

Minifizierung ist konservativ:
    - JS: entfernt Kommentare, kollabiert Whitespace; bewahrt Zeilenumbrüche,
      um Automatic-Semicolon-Insertion (ASI) nicht zu zerschießen.
    - CSS: entfernt Kommentare und Whitespace, strafft `;:,{}`-Umgebungen.
    - HTML: entfernt Kommentare und Whitespace zwischen Tags.

Keine Regex-Literals im Quell-JS, daher reicht ein einfacher String-/Comment-
Parser. Wer später Regexe verwendet, muss minify_js() erweitern.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
SRC_DIR = HERE / 'src'


# ─────────────────────────────────────────────────────────────────────────────
# Minifizierer
# ─────────────────────────────────────────────────────────────────────────────

def strip_js_comments(src: str) -> str:
    """
    Entfernt JavaScript-Kommentare, ohne Strings oder Template-Literale
    zu zerschießen.

    Behandelt:
        - "..."   doppelte Anführungszeichen
        - '...'   einfache Anführungszeichen
        - `...`   Template-Literale (können mehrzeilig sein)
        - // ...  Zeilenkommentar bis Zeilenende
        - /* ... */  Block-Kommentar (kann mehrzeilig sein)

    Voraussetzung: keine Regex-Literals im Code (z.B. /foo/g). Diese
    würden hier fälschlich als Kommentar interpretiert. Aktueller
    Quellcode kommt ohne Regex-Literale aus.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''

        # String-Literale durchreichen (mit Escapes).
        if c in ('"', "'", '`'):
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                if ch == '\\' and i + 1 < n:
                    out.append(ch)
                    out.append(src[i + 1])
                    i += 2
                    continue
                out.append(ch)
                i += 1
                if ch == quote:
                    break
            continue

        # Zeilenkommentar: alles bis zum Newline schlucken (Newline behalten).
        if c == '/' and nxt == '/':
            i += 2
            while i < n and src[i] != '\n':
                i += 1
            continue

        # Block-Kommentar: alles bis zum nächsten "*/" schlucken.
        if c == '/' and nxt == '*':
            i += 2
            while i < n - 1 and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2  # über "*/" hinwegspringen
            continue

        out.append(c)
        i += 1
    return ''.join(out)


def collapse_js_whitespace(src: str) -> str:
    """
    Kollabiert Whitespace im JavaScript, ohne Strings zu berühren und
    ohne nötige Zeilenumbrüche zu entfernen (Schutz vor ASI-Bugs).

    Strategie:
        - In Strings: 1:1 durchreichen.
        - Außerhalb: aufeinanderfolgende Whitespaces zu maximal einem
          Newline (wenn mindestens einer dabei war) oder einem Space
          (sonst) zusammenziehen.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]

        # Strings durchreichen.
        if c in ('"', "'", '`'):
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = src[i]
                if ch == '\\' and i + 1 < n:
                    out.append(ch)
                    out.append(src[i + 1])
                    i += 2
                    continue
                out.append(ch)
                i += 1
                if ch == quote:
                    break
            continue

        # Whitespace-Block zusammenfassen.
        if c.isspace():
            had_newline = False
            while i < n and src[i].isspace():
                if src[i] == '\n':
                    had_newline = True
                i += 1
            out.append('\n' if had_newline else ' ')
            continue

        out.append(c)
        i += 1
    return ''.join(out)


def tighten_js_punctuation(src: str) -> str:
    """
    Entfernt unnötige Spaces direkt vor/nach Satzzeichen, die in JS
    immer ein Token-Ende markieren. Sehr konservativ — bewahrt
    Zeilenumbrüche, denn die brauchen wir für ASI.
    """
    # Spaces (kein Newline) um diese Zeichen sind redundant.
    # Achtung: NUR Spaces matchen, keine Newlines (\n).
    # WICHTIG: + und - sind bewusst NICHT dabei. Wuerde man sie straffen, koennte
    # aus "a + +b" faelschlich "a++b" (Post-Increment) oder aus "a - -b" "a--b"
    # werden — eine Semantik-Aenderung. Spaces um +/- bleiben daher erhalten
    # (winziger Groessen-Aufschlag, dafuer korrekt). Lookarounds helfen hier nicht,
    # weil sie die Original-Nachbarn pruefen, nicht das Ergebnis nach dem Entfernen.
    punct = r'[{}()\[\];,:?=<>*/%&|^!~]'
    src = re.sub(rf' *({punct}) *', r'\1', src)
    # Mehrfache Leerzeilen → eine.
    src = re.sub(r'\n{2,}', '\n', src)
    # Whitespace am Zeilenanfang/-ende.
    src = re.sub(r'[ \t]+\n', '\n', src)
    src = re.sub(r'\n[ \t]+', '\n', src)
    return src.strip()


def minify_js(src: str) -> str:
    """JS minifizieren — Kommentare raus, Whitespace straffen."""
    src = strip_js_comments(src)
    src = collapse_js_whitespace(src)
    src = tighten_js_punctuation(src)
    return src


def minify_css(src: str) -> str:
    """
    CSS minifizieren. CSS hat keine Strings mit Bedeutung für Whitespace
    (außer in url(), content: usw.) und keine Block-Verschachtelungs-Tricks
    → ein einfacher Regex-basierter Ansatz reicht.
    """
    # /* ... */ Kommentare raus.
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)
    # Whitespace um Satzzeichen straffen.
    src = re.sub(r'\s*([{}:;,>])\s*', r'\1', src)
    # Trailing-Semicolon vor "}" sparen.
    src = src.replace(';}', '}')
    # Mehrfache Whitespaces zu einem.
    src = re.sub(r'\s+', ' ', src)
    return src.strip()


def minify_html(src: str) -> str:
    """
    HTML minifizieren. Entfernt Kommentare und kollabiert Whitespace
    zwischen Tags. Innerhalb von Text-Inhalten bleibt mindestens ein
    Space erhalten, damit Wörter nicht verkleben.
    """
    # <!-- ... --> Kommentare raus.
    src = re.sub(r'<!--.*?-->', '', src, flags=re.DOTALL)
    # Whitespace zwischen ">" und "<" wegnehmen.
    src = re.sub(r'>\s+<', '><', src)
    # Mehrfache Whitespaces zu einem.
    src = re.sub(r'\s+', ' ', src)
    return src.strip()


# ─────────────────────────────────────────────────────────────────────────────
# Quellen lesen und vorbereiten
# ─────────────────────────────────────────────────────────────────────────────

def strip_module_keywords(src: str) -> str:
    """
    Entfernt ES-Modul-Keywords aus modplayer.js, damit das Skript inline
    in einem <script>-Tag (ohne type=module) funktioniert.
    """
    return (src
            .replace('export class', 'class')
            .replace('export async function', 'async function')
            .replace('export function', 'function'))


def build(minify: bool = True) -> Path:
    """Baut die finale modplayer.html und gibt den Pfad zurück."""
    worklet_src = (HERE / 'mod-player-worklet.js').read_text()
    modplayer_src = (HERE / 'modplayer.js').read_text()
    css_src = (SRC_DIR / 'styles.css').read_text()
    body_src = (SRC_DIR / 'body.html').read_text()
    app_src = (SRC_DIR / 'app.js').read_text()
    # Versions-String aus der VERSION-Datei lesen und in body.html einsetzen.
    # So gibt es genau eine Quelle für die Versionsnummer.
    version = (HERE / 'VERSION').read_text().strip()
    body_src = body_src.replace('{{VERSION}}', version)

    modplayer_src = strip_module_keywords(modplayer_src)

    if minify:
        worklet_src = minify_js(worklet_src)
        modplayer_src = minify_js(modplayer_src)
        app_src = minify_js(app_src)
        css_src = minify_css(css_src)
        body_src = minify_html(body_src)

    html = (
        '<!doctype html>'
        '<html lang="de">'
        '<head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Savage Mod Player</title>'
        f'<style>{css_src}</style>'
        '</head>'
        '<body>'
        f'{body_src}'
        '<script>'
        # Worklet-Quelltext als String → Blob-URL → audioWorklet.addModule()
        # akzeptiert das auch aus file://, ohne CORS-Stress.
        f'const WORKLET_SOURCE={worklet_src!r};'
        "const WORKLET_BLOB_URL=URL.createObjectURL(new Blob([WORKLET_SOURCE],{type:'application/javascript'}));"
        f'{modplayer_src}\n'
        f'{app_src}'
        '</script>'
        '</body>'
        '</html>'
    )

    out = HERE / 'savage-mod-player.html'
    out.write_text(html)
    return out


def main(argv: list[str]) -> int:
    minify = '--no-min' not in argv and '--no-minify' not in argv
    out = build(minify=minify)
    size = out.stat().st_size
    mode = 'minifiziert' if minify else 'unminifiziert'
    print(f'Geschrieben: {out} ({size:,} Bytes, {mode})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
