#!/usr/bin/env bash
#
# Repack the upstream Joplin Windows x64 release:
#   - x64 payload only (never app-32.7z / app-arm64.7z)
#   - OCR runtime removed      (resources/tesseract.js, tesseract.js-core)
#   - AI runtime removed       (app.asar: onnxruntime-*, @huggingface/transformers)
#   - Electron locales pruned  (English + Chinese only)
#   - output: a single portable .7z
#
#   usage: repack.sh <upstream-tag> <asset-url>
#
set -euo pipefail

TAG="${1:?usage: repack.sh <upstream-tag> <asset-url>}"
URL="${2:?missing asset download url}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-7}"
STRIP_AI="${STRIP_AI:-true}"
# Electron locale packs to keep (space separated)
KEEP_LOCALES="${KEEP_LOCALES:-en-US.pak zh-CN.pak}"
# TinyMCE language packs to keep (glob patterns, space separated)
KEEP_EDITOR_LOCALES="${KEEP_EDITOR_LOCALES:-en* zh*}"

# Joplin's own UI translations are compiled into the JS bundle (not files on
# disk), so they are cut out of the bundle by scripts/trim-joplin-locales.js.
# Keep languages whose id starts with one of these prefixes.
TRIM_UI_LOCALES="${TRIM_UI_LOCALES:-true}"
KEEP_UI_LOCALES="${KEEP_UI_LOCALES:-en zh}"

# Point Joplin's "check for updates" at another repository. Joplin fetches a
# GitHub-Releases-shaped JSON list from its own endpoint, so a GitHub API URL
# works as a drop-in replacement:
#   https://api.github.com/repos/<owner>/<repo>/releases
UPDATE_FEED_URL="${UPDATE_FEED_URL:-}"
# Same thing for resources/app-update.yml (used by electron-updater), as
# "<owner>/<repo>".
UPDATE_REPO="${UPDATE_REPO:-}"

# Opt-in trimming of the Electron/Chromium runtime itself. These files are large
# but belong to rendering / media paths, so removing them is not supported by
# Electron - test the result before relying on it. Default: off.
#   dxcompiler.dll + dxil.dll   26 MB  DirectX shader compiler (D3D12 / WebGPU) - Joplin does not use these
#   vk_swiftshader.dll           5 MB  Vulkan software rasterizer (fallback on GPU-less machines)
#   ffmpeg.dll                   3 MB  audio / video decoding
#   LICENSES.chromium.html      20 MB  third-party licence text - zero runtime impact, but BSD-style
#                                      licences expect it to ship with the binaries
STRIP_RUNTIME_EXTRAS="${STRIP_RUNTIME_EXTRAS:-false}"
RUNTIME_EXTRAS="${RUNTIME_EXTRAS:-dxcompiler.dll dxil.dll vk_swiftshader.dll ffmpeg.dll}"

VERSION="${TAG#v}"
BASENAME="Joplin-${VERSION}-win-x64-noocr-noai"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
DIST="$ROOT/dist"

log() { printf '\033[1;36m[repack]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[repack]\033[0m %s\n' "$*" >&2; exit 1; }
human() { du -sh "$1" 2>/dev/null | cut -f1; }

# prefer the modern 7-Zip build (7zz, from the "7zip" package): p7zip 16.02 has
# noticeably weaker NSIS support than the current releases
if command -v 7zz >/dev/null 2>&1; then
    SEVENZ=7zz
elif command -v 7z >/dev/null 2>&1; then
    SEVENZ=7z
else
    die "7z is required (apt-get install p7zip-full, or the newer 7zip package)"
fi
if [ "$TRIM_UI_LOCALES" = "true" ] && ! command -v node >/dev/null 2>&1; then
    die "node is required to trim UI translations (set TRIM_UI_LOCALES=false to skip)"
fi
log "archiver: $SEVENZ"

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$DIST"

# ---------------------------------------------------------------- download --
log "downloading $URL"
curl -fL --retry 3 --retry-delay 5 -o "$WORK/installer.exe" "$URL"
log "downloaded $TAG installer ($(human "$WORK/installer.exe"))"

