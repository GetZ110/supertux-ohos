#!/usr/bin/env bash
#
# build-supertux-hap.sh -- bash port of scripts/build-supertux-hap.ps1
#
# Package the cross-built SuperTux into a HarmonyOS HAP, sign it, and (optionally) install, launch
# and verify it on a connected device.
#
# Run scripts/build-supertux-ohos.sh first: build/supertux/libmain.so must exist.
#
# Steps:
#   1. walk libmain.so's ELF NEEDED list (recursively) and copy every non-system shared library
#      into app/supertux-ohos/entry/libs/arm64-v8a/, which is where hvigor packages prebuilt
#      native libraries from. libSDL3.so gets special treatment: ArkTS loads it by the plain
#      "libSDL3.so" name (XComponent libraryname + `import sdl from 'libSDL3.so'`), so the
#      versioned file must NOT also be present -- with both, HarmonyOS loads the library twice and
#      each copy gets its own globals, which makes SDL_CreateWindow fail with "Don't have Native
#      XComponent or Native Window". SDL is built without a SOVERSION here (patches/sdl-ohos.patch)
#      so libmain.so asks for "libSDL3.so" too.
#   2. build resources/rawfile/data.zip from SuperTux's data/ directory (music/ excluded by
#      default: it is ~145 MB of the ~346 MB and optional). The ArkTS shell extracts this into the
#      app sandbox at first launch, because PhysFS cannot read the HAP's rawfile space.
#   3. hvigorw assembleHap.
#   4. sign with hap-sign-tool. hvigor's own signingConfigs want DevEco's encrypted password
#      format, so the HAP is signed after the fact instead.
#   5. install with hdc, launch, dump hilog, take a screenshot.
#
# Signing material is never read from the repository: point --cert/--profile/--keystore at your own
# AppGallery Connect debug certificate, provisioning profile and keystore, and pass the password via
# --key-pwd or the SUPERTUX_OHOS_KEY_PWD environment variable. See docs/signing-howto.md.
#
# Usage:
#   scripts/build-supertux-hap.sh
#   scripts/build-supertux-hap.sh --skip-data-zip --skip-install
#   scripts/build-supertux-hap.sh --include-music --log-seconds 30
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLT="${OHOS_CLT:-${COMMAND_LINE_TOOL_PATH:-/storage/Users/currentUser/deveco_tools}}"
NATIVE="${OHOS_NATIVE:-}"
PACKAGE_SDK="${OHOS_PACKAGE_SDK:-$CLT/sdk}"

PROJECT="$REPO_ROOT/app/supertux-ohos"
BUILD="$REPO_ROOT/build/supertux"
PREFIX="$REPO_ROOT/build/ohos-prefix"
DATA_DIR="$REPO_ROOT/third_party/SuperTux/data"
SIGNING_DIR="$REPO_ROOT/signing"

