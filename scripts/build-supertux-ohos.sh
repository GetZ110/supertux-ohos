#!/usr/bin/env bash
#
# build-supertux-ohos.sh -- bash port of scripts/build-supertux-ohos.ps1
#
# Configure and build SuperTux for HarmonyOS (API 26, arm64-v8a) as libmain.so.
#
# Run scripts/fetch-sources.sh, build-ohos-deps.sh and build-sdl-ohos.sh first.
#
# Why this produces a shared library rather than an executable:
#   SDL3 on HarmonyOS cannot use an ANSI main(). SDL gains control of the app through ArkTS +
#   XComponent and then loads libmain.so and calls SDL_AppInit/SDL_AppIterate/SDL_AppEvent/
#   SDL_AppQuit from it (src/ohos/main_ohos.cpp in the patched SuperTux tree). src/main.cpp is
#   therefore excluded, and the target is named "main".
#
# Notes:
#   * ENABLE_NETWORKING=OFF drops the libcurl dependency; the patched file_system.cpp no longer
#     includes <curl/curl.h> unconditionally.
#   * ENABLE_OPENGL=OFF makes SuperTux use its SDL_Renderer video path, which is what SDL3's
#     HarmonyOS backend implements well (GLES2).
#   * physfs 3.3 exports PhysFS::PhysFS-shared but SuperTux's AddPackage.cmake wants
#     PhysFS::PhysFS, so an alias is appended to the installed config, and the package is looked up
#     with find_package instead of pkg-config.
#
# Usage:
#   scripts/build-supertux-ohos.sh
#   scripts/build-supertux-ohos.sh --reconfigure
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLT="${OHOS_CLT:-${COMMAND_LINE_TOOL_PATH:-/storage/Users/currentUser/deveco_tools}}"
NATIVE="${OHOS_NATIVE:-}"
COMPAT_SDK="${OHOS_COMPATIBLE_SDK_VERSION:-26}"

THIRD_PARTY="$REPO_ROOT/third_party"
BUILD="$REPO_ROOT/build/supertux"
PREFIX="$REPO_ROOT/build/ohos-prefix"
JOBS="$(nproc 2>/dev/null || echo 8)"
RECONFIGURE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --clt)              CLT="${2:-}"; shift 2 ;;
        --clt=*)            CLT="${1#*=}"; shift ;;
        --native)           NATIVE="${2:-}"; shift 2 ;;
        --native=*)         NATIVE="${1#*=}"; shift ;;
        --compatible-sdk)   COMPAT_SDK="${2:-}"; shift 2 ;;
        --compatible-sdk=*) COMPAT_SDK="${1#*=}"; shift ;;
        --third-party)      THIRD_PARTY="${2:-}"; shift 2 ;;
        --third-party=*)    THIRD_PARTY="${1#*=}"; shift ;;
        --build)            BUILD="${2:-}"; shift 2 ;;
        --build=*)          BUILD="${1#*=}"; shift ;;
        --prefix)           PREFIX="${2:-}"; shift 2 ;;
        --prefix=*)         PREFIX="${1#*=}"; shift ;;
        --jobs|-j)          JOBS="${2:-}"; shift 2 ;;
        --jobs=*)           JOBS="${1#*=}"; shift ;;
        --reconfigure)      RECONFIGURE=1; shift ;;
        -h|--help)          sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$NATIVE" ]; then
    NATIVE="$CLT/sdk/default/openharmony/native"
fi
CMAKE="$NATIVE/build-tools/cmake/bin/cmake"
NINJA="$NATIVE/build-tools/cmake/bin/ninja"
TOOLCHAIN="$NATIVE/build/cmake/ohos.toolchain.cmake"

for tool in "$CMAKE" "$NINJA"; do
    if [ -f "$tool" ] && [ ! -x "$tool" ]; then chmod +x "$tool" 2>/dev/null || true; fi
done

for tool in "$CMAKE" "$NINJA" "$TOOLCHAIN"; do
    if [ ! -e "$tool" ]; then
        echo "not found: $tool (pass --clt <path to Huawei command line tools>)" >&2
        exit 1
    fi
done

SRC="$THIRD_PARTY/SuperTux"
if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "no SuperTux sources at $SRC -- run scripts/fetch-sources.sh first" >&2
    exit 1
fi
if [ ! -f "$SRC/src/ohos/main_ohos.cpp" ]; then
    echo "SuperTux does not look patched (src/ohos/main_ohos.cpp missing) -- run scripts/fetch-sources.sh without --skip-patches" >&2
    exit 1
fi

echo "=== 1. submodules (external/tinygettext, sexp-cpp, simplesquirrel + nested squirrel) ==="
git -C "$SRC" submodule update --init --recursive --depth 1 \
    external/tinygettext external/sexp-cpp external/simplesquirrel 2>&1 | tail -4
for m in tinygettext sexp-cpp simplesquirrel; do
    printf '  %-16s ' "$m"
    if [ -f "$SRC/external/$m/CMakeLists.txt" ]; then echo "ok"; else echo "MISSING"; fi
done

echo
echo "=== 2. physfs target alias ==="
PHYSFS_CFG="$PREFIX/lib/cmake/PhysFS/PhysFSConfig.cmake"
if [ -f "$PHYSFS_CFG" ]; then
    if ! grep -q 'PhysFS::PhysFS ALIAS' "$PHYSFS_CFG"; then
        cat >> "$PHYSFS_CFG" <<'EOF'

# --- local HarmonyOS port shim -------------------------------------------------
# physfs 3.3 exports only PhysFS::PhysFS-shared / PhysFS::PhysFS-static, but SuperTux's
# mk/cmake/SuperTux/AddPackage.cmake expects the target PhysFS::PhysFS.
if(TARGET PhysFS::PhysFS-shared AND NOT TARGET PhysFS::PhysFS)
  add_library(PhysFS::PhysFS ALIAS PhysFS::PhysFS-shared)
endif()
# ------------------------------------------------------------------------------
EOF
        echo "  alias appended"
    else
        echo "  alias already present"
    fi
else
    echo "  WARNING: $PHYSFS_CFG not found -- run build-ohos-deps.sh first?"
fi

echo
echo "=== 3. configure SuperTux for OHOS ==="
if [ "$RECONFIGURE" -eq 1 ] && [ -d "$BUILD" ]; then
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"

if ! "$CMAKE" -G Ninja -S "$SRC" -B "$BUILD" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DCMAKE_BUILD_TYPE=Release \
        -DOHOS_COMPATIBLE_SDK_VERSION="$COMPAT_SDK" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$NATIVE;$PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_MAKE_PROGRAM="$NINJA" \
        -DENABLE_NETWORKING=OFF \
        -DENABLE_OPENGL=OFF \
        -DBUILD_TESTING=OFF \
        -DSUPERTUX_PCH=OFF \
        -DSUPERTUX_CCACHE=OFF \
        -DPhysFS_PREFER_FIND_PACKAGE=ON > "$BUILD.configure.log" 2>&1; then
    echo "SuperTux configure failed"
    grep -E 'CMake Error|error:' "$BUILD.configure.log" | head -20
    exit 1
fi
tail -3 "$BUILD.configure.log"

echo
echo "=== 4. build ==="
if ! "$CMAKE" --build "$BUILD" -j "$JOBS" > "$BUILD.build.log" 2>&1; then
    echo "SuperTux build failed"
    grep -E 'error:|FAILED' "$BUILD.build.log" | head -30
    exit 1
fi
grep -E 'Linking' "$BUILD.build.log" | tail -3

echo
find "$BUILD" -name 'libmain.so' -exec ls -la {} \;