# --------------------------------------------------------------- unpack ----
# NOTE: 7-Zip can *list* an NSIS archive but it ignores the -i! include filter
# when extracting from one, so "extract app-64.7z only" silently yields nothing.
# Unpack the whole installer instead and pick the x64 payload out of the result.
# app-32.7z / app-arm64.7z (if present) are deliberately left untouched.
mkdir -p "$WORK/payload"
log "unpacking the NSIS installer"
if ! "$SEVENZ" x -y -bsp0 -o"$WORK/payload" "$WORK/installer.exe" > "$WORK/7z-installer.log" 2>&1; then
    tail -n 40 "$WORK/7z-installer.log" >&2 || true
    die "$SEVENZ could not unpack the installer"
fi
log "payload top level: $(ls -1A "$WORK/payload" 2>/dev/null | tr '\n' ' ')"

ARCHIVE="$(find "$WORK/payload" -type f -name '*app-64*.7z' -print -quit 2>/dev/null || true)"
if [ -z "$ARCHIVE" ]; then
    log "app-64.7z not found, retrying with a flat extract ($SEVENZ e)" >&2
    mkdir -p "$WORK/flat"
    "$SEVENZ" e -y -bsp0 -o"$WORK/flat" "$WORK/installer.exe" > "$WORK/7z-flat.log" 2>&1 || true
    ARCHIVE="$(find "$WORK/flat" -type f -name '*app-64*.7z' -print -quit 2>/dev/null || true)"
fi

APP="$WORK/app"
mkdir -p "$APP"
if [ -n "$ARCHIVE" ]; then
    log "unpacking x64 payload: $(basename "$ARCHIVE")"
    if ! "$SEVENZ" x -y -bsp0 -o"$APP" "$ARCHIVE" > "$WORK/7z-payload.log" 2>&1; then
        tail -n 40 "$WORK/7z-payload.log" >&2 || true
        die "$SEVENZ could not unpack $(basename "$ARCHIVE")"
    fi
else
    log "WARNING: no app-64.7z found, using the raw extracted tree" >&2
    cp -a "$WORK/payload/." "$APP/"
    if [ -d "$WORK/flat" ]; then cp -a "$WORK/flat/." "$APP/"; fi
fi

# the payload root is not always the directory that holds Joplin.exe
if [ ! -f "$APP/Joplin.exe" ]; then
    found="$(find "$WORK" -type f -name 'Joplin.exe' -print -quit 2>/dev/null || true)"
    if [ -z "$found" ]; then
        find "$WORK" -maxdepth 3 2>/dev/null | head -n 40 >&2 || true
        die "Joplin.exe not found after unpacking - installer layout changed"
    fi
    APP="$(dirname "$found")"
fi
log "application root: $APP"
log "resources/: $(ls -1 "$APP/resources" 2>/dev/null | tr '\n' ' ')"

# ------------------------------------------------------------ strip parts ---
SIZE_BEFORE="$(du -sb "$APP" | cut -f1)"
REMOVED="$WORK/removed.txt"
: > "$REMOVED"

note_removed() { echo "$1" >> "$REMOVED"; }

log "-- OCR runtime --"
# OCR engine shipped as electron-builder extraResources
for d in tesseract.js tesseract.js-core; do
    if [ -e "$APP/resources/$d" ]; then
        log "removing  resources/$d ($(human "$APP/resources/$d"))"
        rm -rf "$APP/resources/$d"
        note_removed "resources/$d"
    fi
done

# OCR language data / leftovers (never touch app.asar itself)
if [ -d "$APP/resources" ]; then
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        log "removing  ${hit#$APP/}"
        rm -rf "$hit"
        note_removed "${hit#$APP/}"
    done < <(find "$APP/resources" -mindepth 1 \
        \( -name '*.traineddata' -o -name '*.traineddata.gz' \
           -o -name '*tessdata*' -o -name 'tesseract*' \) \
        ! -name 'app.asar' 2>/dev/null || true)
fi