CERT=""
PROFILE=""
KEYSTORE=""
KEY_ALIAS="debugKey"
KEY_PWD="${SUPERTUX_OHOS_KEY_PWD:-}"
BUNDLE_NAME="com.supertux.game"
ABILITY="EntryAbility"
DEVICE=""
LOG_SECONDS=20
COMPAT_VERSION=""
INCLUDE_MUSIC=0
SKIP_PACKAGE=0
SKIP_INSTALL=0
SKIP_DATA_ZIP=0
SKIP_SIGN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --clt)              CLT="${2:-}"; shift 2 ;;
        --clt=*)            CLT="${1#*=}"; shift ;;
        --native)           NATIVE="${2:-}"; shift 2 ;;
        --native=*)         NATIVE="${1#*=}"; shift ;;
        --package-sdk)      PACKAGE_SDK="${2:-}"; shift 2 ;;
        --package-sdk=*)    PACKAGE_SDK="${1#*=}"; shift ;;
        --project)          PROJECT="${2:-}"; shift 2 ;;
        --project=*)        PROJECT="${1#*=}"; shift ;;
        --build)            BUILD="${2:-}"; shift 2 ;;
        --build=*)          BUILD="${1#*=}"; shift ;;
        --prefix)           PREFIX="${2:-}"; shift 2 ;;
        --prefix=*)         PREFIX="${1#*=}"; shift ;;
        --data-dir)         DATA_DIR="${2:-}"; shift 2 ;;
        --data-dir=*)       DATA_DIR="${1#*=}"; shift ;;
        --signing-dir)      SIGNING_DIR="${2:-}"; shift 2 ;;
        --signing-dir=*)    SIGNING_DIR="${1#*=}"; shift ;;
        --cert)             CERT="${2:-}"; shift 2 ;;
        --cert=*)           CERT="${1#*=}"; shift ;;
        --profile)          PROFILE="${2:-}"; shift 2 ;;
        --profile=*)        PROFILE="${1#*=}"; shift ;;
        --keystore)         KEYSTORE="${2:-}"; shift 2 ;;
        --keystore=*)       KEYSTORE="${1#*=}"; shift ;;
        --key-alias)        KEY_ALIAS="${2:-}"; shift 2 ;;
        --key-alias=*)      KEY_ALIAS="${1#*=}"; shift ;;
        --key-pwd)          KEY_PWD="${2:-}"; shift 2 ;;
        --key-pwd=*)        KEY_PWD="${1#*=}"; shift ;;
        --bundle-name)      BUNDLE_NAME="${2:-}"; shift 2 ;;
        --bundle-name=*)    BUNDLE_NAME="${1#*=}"; shift ;;
        --ability)          ABILITY="${2:-}"; shift 2 ;;
        --ability=*)        ABILITY="${1#*=}"; shift ;;
        --device|-t)        DEVICE="${2:-}"; shift 2 ;;
        --device=*)         DEVICE="${1#*=}"; shift ;;
        --log-seconds)      LOG_SECONDS="${2:-}"; shift 2 ;;
        --log-seconds=*)    LOG_SECONDS="${1#*=}"; shift ;;
        --compatible-version)   COMPAT_VERSION="${2:-}"; shift 2 ;;
        --compatible-version=*) COMPAT_VERSION="${1#*=}"; shift ;;
        --include-music)    INCLUDE_MUSIC=1; shift ;;
        --skip-package)     SKIP_PACKAGE=1; shift ;;
        --skip-install)     SKIP_INSTALL=1; shift ;;
        --skip-data-zip)    SKIP_DATA_ZIP=1; shift ;;
        --skip-sign)        SKIP_SIGN=1; shift ;;
        -h|--help)          sed -n '2,38p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$NATIVE" ]; then
    NATIVE="$CLT/sdk/default/openharmony/native"
fi
READELF="$NATIVE/llvm/bin/llvm-readelf"
CMAKE="$NATIVE/build-tools/cmake/bin/cmake"
HVIGOR="$CLT/hvigor/bin/hvigorw"
HDC="$(command -v hdc || echo "$CLT/sdk/default/openharmony/toolchains/hdc")"
# The signing tool lives under the SDK's toolchains dir, not under native/. Current SDKs ship a
# native binary; older ones ship a .jar. Probe both layouts and both names.
SIGN_TOOL_BIN=""
SIGN_TOOL_JAR=""
for cand in \
    "$CLT/sdk/default/openharmony/toolchains/lib/hap-sign-tool" \
    "$NATIVE/../toolchains/lib/hap-sign-tool" \
    "$NATIVE/toolchains/lib/hap-sign-tool" \
    "$NATIVE/llvm/../toolchains/lib/hap-sign-tool"; do
    if [ -z "$SIGN_TOOL_BIN" ] && [ -f "$cand" ]; then SIGN_TOOL_BIN="$cand"; fi
done
for cand in \
    "$CLT/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar" \
    "$NATIVE/../toolchains/lib/hap-sign-tool.jar" \
    "$NATIVE/toolchains/lib/hap-sign-tool.jar"; do
    if [ -z "$SIGN_TOOL_JAR" ] && [ -f "$cand" ]; then SIGN_TOOL_JAR="$cand"; fi
done

