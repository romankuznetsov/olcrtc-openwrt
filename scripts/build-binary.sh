#!/usr/bin/env bash
#
# Phase 1 -- cross-compile the olcRTC binary from the pinned upstream commit.
#
#   ./scripts/build-binary.sh <openwrt-arch> [outdir]
#
# Example:
#   ./scripts/build-binary.sh aarch64_cortex-a53 ./out
#
# Requires the Go version named in UPSTREAM. Nothing else -- olcRTC is pure Go
# and builds with CGO disabled, which is why adding an architecture costs one
# line in the table below.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/UPSTREAM"

ARCH="${1:?usage: build-binary.sh <openwrt-arch> [outdir]}"
OUTDIR="${2:-$REPO_ROOT/out}"

# OpenWrt architecture -> Go target. GOARM only applies to 32-bit ARM.
# GOMIPS would be added here (softfloat) if MIPS is ever re-introduced.
case "$ARCH" in
    aarch64_cortex-a53) GOARCH=arm64 GOARM="" ;;
    aarch64_cortex-a72) GOARCH=arm64 GOARM="" ;;
    arm_cortex-a7)      GOARCH=arm   GOARM=7 ;;
    x86_64)             GOARCH=amd64 GOARM="" ;;
    *) echo "unknown architecture: $ARCH" >&2; exit 1 ;;
esac

command -v go >/dev/null || { echo "go toolchain not found (need $GO)" >&2; exit 1; }

HAVE_GO="$(go env GOVERSION | sed 's/^go//')"
if [ "$HAVE_GO" != "$GO" ]; then
    echo "warning: UPSTREAM pins Go $GO but 'go' is $HAVE_GO" >&2
    echo "         builds may differ from CI; continuing" >&2
fi

SRC="${OLCRTC_SRC:-$REPO_ROOT/.build/olcrtc-src}"
mkdir -p "$(dirname "$SRC")" "$OUTDIR"

# Fetch exactly the pinned commit. A shallow fetch of one revision keeps this
# fast and makes it obvious that the pin -- not a branch -- is what we build.
if [ ! -d "$SRC/.git" ]; then
    echo "==> cloning $REPO"
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$REPO"
fi
echo "==> fetching $REF"
git -C "$SRC" fetch -q --depth 1 origin "$REF"
git -C "$SRC" checkout -q FETCH_HEAD

GOT="$(git -C "$SRC" rev-parse HEAD)"
[ "$GOT" = "$REF" ] || { echo "checkout mismatch: got $GOT want $REF" >&2; exit 1; }
echo "    at $GOT"

OUT="$OUTDIR/olcrtc-$ARCH"
echo "==> building $ARCH (GOARCH=$GOARCH${GOARM:+ GOARM=$GOARM})"

# -trimpath strips local filesystem paths, so the binary does not leak the
# build machine's directory layout. -s -w drops the symbol table and DWARF.
# Flags match upstream's own buildBinary().
env CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" ${GOARM:+GOARM=$GOARM} \
    go -C "$SRC" build -trimpath -ldflags "-s -w" -o "$OUT" ./cmd/olcrtc

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
SHA=$(sha256sum "$OUT" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$OUT" | cut -d' ' -f1)

printf '==> %s\n    %s bytes (%s MiB)\n    sha256 %s\n' \
    "$OUT" "$SIZE" "$((SIZE / 1048576))" "$SHA"

echo "$SHA  $(basename "$OUT")" > "$OUT.sha256"
