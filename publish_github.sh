#!/usr/bin/env bash
#
# publish_github.sh — Erstveroeffentlichung und Releases fuer GitHub.
#
# Das Skript pusht nur Code, wenn der Arbeitsbaum sauber ist und keine
# Audio-/Release-Artefakte im Git-Index liegen. Releases erzeugt es optional
# ueber GitHub CLI. Es legt keine gesonderten KI-Contributor an; GitHub zeigt
# nur den normalen Git-/GitHub-Account, der den Push ausfuehrt.
#
# Aufruf:
#   bash publish_github.sh                       # Code pushen
#   bash publish_github.sh --release             # Code pushen + Release/DMG
#   bash publish_github.sh --dry-run --release   # Checks anzeigen, nichts pushen
#
# Umgebung:
#   REMOTE_URL      GitHub-URL, Default siehe unten.
#   BRANCH          Zielbranch, Default: main.
#   REQUIRE_CLEAN   1 = sauberer Arbeitsbaum Pflicht, Default: 1.

set -euo pipefail

REMOTE_URL="${REMOTE_URL:-https://github.com/DanielMuellerIR/savage_protracker.git}"
BRANCH="${BRANCH:-main}"
REQUIRE_CLEAN="${REQUIRE_CLEAN:-1}"
VERSION="$(cat VERSION 2>/dev/null || echo "0.0.0")"
TAG="v${VERSION}"
DMG_PATH="build/Savage Protracker Player.dmg"
DO_RELEASE=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: bash publish_github.sh [--release] [--dry-run]

  --release  Create or update GitHub release ${TAG} and upload the DMG.
  --dry-run  Run checks and print planned actions without pushing.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            DO_RELEASE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

if [[ "$REQUIRE_CLEAN" == "1" ]] && [[ -n "$(git status --short --untracked-files=all)" ]]; then
    echo "ABBRUCH: Arbeitsbaum nicht sauber. Erst committen oder REQUIRE_CLEAN=0 setzen." >&2
    git status --short --untracked-files=all >&2
    exit 1
fi

# Nur getrackte Dateien koennen auf GitHub landen. Deshalb reicht git ls-files
# als harter Schutz gegen Testmusik und lokale Release-Artefakte.
FORBIDDEN="$(git ls-files | grep -E -i '(^audio/|\.mod$|\.sid$|\.wav$|\.aiff?$|\.mp3$|\.flac$|\.dmg$|\.app/|\.zip$|\.tar(\.gz)?$)' || true)"
if [[ -n "$FORBIDDEN" ]]; then
    echo "ABBRUCH: Nicht veroeffentlichbare Artefakte sind getrackt:" >&2
    echo "$FORBIDDEN" >&2
    exit 1
fi

if [[ "$DO_RELEASE" == "1" ]]; then
    if [[ ! -f "$DMG_PATH" ]]; then
        echo "ABBRUCH: DMG fehlt: $DMG_PATH" >&2
        echo "Vorher ausfuehren: bash build_app.sh && bash build_dmg.sh --notarize" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "ABBRUCH: GitHub CLI 'gh' fehlt. Fuer Releases installieren oder manuell hochladen." >&2
        exit 1
    fi
fi

if git remote get-url origin >/dev/null 2>&1; then
    run git remote set-url origin "$REMOTE_URL"
else
    run git remote add origin "$REMOTE_URL"
fi

echo "Remote: $REMOTE_URL"
echo "Branch: $BRANCH"
run git push -u origin "$BRANCH"

if [[ "$DO_RELEASE" == "1" ]]; then
    if ! git rev-parse "$TAG" >/dev/null 2>&1; then
        run git tag -a "$TAG" -m "Savage Protracker Player ${VERSION}"
    fi
    run git push origin "$TAG"

    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "Release ${TAG} existiert. Lade DMG neu hoch."
        run gh release upload "$TAG" "$DMG_PATH" --clobber
    else
        echo "Lege Release ${TAG} an."
        run gh release create "$TAG" "$DMG_PATH" \
            --title "Savage Protracker Player ${VERSION}" \
            --notes "macOS-App als DMG. MOD-Dateien sind nicht enthalten; Musik wird lokal per Drag & Drop oder aus einem lokalen audio-Ordner geladen."
    fi
fi

echo "Fertig."
