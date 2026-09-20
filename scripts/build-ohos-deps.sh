#!/usr/bin/env bash
#
# build-ohos-deps.sh -- bash port of scripts/build-ohos-deps.ps1
#
# Cross-build every third-party library SuperTux needs on HarmonyOS (API 26, arm64-v8a) into one
# prefix: build/ohos-prefix.
#
# Run scripts/fetch-sources.sh first: this script only builds, it does not download.
#
#   Already built outside this script (they are SDL's own CMake projects and are built by the two
#   scripts after this one, against the same prefix):
#     * SDL3       -> build/sdl       (also built on demand here, core only, as OpenAL's prerequisite)
#     * SDL3_image -> build/sdl-image
#     * SDL3_ttf   -> build/sdl-ttf
#
# Notes that cost real debugging time:
#   * zlib comes from the OHOS sysroot, nothing to build.
#   * OHOS cannot link executables, so tests/samples are disabled everywhere.
#   * The OHOS toolchain pins CMAKE_FIND_ROOT_PATH to the SDK sysroot, so a prefix outside it is
#     invisible to find_library() unless it is appended to CMAKE_FIND_ROOT_PATH.
#   * OpenAL Soft: master needs C++20 std::lexicographical_compare_three_way (absent from OHOS's
#     libc++), so 1.23.1 is used; and its AL_API export macro comes from a check_c_source_compiles()
#     probe that fails when cross-compiling, leaving the library with ZERO exported symbols unless
#     HAVE_GCC_DEFAULT_VISIBILITY is forced on.
#
# Usage:
#   scripts/build-ohos-deps.sh
#   scripts/build-ohos-deps.sh --only libpng,freetype
#   scripts/build-ohos-deps.sh --list-only
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLT="${OHOS_CLT:-${COMMAND_LINE_TOOL_PATH:-/storage/Users/currentUser/deveco_tools}}"
# The native cross-compile SDK is selectable independently of the packaging SDK. On this machine the
# HarmonyOS command-line tools under deveco_tools ship an API 23 native SDK, while the port's native
# code is written against API 26; point OHOS_NATIVE at an API 26 native tree when one is available.
NATIVE="${OHOS_NATIVE:-}"
COMPAT_SDK="${OHOS_COMPATIBLE_SDK_VERSION:-26}"

THIRD_PARTY="$REPO_ROOT/third_party"
PREFIX="$REPO_ROOT/build/ohos-prefix"
JOBS="$(nproc 2>/dev/null || echo 8)"
ONLY=""
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --only)          ONLY="${2:-}"; shift 2 ;;
        --only=*)        ONLY="${1#*=}"; shift ;;
        --clt)           CLT="${2:-}"; shift 2 ;;
        --clt=*)         CLT="${1#*=}"; shift ;;
        --native)        NATIVE="${2:-}"; shift 2 ;;
        --native=*)      NATIVE="${1#*=}"; shift ;;
        --compatible-sdk)   COMPAT_SDK="${2:-}"; shift 2 ;;
        --compatible-sdk=*) COMPAT_SDK="${1#*=}"; shift ;;
        --third-party)   THIRD_PARTY="${2:-}"; shift 2 ;;
        --third-party=*) THIRD_PARTY="${1#*=}"; shift ;;
        --prefix)        PREFIX="${2:-}"; shift 2 ;;
        --prefix=*)      PREFIX="${1#*=}"; shift ;;
        --jobs|-j)       JOBS="${2:-}"; shift 2 ;;
        --jobs=*)        JOBS="${1#*=}"; shift ;;
        --list-only)     LIST_ONLY=1; shift ;;
        -h|--help)       sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Derive the native SDK paths only after parsing, so --native / --clt take effect.
if [ -z "$NATIVE" ]; then
    NATIVE="$CLT/sdk/default/openharmony/native"
fi
CMAKE="$NATIVE/build-tools/cmake/bin/cmake"
NINJA="$NATIVE/build-tools/cmake/bin/ninja"
TOOLCHAIN="$NATIVE/build/cmake/ohos.toolchain.cmake"

# The SDK ships cmake/ninja without the execute bit when unpacked by some toolchains; make sure
# they can actually be run instead of failing with a bare "Permission denied".
for tool in "$CMAKE" "$NINJA"; do
    if [ -f "$tool" ] && [ ! -x "$tool" ]; then chmod +x "$tool" 2>/dev/null || true; fi
done

for tool in "$CMAKE" "$NINJA" "$TOOLCHAIN"; do
    if [ ! -e "$tool" ]; then
        echo "not found: $tool (pass --clt <path to Huawei command line tools>)" >&2
        exit 1
    fi
done

DEPS="libpng physfs fmt glm freetype ogg vorbis openal"

# OpenAL's output backend on OHOS is SDL3's audio subsystem (SDL3 -> OHAudio). That means OpenAL
# needs SDL3's headers and libSDL3.so already installed in the prefix when it is configured, but
# build-sdl-ohos.sh normally runs *after* this script. Rather than reordering the documented
# pipeline (SDL3_image/SDL3_ttf need libpng/freetype from this script, so SDL3 would have to be
# split in half), build the SDL3 core here on demand as a prerequisite; the later
# build-sdl-ohos.sh run just rebuilds it and adds SDL3_image/SDL3_ttf.
openal_sdl3_args() {
    if [ -f "$PREFIX/include/SDL3/SDL.h" ] && [ -f "$PREFIX/lib/libSDL3.so" ]; then
        echo "-DALSOFT_BACKEND_SDL3=ON -DALSOFT_REQUIRE_SDL3=ON -DSDL3_INCLUDE_DIR=$PREFIX/include -DSDL3_LIBRARY=$PREFIX/lib/libSDL3.so"
    fi
}

