#!/usr/bin/env bash
#
# build-sdl-ohos.sh -- bash port of scripts/build-sdl-ohos.ps1
#
# Cross-build SDL3 and the two SDL3 satellite libraries SuperTux needs (SDL3_image, SDL3_ttf) for
# HarmonyOS, installing all three into build/ohos-prefix.
#
# Run scripts/fetch-sources.sh first: the trees under third_party/ must exist and already have
# patches/sdl-ohos.patch applied.
#
# Two things to know:
#   * OHOS cannot link executables ("undefined symbol: main" under -Wl,--no-undefined), so the
#     examples/tests are off and only the library targets are built. SDL_image's samples fail to
#     link for exactly that reason.
#   * SDL3 must be installed *before* SDL3_image/SDL3_ttf, because those two find it through
#     SDL3_DIR in the prefix.
#
# Usage:
#   scripts/build-sdl-ohos.sh
#   scripts/build-sdl-ohos.sh --skip-image --skip-ttf
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLT="${OHOS_CLT:-${COMMAND_LINE_TOOL_PATH:-/storage/Users/currentUser/deveco_tools}}"
NATIVE="${OHOS_NATIVE:-}"
COMPAT_SDK="${OHOS_COMPATIBLE_SDK_VERSION:-26}"

THIRD_PARTY="$REPO_ROOT/third_party"
BUILD_ROOT="$REPO_ROOT/build"
PREFIX="$REPO_ROOT/build/ohos-prefix"
JOBS="$(nproc 2>/dev/null || echo 8)"
SKIP_IMAGE=0
SKIP_TTF=0

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
        --build-root)       BUILD_ROOT="${2:-}"; shift 2 ;;
        --build-root=*)     BUILD_ROOT="${1#*=}"; shift ;;
        --prefix)           PREFIX="${2:-}"; shift 2 ;;
        --prefix=*)         PREFIX="${1#*=}"; shift ;;
        --jobs|-j)          JOBS="${2:-}"; shift 2 ;;
        --jobs=*)           JOBS="${1#*=}"; shift ;;
        --skip-image)       SKIP_IMAGE=1; shift ;;
        --skip-ttf)         SKIP_TTF=1; shift ;;
        -h|--help)          sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
if [ ! -f "$THIRD_PARTY/SDL/CMakeLists.txt" ]; then
    echo "no SDL sources at $THIRD_PARTY/SDL -- run scripts/fetch-sources.sh first" >&2
    exit 1
fi

mkdir -p "$PREFIX" "$BUILD_ROOT"

# configure_and_build <name> <source> <builddir> <extra-args...> --targets t1[,t2]
configure_and_build() {
    local name="$1" source="$2" build="$3"; shift 3
    local extra=() targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --targets) targets=("${2//,/ }"); shift 2 ;;
            *)         extra+=("$1"); shift ;;
        esac
    done

    echo
    echo "================ $name ================"
    if [ ! -f "$source/CMakeLists.txt" ]; then
        echo "SKIP: no sources at $source"
        return 1
    fi

    mkdir -p "$build"
    if ! "$CMAKE" -G Ninja -S "$source" -B "$build" \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
            -DCMAKE_BUILD_TYPE=Release \
            -DOHOS_COMPATIBLE_SDK_VERSION="$COMPAT_SDK" \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_PREFIX_PATH="$PREFIX" \
            -DCMAKE_FIND_ROOT_PATH="$NATIVE;$PREFIX" \
            -DCMAKE_MAKE_PROGRAM="$NINJA" \
            "${extra[@]}" > "$build.configure.log" 2>&1; then
        echo "CONFIGURE FAILED: $name"
        grep -E 'CMake Error' "$build.configure.log" | head -6
        return 1
    fi

    # shellcheck disable=SC2086
    local build_cmd=("$CMAKE" --build "$build")
    if [ "${#targets[@]}" -gt 0 ]; then
        build_cmd+=(--target "${targets[@]}")
    fi
    if ! "${build_cmd[@]}" -j "$JOBS" > "$build.build.log" 2>&1; then
        echo "BUILD FAILED: $name"
        grep -E 'error:|FAILED' "$build.build.log" | head -10
        return 1
    fi
    grep -E 'Linking' "$build.build.log" | tail -4

    if ! "$CMAKE" --install "$build" > "$build.install.log" 2>&1; then
        echo "INSTALL FAILED: $name"
        tail -5 "$build.install.log"
        return 1
    fi
    tail -1 "$build.install.log"
    echo "$name ok"
    return 0
}

# 1. SDL3 itself. -DSDL_SHARED only: one libSDL3.so, no tests/examples/install extras.
if ! configure_and_build SDL3 "$THIRD_PARTY/SDL" "$BUILD_ROOT/sdl" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF; then
    echo "SDL3 build failed" >&2
    exit 1
fi

SDL3_DIR="$PREFIX/lib/cmake/SDL3"

# 2. SDL3_image (stb backends; libpng comes from the prefix). SDLIMAGE_VENDORED defaults to OFF on
#    OHOS, which is what keeps the nine vendored codec submodules out of the build.
if [ "$SKIP_IMAGE" -eq 0 ]; then
    configure_and_build SDL3_image "$THIRD_PARTY/SDL_image" "$BUILD_ROOT/sdl-image" \
        -DBUILD_SHARED_LIBS=ON -DSDLIMAGE_TESTS=OFF "-DSDL3_DIR=$SDL3_DIR" \
        --targets SDL3_image-shared || true
fi

# 3. SDL3_ttf against the system FreeType from the prefix (no FetchContent: vendoring would pull
#    FreeType/HarfBuzz/plutosvg at configure time). Without HarfBuzz there is no complex-script
#    shaping and no colour emoji -- acceptable for a first port.
if [ "$SKIP_TTF" -eq 0 ]; then
    configure_and_build SDL3_ttf "$THIRD_PARTY/SDL_ttf" "$BUILD_ROOT/sdl-ttf" \
        -DBUILD_SHARED_LIBS=ON -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF \
        -DSDLTTF_SAMPLES=OFF -DSDLTTF_INSTALL=ON "-DSDL3_DIR=$SDL3_DIR" \
        --targets SDL3_ttf-shared || true
fi

echo
echo "prefix contents:"
ls -la "$PREFIX/lib" 2>/dev/null | awk '{printf "  %-44s %s\n", $9, $5}'
