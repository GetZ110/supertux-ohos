#!/usr/bin/env bash
#
# fetch-sources.sh -- bash port of scripts/fetch-sources.ps1
#
# Clone the third-party sources this port builds against, at the pinned revisions in versions.txt,
# then apply the patches in patches/.
#
# Everything lands under <repo>/third_party/ (git-ignored). Nothing third-party is stored in this
# repository, so this script is the first step of any build.
#
# SuperTux needs its submodules (external/tinygettext, external/sexp-cpp, external/simplesquirrel)
# and simplesquirrel has a nested libs/squirrel submodule, hence --recursive.
#
# Usage:
#   scripts/fetch-sources.sh
#   scripts/fetch-sources.sh --proxy http://127.0.0.1:7890   # if GitHub needs a proxy
#   scripts/fetch-sources.sh --force                          # re-clone everything
#   scripts/fetch-sources.sh --skip-patches                   # pristine upstream trees
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THIRD_PARTY="$REPO_ROOT/third_party"
PROXY=""
SKIP_PATCHES=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --proxy)         PROXY="${2:-}"; shift 2 ;;
        --proxy=*)       PROXY="${1#*=}"; shift ;;
        --third-party)   THIRD_PARTY="${2:-}"; shift 2 ;;
        --third-party=*) THIRD_PARTY="${1#*=}"; shift ;;
        --skip-patches)  SKIP_PATCHES=1; shift ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

VERSIONS="$SCRIPT_DIR/versions.txt"
if [ ! -f "$VERSIONS" ]; then
    echo "missing $VERSIONS" >&2
    exit 1
fi

# git wrapper honouring --proxy. Returns git's exit code.
git_run() {
    if [ -n "$PROXY" ]; then
        git -c "http.proxy=$PROXY" -c "https.proxy=$PROXY" "$@"
    else
        git "$@"
    fi
}

mkdir -p "$THIRD_PARTY"
echo "third_party: $THIRD_PARTY"

failures=0

# name|url|rev|note
while IFS= read -r line; do
    # skip blanks and comments
    case "$line" in ''|'#'*) continue ;; esac
    if ! printf '%s' "$line" | grep -q '[^[:space:]]'; then continue; fi

    name="$(printf '%s' "$line" | cut -d'|' -f1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    url="$(printf '%s'  "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    rev="$(printf '%s'  "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$name" ] && continue

    dir="$THIRD_PARTY/$name"
    short="${rev:0:12}"
    echo
    echo "=== $name @ $short ==="

    if [ "$FORCE" -eq 1 ] && [ -e "$dir" ]; then
        rm -rf "$dir"
    fi

    if [ -d "$dir/.git" ]; then
        echo "  already cloned, checking out the pinned revision"
        if ! git_run -C "$dir" fetch --depth 1 origin "$rev"; then
            echo "  ERROR: fetch failed for $name" >&2
            failures=$((failures + 1))
            continue
        fi
        if ! git_run -C "$dir" checkout -q --detach FETCH_HEAD; then
            echo "  ERROR: checkout failed for $name" >&2
            failures=$((failures + 1))
            continue
        fi
    else
        mkdir -p "$(dirname "$dir")"
        git_run init -q "$dir" || { echo "  ERROR: init failed" >&2; failures=$((failures + 1)); continue; }
        git_run -C "$dir" remote add origin "$url" || true

        # GitHub serves fetches by SHA, which keeps this shallow and quick.
        if git_run -C "$dir" fetch --depth 1 origin "$rev" \
           && git_run -C "$dir" checkout -q --detach FETCH_HEAD; then
            :
        else
            echo "  fetch by revision failed, falling back to a blobless clone"
            rm -rf "$dir"
            if ! git_run clone --filter=blob:none --no-checkout "$url" "$dir" \
               || ! git_run -C "$dir" checkout -q "$rev"; then
                echo "  ERROR: clone failed for $name" >&2
                failures=$((failures + 1))
                continue
            fi
        fi
    fi

    # Submodule policy.
    #
    # NOT "update --recursive for every repo": SDL_image vendors nine image codecs (aom, dav1d,
    # libavif, libjxl + its own nested tree, libtiff, libwebp, ...) that this port never builds.
    # SDLIMAGE_VENDORED defaults to OFF on non-Android/MSVC, so SDL3_image links the libpng from
    # build/ohos-prefix instead. Pulling them costs gigabytes and routinely dies on flaky clones
    # (libjxl/third_party/brotli is the usual casualty), so only SuperTux's three build-required
    # submodules are fetched.
    case "$name" in
        SuperTux)
            echo "  updating required submodules"
            if ! git_run -C "$dir" submodule update --init --recursive --depth 1 \
                    external/tinygettext external/sexp-cpp external/simplesquirrel; then
                echo "  WARNING: submodule update failed for $name" >&2
            fi
            ;;
        *)
            if [ -f "$dir/.gitmodules" ]; then
                echo "  skipping submodules (not needed by this port's build)"
            fi
            ;;
    esac

    head="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    echo "  at $head"
done < "$VERSIONS"

if [ "$SKIP_PATCHES" -eq 1 ]; then
    echo
    echo "--skip-patches: leaving the trees pristine (the port will not build like this)"
    exit 0
fi

echo
echo "=== applying patches ==="
apply_patch() {
    local target="$THIRD_PARTY/$1"
    local patch="$REPO_ROOT/patches/$2"
    if [ ! -f "$patch" ]; then
        echo "  $2: not found, skipping"
        return 0
    fi
    if [ ! -d "$target" ]; then
        echo "  $2: target tree $1 missing, skipping"
        return 0
    fi
    if git -C "$target" apply --check --whitespace=nowarn "$patch" >/dev/null 2>&1; then
        git -C "$target" apply --whitespace=nowarn "$patch" \
            && echo "  $2 -> $1" \
            || echo "  $2: apply failed"
    else
        echo "  $2: does not apply cleanly (already applied, or the revision moved)"
    fi
}

apply_patch SDL      sdl-ohos.patch
apply_patch SuperTux supertux-ohos.patch
apply_patch deps/openal openal-ohos-sdl3.patch

echo
if [ "$failures" -ne 0 ]; then
    echo "Done with $failures failure(s). Review the messages above." >&2
    exit 1
fi
echo "Done. Next: scripts/build-ohos-deps.sh"