# The OCR front-end is copied to two more places by copyApplicationAssets:
#   tesseract.js/dist/tesseract.min.js  -> vendor/lib/tesseract.js/
#   tesseract.js/dist/worker.min.js     -> build/tesseract.js/ (=> resources/, handled above)
for d in "$APP/vendor/lib/tesseract.js" "$APP/vendor/lib/tesseract.js-core"; do
    if [ -e "$d" ]; then
        log "removing  vendor/lib/$(basename "$d") ($(human "$d"))"
        rm -rf "$d"
        note_removed "vendor/lib/$(basename "$d")"
    fi
done

log "-- Electron locales --"
if [ -d "$APP/locales" ]; then
    keep_args=()
    for l in $KEEP_LOCALES; do keep_args+=(! -name "$l"); done
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f"
        note_removed "locales/$(basename "$f")"
    done < <(find "$APP/locales" -maxdepth 1 -type f "${keep_args[@]}" -print 2>/dev/null || true)
    log "kept: $(ls -1A "$APP/locales" 2>/dev/null | tr '\n' ' ')"
else
    log "WARNING: no locales/ directory found" >&2
fi

log "-- editor locales (TinyMCE) --"
# Assets/TinyMCE/langs/*.js are copied to vendor/lib/tinymce/langs by
# copyApplicationAssets - same policy as the Electron locales above.
TM_LANGS="$APP/vendor/lib/tinymce/langs"
if [ -d "$TM_LANGS" ]; then
    tm_before="$(find "$TM_LANGS" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    keep_args=()
    for l in $KEEP_EDITOR_LOCALES; do keep_args+=(! -name "$l"); done
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f"
        note_removed "vendor/lib/tinymce/langs/$(basename "$f")"
    done < <(find "$TM_LANGS" -maxdepth 1 -type f "${keep_args[@]}" -print 2>/dev/null || true)
    log "kept $(find "$TM_LANGS" -maxdepth 1 -type f 2>/dev/null | wc -l) of $tm_before: $(ls -1A "$TM_LANGS" 2>/dev/null | tr '\n' ' ')"
else
    log "vendor/lib/tinymce/langs not found, nothing to prune"
fi

log "-- optional runtime extras --"
if [ "$STRIP_RUNTIME_EXTRAS" = "true" ]; then
    for f in $RUNTIME_EXTRAS; do
        if [ -e "$APP/$f" ]; then
            log "removing  $f ($(human "$APP/$f"))"
            rm -rf "$APP/$f"
            note_removed "$f"
        fi
    done
    log "kept: $(ls -1A "$APP" 2>/dev/null | tr '\n' ' ')"
else
    log "skipped (STRIP_RUNTIME_EXTRAS != true)"
fi

log "-- AI runtime (inside app.asar) --"
# onnxruntime-node + @huggingface/transformers power the local semantic search.
# They live inside resources/app.asar, so the archive must be unpacked, edited
# and repacked with @electron/asar.
# Safe to remove: LocalEmbeddingProvider resolves the runtime lazily through
# shim.onnxRuntime() and imports transformers.js dynamically, both guarded with
# null checks, so the app still starts - only AI features stop working.
AI_DONE=false
ASAR="$APP/resources/app.asar"
if [ "$STRIP_AI" != "true" ]; then
    log "skipped (STRIP_AI != true)"
elif [ ! -f "$ASAR" ]; then
    log "WARNING: app.asar not found, skipping" >&2
elif ! command -v asar >/dev/null 2>&1 && ! command -v npx >/dev/null 2>&1; then
    log "WARNING: neither 'asar' nor 'npx' is available, skipping" >&2
else
    if command -v asar >/dev/null 2>&1; then
        ASAR_BIN=(asar)
    else
        ASAR_BIN=(npx --yes @electron/asar)
    fi
    ASARDIR="$WORK/asar"
    mkdir -p "$ASARDIR/src"
    log "unpacking app.asar with ${ASAR_BIN[*]}"
    "${ASAR_BIN[@]}" extract "$ASAR" "$ASARDIR/src" \
        || die "asar extract failed"

    # Some files must NOT live inside the archive: native .node modules and
    # node-notifier's helper exes are executed by the OS, not required by Node,
    # so electron-builder keeps them next to the archive in app.asar.unpacked.
    # Read that list from the original header so it can be restored on pack.
    cat > "$WORK/asar-unpacked.js" <<'NODE'