[ -z "$CERT" ]     && CERT="$SIGNING_DIR/debug.cer"
[ -z "$PROFILE" ]  && PROFILE="$SIGNING_DIR/debug.p7b"
[ -z "$KEYSTORE" ] && KEYSTORE="$SIGNING_DIR/debug.p12"

# Fall back to whatever single-file material actually sits in signing/ (e.g. an AGC profile named
# after the app). Only used when the canonical debug.* names are absent.
discover_signing() {
    [ -e "$PROFILE" ] || {
        cand="$(ls -1 "$SIGNING_DIR"/*.p7b 2>/dev/null | head -1)"
        [ -n "$cand" ] && PROFILE="$cand"
    }
    [ -e "$CERT" ] || {
        cand="$(ls -1 "$SIGNING_DIR"/*.cer 2>/dev/null | head -1)"
        [ -n "$cand" ] && CERT="$cand"
    }
    [ -e "$KEYSTORE" ] || {
        cand="$(ls -1 "$SIGNING_DIR"/*.p12 2>/dev/null | head -1)"
        [ -n "$cand" ] && KEYSTORE="$cand"
    }
}

LIB_OUT="$PROJECT/entry/libs/arm64-v8a"
RAW_OUT="$PROJECT/entry/src/main/resources/rawfile"
OUT_DIR="$PROJECT/entry/build/default/outputs/default"

step() { echo; echo "=== $* ==="; }
fail() { echo "FAILED: $*" >&2; exit 1; }
have() { [ -e "$1" ]; }
mbsize() { awk -v b="$1" 'BEGIN{printf "%.1f MB", b/1048576}'; }

# hdc wrapper pinned to one device when several are attached.
hdc_() {
    if [ -n "$DEVICE" ]; then "$HDC" -t "$DEVICE" "$@"; else "$HDC" "$@"; fi
}
# Auto-select the device when --device was not given.
#
# `hdc list targets` can list more than one entry: a USB phone plus loopback/TCP targets such as
# "127.0.0.1:43817". Taking the first line is therefore a trap -- it silently picks the TCP one,
# and `aa start` then fails with "bundle does not exist". Prefer a GENUINE serial (a USB device id
# like FMR0223A31018476) and only fall back to a TCP target when no USB device is attached.
if [ -z "$DEVICE" ]; then
    TARGETS="$("$HDC" list targets 2>/dev/null | tr -d '\r' | grep -v '^\[Empty\]$')"
    DEVICE="$(printf '%s\n' "$TARGETS" | grep -vE '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+$' | grep -v '^$' | head -1)"
    if [ -z "$DEVICE" ]; then
        DEVICE="$(printf '%s\n' "$TARGETS" | grep -v '^$' | head -1)"
    fi
    if [ -n "$DEVICE" ]; then
        echo "auto-selected device: $DEVICE"
    fi
fi

# --------------------------------------------------------------------------- 1. libs
step "1. collect shared libraries needed by libmain.so"

LIBMAIN="$BUILD/libmain.so"
have "$LIBMAIN" || fail "libmain.so not found at $LIBMAIN -- run scripts/build-supertux-ohos.sh first"
echo "libmain.so: $(mbsize "$(stat -c%s "$LIBMAIN")")"

# HarmonyOS provides these at runtime; never ship them.
SYSTEM_LIB_RE='^lib(c|m|dl|z|unwind|EGL|GLESv3|GLESv2|native_window|hilog|ace|deviceinfo|rawfile|native_image|native_buffer|native_vsync|pixelmap|image|ohaudio|OpenSLES|bundle|ability|ipc|utils|hidumper|hitrace|ffrt|crypto|ssl|xml2|sqlite|webview|display_manager|pasteboard|udmf|ohcamera|ohimage|image_receiver|ohbattery|ohcommonevent|ability_runtime|net|huks|ace_napi|ace_ndk)'

needed_of() {
    "$READELF" -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'
}

mkdir -p "$LIB_OUT"
find "$LIB_OUT" -maxdepth 1 -name '*.so*' -delete 2>/dev/null

search_dirs=("$PREFIX/lib" "$BUILD" "$BUILD/external/simplesquirrel" "$NATIVE/llvm/lib/aarch64-linux-ohos")