dep_args() {
    case "$1" in
        libpng)   echo "-DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF" ;;
        physfs)   echo "-DPHYSFS_BUILD_SHARED=ON -DPHYSFS_BUILD_STATIC=OFF -DPHYSFS_BUILD_TEST=OFF -DPHYSFS_BUILD_DOCS=OFF" ;;
        fmt)      echo "-DFMT_TEST=OFF -DFMT_DOC=OFF -DBUILD_SHARED_LIBS=ON" ;;
        glm)      echo "-DGLM_BUILD_TESTS=OFF -DBUILD_SHARED_LIBS=OFF" ;;
        freetype) echo "-DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DBUILD_SHARED_LIBS=ON" ;;
        ogg)      echo "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF" ;;
        vorbis)   echo "-DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF" ;;
        openal)   echo "-DLIBTYPE=SHARED -DALSOFT_EXAMPLES=OFF -DALSOFT_UTILS=OFF -DALSOFT_TESTS=OFF -DHAVE_GCC_DEFAULT_VISIBILITY=1 -DALSOFT_BACKEND_ALSA=OFF -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_OSS=OFF -DALSOFT_BACKEND_SNDIO=OFF -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_PIPEWIRE=OFF -DALSOFT_BACKEND_WAVE=ON -DALSOFT_BACKEND_NULL=ON $(openal_sdl3_args)" ;;
        *)        echo "" ;;
    esac
}

if [ "$LIST_ONLY" -eq 1 ]; then
    for d in $DEPS; do echo "$d"; done
    exit 0
fi

mkdir -p "$PREFIX"

# Build the SDL3 core first when OpenAL is part of this run and SDL3 is not in the prefix yet.
want_openal=0
if [ -z "$ONLY" ]; then want_openal=1
else case ",$ONLY," in *",openal,"*) want_openal=1 ;; esac; fi

if [ "$want_openal" -eq 1 ] && [ ! -f "$PREFIX/include/SDL3/SDL.h" ]; then
    echo
    echo "================ SDL3 (prerequisite of OpenAL) ================"
    if ! "$SCRIPT_DIR/build-sdl-ohos.sh" --skip-image --skip-ttf --prefix "$PREFIX"; then
        echo "WARNING: SDL3 prerequisite build failed; OpenAL will be built without an output backend" >&2
    fi
fi

summary=""
for d in $DEPS; do
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$d,"*) ;; *) continue ;; esac
    fi

    src="$THIRD_PARTY/deps/$d"
    bld="$(dirname "$PREFIX")/deps/$d"
    echo
    echo "================ $d ================"

    if [ ! -f "$src/CMakeLists.txt" ]; then
        echo "SKIP $d: no sources at $src -- run scripts/fetch-sources.sh first"
        summary="$summary$d sources-missing"$'\n'
        continue
    fi

    mkdir -p "$bld"

    # shellcheck disable=SC2086
    if ! "$CMAKE" -G Ninja -S "$src" -B "$bld" \
            -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
            -DCMAKE_BUILD_TYPE=Release \
            -DOHOS_COMPATIBLE_SDK_VERSION="$COMPAT_SDK" \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_PREFIX_PATH="$PREFIX" \
            -DCMAKE_FIND_ROOT_PATH="$NATIVE;$PREFIX" \
            -DCMAKE_MAKE_PROGRAM="$NINJA" \
            $(dep_args "$d") > "$bld.configure.log" 2>&1; then
        echo "CONFIGURE FAILED: $d"
        grep -E 'CMake Error' "$bld.configure.log" 2>/dev/null | head -6
        summary="$summary$d configure-failed"$'\n'
        continue
    fi
    echo "configure ok"

    if "$CMAKE" --build "$bld" -j "$JOBS" > "$bld.build.log" 2>&1; then
        buildOk=1
        grep -E 'Linking' "$bld.build.log" | tail -3
    else
        buildOk=0
        echo "BUILD FAILED: $d"
        grep -E 'error:|FAILED' "$bld.build.log" | head -8
    fi

    if "$CMAKE" --install "$bld" > "$bld.install.log" 2>&1; then
        installOk=1
    else
        installOk=0
        echo "INSTALL FAILED: $d"
        tail -5 "$bld.install.log"
    fi

    if [ "$buildOk" -eq 1 ] && [ "$installOk" -eq 1 ]; then status=ok
    elif [ "$buildOk" -eq 1 ]; then status=built-no-install
    else status=build-failed; fi

    echo "$d: $status"
    summary="$summary$d $status"$'\n'
done

echo
echo "================ summary ================"
printf '%s' "$summary"
echo "prefix: $PREFIX"
echo
echo "installed shared libraries:"
ls -la "$PREFIX/lib"/*.so* 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}'