const fs = require('fs');
const fd = fs.openSync(process.argv[1], 'r');
const head = Buffer.alloc(12);
fs.readSync(fd, head, 0, 12, 0);
const jsonLen = head.readUInt32LE(8);
const hb = Buffer.alloc(jsonLen);
fs.readSync(fd, hb, 0, jsonLen, 12);
fs.closeSync(fd);
const header = JSON.parse(hb.toString('utf8'));
const out = [];
(function walk(node, prefix) {
    for (const [name, meta] of Object.entries(node.files || {})) {
        const p = prefix ? prefix + '/' + name : name;
        if (meta.unpacked) out.push(p);
        if (meta.files) walk(meta, p);
    }
})(header, '');
console.log(out.join('\n'));
NODE
    node "$WORK/asar-unpacked.js" "$ASAR" > "$WORK/asar-unpacked.txt" 2>/dev/null || true
    UNPACKED_COUNT="$(grep -c . "$WORK/asar-unpacked.txt" 2>/dev/null || true)"
    log "entries that must stay unpacked: ${UNPACKED_COUNT:-0}"

    # @huggingface/transformers pulls in a whole tree of its own, so removing
    # just the package would leave its dependencies behind as orphans:
    #   onnxruntime-web (~115 MB of wasm), onnxruntime-node, onnxruntime-common,
    #   sharp (native), @huggingface/jinja, @huggingface/tokenizers.
    # Match on the directory name so nested copies are caught too.
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        rel="app.asar/${d#$ASARDIR/src/}"
        log "removing  $rel ($(human "$d"))"
        rm -rf "$d"
        note_removed "$rel"
    done < <(find "$ASARDIR/src" -type d \
        \( \( -path '*/node_modules/*' -name 'onnxruntime-*' \) \
           -o \( -path '*/node_modules/*' -name 'sharp' \) \
           -o \( -path '*/node_modules/*' -name '@huggingface' \) \) \
        -print 2>/dev/null || true)

    # fail loudly if anything AI-ish survived
    leftover="$(find "$ASARDIR/src" -type d \
        \( -name 'onnxruntime-*' -o -name 'sharp' -o -path '*/@huggingface/*' \) \
        -print 2>/dev/null || true)"
    if [ -n "$leftover" ]; then
        log "WARNING: AI leftovers still present:" >&2
        echo "$leftover" | head -n 20 >&2
    fi

    # show what is actually left, so missed items are visible in the log
    log "largest directories left in app.asar:"
    du -sh "$ASARDIR/src"/node_modules/* 2>/dev/null | sort -rh | head -n 15 > "$WORK/asar-leftover-sizes.txt" || true
    sed 's/^/    /' "$WORK/asar-leftover-sizes.txt"

    # ---- UI translations: they live in the bundle, not on disk ----
    if [ "$TRIM_UI_LOCALES" = "true" ]; then
        log "-- UI translations --"
        # (a) the loader: locales/index.js lists every language and also fills
        #     the `stats` map that the settings screen uses to build its
        #     language list, so the entries have to be cut from the code.
        mapfile -t lo_bundles < <(grep -rl 'percentDone' "$ASARDIR/src" --include='*.js' 2>/dev/null || true)
        for b in "${lo_bundles[@]}"; do
            node "$ROOT/scripts/trim-joplin-locales.js" "$b" $KEEP_UI_LOCALES \
                || die "failed to trim translations in ${b#$ASARDIR/src/}"
        done

        # (b) the translation data itself: a directory of one JSON file per
        #     language, sitting next to the loader.
        while IFS= read -r lo_dir; do
            lo_before="$(find "$lo_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
            [ "$lo_before" -gt 1 ] || continue
            lo_keep=()
            for l in $KEEP_UI_LOCALES; do lo_keep+=(! -name "$l*.json"); done
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                rm -f "$f"
            done < <(find "$lo_dir" -maxdepth 1 -type f -name '*.json' "${lo_keep[@]}" -print 2>/dev/null || true)
            log "  ${lo_dir#$ASARDIR/src/}: kept $(find "$lo_dir" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l) of $lo_before language file(s)"
        done < <(find "$ASARDIR/src" -type d -name 'locales' 2>/dev/null || true)

        note_removed "app.asar: UI translations other than [${KEEP_UI_LOCALES// /, }]"
    else
        log "-- UI translations -- skipped (TRIM_UI_LOCALES != true)"
    fi

    # ---- repoint the update check ----
    if [ -n "$UPDATE_FEED_URL" ]; then
        log "-- update feed --"
        feed_hits=false
        mapfile -t feed_files < <(grep -rl 'objects\.joplinusercontent\.com' "$ASARDIR/src" --include='*.js' 2>/dev/null || true)
        for f in "${feed_files[@]}"; do
            sed -i "s|https://objects\.joplinusercontent\.com/r/releases|$UPDATE_FEED_URL|g" "$f"
            log "  ${f#$ASARDIR/src/} -> $UPDATE_FEED_URL"
            feed_hits=true
        done
        if [ "$feed_hits" = "false" ]; then
            log "WARNING: no bundle referencing the update feed was found" >&2
        else
            note_removed "app.asar: update feed -> $UPDATE_FEED_URL"
        fi
    fi

    log "repacking app.asar"
    # The old unpacked directory must be wiped first: `asar pack` only adds or
    # overwrites files in app.asar.unpacked and would otherwise leave the
    # unpacked copies of the modules we just deleted (onnxruntime-node, sharp,
    # ...) behind.
    rm -rf "$APP/resources/app.asar.unpacked"

    # Unpack every native binary the archive contains. electron-builder's
    # smartUnpack moves these out automatically (sqlite3, keytar, sqlite-vec,
    # node-notifier's helper exes) because Electron cannot load a .node module
    # or execute a helper exe from inside the archive. @electron/asar takes a
    # SINGLE glob for --unpack, hence one brace pattern; it is matched against
    # the full source path, hence the leading **/.
    "${ASAR_BIN[@]}" pack "$ASARDIR/src" "$ASAR" \
        --unpack "**/*.{node,dll,exe,so,dylib}" \
        || die "asar pack failed"
    rm -rf "$ASARDIR"

    # Verify: every path the original archive kept unpacked - minus the modules
    # we deliberately removed - must be back in app.asar.unpacked. Anything
    # missing means a native module got packed inside the archive and Joplin
    # would fail to start.
    if [ -s "$WORK/asar-unpacked.txt" ]; then
        missing="$(while IFS= read -r p; do
            [ -n "$p" ] || continue
            case "$p" in
                */onnxruntime-*|*/sharp/*|*/@huggingface/*) continue ;;
            esac
            [ -f "$APP/resources/app.asar.unpacked/$p" ] || echo "$p"
        done < "$WORK/asar-unpacked.txt")"
        if [ -n "$missing" ]; then
            log "ERROR: these originally-unpacked paths are missing:" >&2
            echo "$missing" | head -n 20 >&2
            die "native modules would be trapped inside app.asar"
        fi
        log "verified: all $(grep -c . "$WORK/asar-unpacked.txt") unpacked paths restored"
    fi
    if [ -d "$APP/resources/app.asar.unpacked" ]; then
        log "app.asar.unpacked: $(find "$APP/resources/app.asar.unpacked" -type f 2>/dev/null | wc -l) file(s), $(human "$APP/resources/app.asar.unpacked")"
    fi
    AI_DONE=true
fi

# ---------------------------------------------------- app-update.yml (feed) --
# electron-builder writes resources/app-update.yml (provider/owner/repo) for
# electron-updater. Joplin's own update check does not read it, but the
# autoUpdater service does, so it must point at the same place as the feed URL.
if [ -n "$UPDATE_REPO" ] && [ -f "$APP/resources/app-update.yml" ]; then
    log "-- app-update.yml --"
    up_owner="${UPDATE_REPO%%/*}"
    up_repo="${UPDATE_REPO##*/}"
    sed -i "s|^owner:.*|owner: $up_owner|; s|^repo:.*|repo: $up_repo|" "$APP/resources/app-update.yml"
    log "  owner=$up_owner repo=$up_repo"
    note_removed "resources/app-update.yml: owner/repo -> $UPDATE_REPO"