declare -A seen
queue=("$LIBMAIN")
while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    while read -r dep; do
        [ -z "$dep" ] && continue
        [ -n "${seen[$dep]:-}" ] && continue
        seen[$dep]=1

        if printf '%s' "$dep" | grep -qE "$SYSTEM_LIB_RE"; then
            continue
        fi

        found=""
        plain="$(printf '%s' "$dep" | sed 's/\.so\..*$/.so/')"
        for d in "${search_dirs[@]}"; do
            for cand in "$dep" "$plain"; do
                if [ -e "$d/$cand" ]; then found="$d/$cand"; break; fi
            done
            [ -n "$found" ] && break
        done

        if [ -n "$found" ]; then
            cp -f "$found" "$LIB_OUT/$dep"
            echo "  + $dep  <- $found"
            if [ "$dep" != "$plain" ]; then
                if [ "$plain" = "libSDL3.so" ]; then
                    # Keep the unversioned name only; see the header comment.
                    cp -f "$found" "$LIB_OUT/$plain"
                    rm -f "$LIB_OUT/$dep"
                    echo "  = $plain kept, $dep dropped (ArkTS loads libSDL3.so by name)"
                else
                    cp -f "$found" "$LIB_OUT/$plain"
                    echo "  + $plain  (unversioned alias)"
                fi
            fi
            queue+=("$found")
        else
            echo "  ? $dep  (not found locally -- assuming the system provides it)"
        fi
    done < <(needed_of "$cur")
done

cp -f "$LIBMAIN" "$LIB_OUT/libmain.so"
echo "  + libmain.so (SuperTux)"

LIBCXX="$NATIVE/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
if have "$LIBCXX" && ! have "$LIB_OUT/libc++_shared.so"; then
    cp -f "$LIBCXX" "$LIB_OUT/libc++_shared.so"
    echo "  + libc++_shared.so"
fi

echo
echo "entry/libs/arm64-v8a:"
ls -la "$LIB_OUT" | awk 'NR>3{printf "  %-34s %10s\n", $9, $5}'

# ----------------------------------------------------------------------- 2. data.zip
step "2. build resources/rawfile/data.zip"
mkdir -p "$RAW_OUT"
ZIP="$RAW_OUT/data.zip"

if [ "$SKIP_DATA_ZIP" -eq 1 ] && have "$ZIP"; then
    echo "data.zip already present: $(mbsize "$(stat -c%s "$ZIP")") (skipped)"
