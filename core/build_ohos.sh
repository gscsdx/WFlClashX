#!/usr/bin/env bash
#
# Cross-compile the Clash core (mihomo) for OpenHarmony / HarmonyOS NEXT
# as a c-shared library (libclash_core.so, arm64).
#
# The OHOS build reuses the same cgo callback architecture as Android:
# no gomobile / JVM involved. The host side (ohos/entry NAPI bridge)
# registers C trampolines via registerCallbacks() and receives events
# through setEventListener().
#
# Prerequisites
# --------------
# 1. OHOS Go toolchain reporting an openharmony/arm64 target:
#      <toolchain>/bin/go tool dist list | grep openharmony
#    Community toolchains: gitee openharmony-sig (ohos_golang) or a Go
#    1.26+ release that ships GOOS=openharmony.
# 2. OpenHarmony / HarmonyOS NDK (ships with DevEco Studio under
#    <sdk>/default/openharmony/native), providing
#    native/llvm/bin/aarch64-unknown-linux-ohos-clang and the musl sysroot.
#
# Environment
# -----------
#   OHOS_GO      path to the OHOS Go toolchain binary (required)
#   OHOS_NDK     path to the OHOS NDK native/ dir (required)
#   OUT          output directory (default: ../ohos/libs/arm64)
#
# Usage
# -----
#   OHOS_GO=/path/to/ohos-go/bin/go OHOS_NDK=/path/to/native ./build_ohos.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/../ohos/entry/libs/arm64-v8a}"

: "${OHOS_GO:?set OHOS_GO to an OHOS Go toolchain (bin/go)}"
: "${OHOS_NDK:?set OHOS_NDK to the OHOS NDK native/ directory}"

GO="$OHOS_GO"
CLANG="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
SYSROOT="$OHOS_NDK/sysroot"

# On Windows hosts the wrapper script aarch64-unknown-linux-ohos-clang is a
# POSIX shell shim and cannot run; call clang.exe directly with the same
# target flags (the shim is only: clang -target aarch64-linux-ohos --sysroot=... -D__MUSL__).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Convert the POSIX OHOS_NDK path to a Windows-absolute path FIRST, then
    # derive CLANG/SYSROOT from it. cgo execs clang.exe directly WITHOUT MSYS
    # path conversion, so (a) a POSIX sysroot like /d/... is NOT resolved by
    # clang (C headers such as stdlib.h go missing) and (b) Go itself rejects a
    # CC that does not look Windows-absolute ("CC environment variable is
    # relative"). Forward slashes (D:/...) are preferred over backslashes here
    # because CC is later embedded in a single-quoted shell string.
    OHOS_NDK_W="$(cygpath -w "$OHOS_NDK" 2>/dev/null || echo "$OHOS_NDK")"
    OHOS_NDK_W="${OHOS_NDK_W//\\//}"
    SYSROOT="$OHOS_NDK_W/sysroot"
    CLANG="$OHOS_NDK_W/llvm/bin/clang.exe"
    CLANG_FLAGS=(-target aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__)
    ;;
  *)
    CLANG_FLAGS=(--sysroot="$SYSROOT")
    ;;
esac

if ! "$GO" tool dist list | grep -q '^openharmony/arm64'; then
  echo "error: $GO does not report openharmony/arm64 in 'go tool dist list'" >&2
  exit 1
fi

if [ ! -x "$CLANG" ]; then
  echo "error: clang not found at $CLANG" >&2
  exit 1
fi

mkdir -p "$OUT"

# GOTOOLCHAIN=local: the ohos toolchain must not try to download a stock Go
# toolchain when go.mod declares a newer version (it would lack the target).
env \
  GOROOT="$("$GO" env GOROOT)" \
  GOTOOLCHAIN=local \
  GOOS=openharmony \
  GOARCH=arm64 \
  CGO_ENABLED=1 \
  CC="$(printf '%q ' "$CLANG" "${CLANG_FLAGS[@]}")" \
  GOPROXY="${GOPROXY:-https://goproxy.cn,direct}" \
  "$GO" build \
    -trimpath \
    -tags "${TAGS:-with_gvisor}" \
    -ldflags="-s -w -extldflags=-Wl,-soname,libclash_core.so" \
    -buildmode=c-shared \
    -o "$OUT/libclash_core.so" \
    .

echo "OK: $OUT/libclash_core.so"
echo
echo "Next steps:"
echo "  1. Copy libclash_core.so into ohos/entry/libs/arm64-v8a/ (or reference"
echo "     it from ohos/entry/oh-package.json5 as a local .so dependency)."
echo "  2. Build the HAP: cd ohos && hvigorw assembleHap"
echo "     (or: flutter build hap --target-platform ohos-arm64)"