fi

# non-x64 leftovers (ia32 / arm payloads), just in case
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    log "removing  ${hit#$APP/} (non-x64)"
    rm -rf "$hit"
    note_removed "${hit#$APP/}"
done < <(find "$APP" -type f \
    \( -name 'app-32.7z' -o -name 'app-arm64.7z' -o -name '*-ia32.*' \) 2>/dev/null || true)

SIZE_AFTER="$(du -sb "$APP" | cut -f1)"
SAVED=$(( SIZE_BEFORE - SIZE_AFTER ))
if [ ! -s "$REMOVED" ]; then
    log "WARNING: nothing matched - check the patterns in this script" >&2
fi
log "stripped $(( SAVED / 1024 / 1024 )) MiB ($(wc -l < "$REMOVED") item(s))"

# sanity check: what is still taking up space, at the app root level
log "largest items left in the app:"
du -sh "$APP"/* 2>/dev/null | sort -rh | head -n 12 > "$WORK/app-leftover-sizes.txt" || true
sed 's/^/    /' "$WORK/app-leftover-sizes.txt"

if [ -d "$APP/resources" ]; then
    log "resources/ breakdown:"
    du -sh "$APP/resources"/* 2>/dev/null | sort -rh | head -n 10 >> "$WORK/app-leftover-sizes.txt" || true
    du -sh "$APP/resources"/* 2>/dev/null | sort -rh | head -n 10 | sed 's/^/    /' || true
fi

# ------------------------------------------------------------- repack ------
cat > "$APP/BUILD_INFO.txt" <<EOF
Joplin $VERSION - Windows x64, trimmed build
upstream : $TAG
source   : $URL
built    : $(date -u +%Y-%m-%dT%H:%M:%SZ)

Removed:
- OCR runtime (resources/tesseract.js, resources/tesseract.js-core)
- AI runtime (inside app.asar: @huggingface/*, onnxruntime-node / -common / -web, sharp)
- Electron locales other than: $KEEP_LOCALES

OCR and the local semantic search (AI embeddings) are unavailable in this
build; everything else is stock Joplin.
EOF

PACK="$WORK/pack"
mkdir -p "$PACK"
mv "$APP" "$PACK/Joplin"

log "packing 7z (level $COMPRESS_LEVEL)"
( cd "$PACK" && "$SEVENZ" a -t7z "-mx=$COMPRESS_LEVEL" -m0=lzma2 -mmt=on -bsp0 "$DIST/$BASENAME.7z" Joplin >/dev/null )
log "  -> $BASENAME.7z ($(human "$DIST/$BASENAME.7z"))"

# ------------------------------------------------------------- metadata ----
( cd "$DIST" && sha256sum * > sha256.txt )

{
    echo "Joplin **$VERSION** (Windows x64, trimmed)"
    echo
    echo "Built from [laurent22/joplin@$TAG](https://github.com/laurent22/joplin/releases/tag/$TAG)."
    echo
    echo "Saved $(( SAVED / 1024 / 1024 )) MiB of unpacked size."
    echo
    echo "## Usage"
    echo
    echo "1. Extract the archive."
    echo "2. Run \`Joplin.exe\`."
    echo
    echo "## Caveats"
    echo
    echo "- **OCR is unavailable**: the tesseract engine was removed. Language data"
    echo "  (\`.traineddata\`) is downloaded by Joplin at runtime, so nothing else is missing."
    if [ "$AI_DONE" = "true" ]; then
        echo "- **Local semantic search / AI embeddings are unavailable**:"
        echo "  \`@huggingface/transformers\` and its whole dependency tree were removed from"
        echo "  \`app.asar\` (\`onnxruntime-node\`, \`onnxruntime-common\`, \`onnxruntime-web\`,"
        echo "  \`sharp\`, \`@huggingface/jinja\`, \`@huggingface/tokenizers\`)."
        echo "  The runtime is resolved lazily, so the app starts normally -"
        echo "  only the AI features stop working."
    fi
    echo "- **Only English and Chinese locales are bundled.**"
    echo "- This is a repack of the official build: no auto-update metadata is included."
} > "$DIST/RELEASE_NOTES.md"

log "done."