else
    have "$DATA_DIR" || fail "no SuperTux data at $DATA_DIR -- run scripts/fetch-sources.sh first"

    STAGE="$(dirname "$PREFIX")/data-stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"

    for entry in "$DATA_DIR"/* "$DATA_DIR"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        if [ "$name" = "music" ] && [ "$INCLUDE_MUSIC" -eq 0 ]; then
            continue
        fi
        cp -Rf "$entry" "$STAGE/"
    done
    staged=$(du -sb "$STAGE" 2>/dev/null | cut -f1)
    echo "staged data: $(mbsize "${staged:-0}")"

    rm -f "$ZIP"
    ( cd "$STAGE" && "$CMAKE" -E tar cf "$ZIP" --format=zip . ) >/dev/null 2>&1 \
        || ( cd "$STAGE" && zip -qr "$ZIP" . ) \
        || fail "failed to create data.zip"
    echo "data.zip: $(mbsize "$(stat -c%s "$ZIP")")"
    rm -rf "$STAGE"
fi

# --------------------------------------------------------------------------- 3. hap
if [ "$SKIP_PACKAGE" -eq 0 ]; then
    step "3. hvigorw assembleHap"
    export DEVECO_SDK_HOME="$PACKAGE_SDK"
    # The command-line tools ship their own node; hvigor needs it on PATH.
    export PATH="$CLT/node/bin:$PATH"
    have "$HVIGOR" || fail "hvigorw not found at $HVIGOR"
    ( cd "$PROJECT" && "$HVIGOR" --no-daemon assembleHap 2>&1 ) \
        | grep -E 'ERROR|BUILD SUCCESSFUL|BUILD FAILED|WARN: No signingConfig' \
        | tail -10
fi

if have "$OUT_DIR"; then
    echo
    ls -la "$OUT_DIR"/*.hap 2>/dev/null | awk '{printf "  %-46s %10s\n", $9, $5}'
fi

# -------------------------------------------------------------------------- 3b. sign
UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
SIGNED="$OUT_DIR/entry-default-signed.hap"
if have "$UNSIGNED" && [ "$SKIP_SIGN" -eq 0 ]; then
    step "3b. sign with hap-sign-tool"
    discover_signing
    for p in "$CERT" "$PROFILE" "$KEYSTORE"; do
        have "$p" || fail "missing signing material: $p

Put your own AppGallery Connect debug certificate, profile and keystore in $SIGNING_DIR
(or pass --cert/--profile/--keystore), and provide the keystore password with --key-pwd or the
SUPERTUX_OHOS_KEY_PWD environment variable. See docs/signing-howto.md."
    done
    [ -n "$KEY_PWD" ] || fail "no keystore password: pass --key-pwd or set SUPERTUX_OHOS_KEY_PWD"

    # Default the signing tool's compatibleVersion to the HAP's own compatibleSdkVersion.
    if [ -z "$COMPAT_VERSION" ]; then
        v="$(grep -oE '"compatibleSdkVersion"[^,]*' "$PROJECT/build-profile.json5" | head -1 | grep -oE '[0-9]+' | tail -1)"
        COMPAT_VERSION="${v:-26}"
    fi

    sign_args=(-keyAlias "$KEY_ALIAS" -keyPwd "$KEY_PWD" -signAlg SHA256withECDSA -mode localSign
               -appCertFile "$CERT" -profileFile "$PROFILE"
               -inFile "$UNSIGNED" -outFile "$SIGNED"
               -keystoreFile "$KEYSTORE" -keystorePwd "$KEY_PWD"
               -compatibleVersion "$COMPAT_VERSION" -signCode 1)

    if have "$SIGN_TOOL_BIN"; then
        "$SIGN_TOOL_BIN" sign-app "${sign_args[@]}" 2>&1 | tail -4
    elif have "$SIGN_TOOL_JAR"; then
        java -jar "$SIGN_TOOL_JAR" sign-app "${sign_args[@]}" 2>&1 | tail -4
    else
        fail "hap-sign-tool not found (looked for $SIGN_TOOL_BIN and $SIGN_TOOL_JAR)"
    fi

    have "$SIGNED" && echo "signed HAP: $(mbsize "$(stat -c%s "$SIGNED")")"
fi

# ------------------------------------------------------------------- 4. install/run
if [ "$SKIP_INSTALL" -eq 0 ]; then
    step "4. install + launch + logs"
    if have "$SIGNED"; then HAP="$SIGNED"; else HAP="$UNSIGNED"; fi
    have "$HAP" || fail 'no HAP produced'

    echo "device: ${DEVICE:-(none)}"
    hdc_ install -r "$HAP" 2>&1 | tail -3
    hdc_ shell 'hilog -r' >/dev/null 2>&1
    hdc_ shell "aa start -a $ABILITY -b $BUNDLE_NAME" 2>&1 | tail -3
    sleep "$LOG_SECONDS"

    mkdir -p "$SIGNING_DIR"
    LOG_FILE="$SIGNING_DIR/hilog-supertux.txt"
    hdc_ shell 'hilog -x -e "supertux|SuperTux|SDL" -v time' 2>&1 | tr -d '\r' > "$LOG_FILE"
    echo
    echo "--- hilog (filtered, tail) ---"
    tail -40 "$LOG_FILE"

    step "5. screenshot"
    remote=/data/local/tmp/supertux.jpeg
    hdc_ shell "snapshot_display -f $remote" 2>&1 | tail -1
    SHOT="$SIGNING_DIR/supertux-screen.jpeg"
    hdc_ file recv "$remote" "$SHOT" 2>&1 | tail -1
    have "$SHOT" && echo "screenshot: $SHOT ($(stat -c%s "$SHOT") bytes)"
fi
