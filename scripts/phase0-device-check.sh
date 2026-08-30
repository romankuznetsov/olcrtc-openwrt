#!/bin/sh
# Phase 0 device checks for olcrtc-openwrt.
#
# Read-only. Changes nothing, installs nothing, writes nothing outside /tmp.
# Run on the target router:
#
#     scp scripts/phase0-device-check.sh root@<router>:/tmp/
#     ssh root@<router> sh /tmp/phase0-device-check.sh
#
# Exit 0 = no blockers. Exit 1 = at least one blocker; read the FAIL lines.

set -u

PASS=0
WARN=0
FAIL=0

ok()   { printf '  [ ok ] %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARN=$((WARN + 1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n== %s\n' "$*"; }

printf 'olcrtc-openwrt :: Phase 0 device checks\n'

# ---------------------------------------------------------------- platform
head_ "Platform"

if [ -r /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    ok "OpenWrt ${DISTRIB_RELEASE:-?} (${DISTRIB_ARCH:-?})"
    REL="${DISTRIB_RELEASE:-}"
    ARCH="${DISTRIB_ARCH:-}"
else
    bad "not OpenWrt, or /etc/openwrt_release unreadable"
    REL=""
    ARCH=""
fi

case "$ARCH" in
    aarch64_cortex-a53|aarch64_cortex-a72|arm_cortex-a7|x86_64)
        ok "architecture is in the build matrix" ;;
    "") warn "architecture unknown; cannot confirm a matching artifact" ;;
    *)  warn "architecture '$ARCH' is not in the build matrix -- add it to .github/workflows/build.yml" ;;
esac

# Package manager decides apk vs ipk. Check what is actually installed rather
# than inferring from the release number.
if command -v apk >/dev/null 2>&1; then
    ok "package manager: apk (expected on 25.12+)"
    PKGFMT=apk
elif command -v opkg >/dev/null 2>&1; then
    ok "package manager: opkg (expected on 24.10 and earlier)"
    PKGFMT=ipk
else
    bad "neither apk nor opkg found"
    PKGFMT=""
fi

case "${REL}:${PKGFMT}" in
    25.12*:ipk) warn "25.12 with opkg is unexpected -- verify which artifact to install" ;;
    24.10*:apk) warn "24.10 with apk is unexpected -- verify which artifact to install" ;;
esac

# ------------------------------------------------------------- check 3: uidrange
head_ "Check 3: 'ip rule uidrange' (loop prevention)"

if ! command -v ip >/dev/null 2>&1; then
    bad "iproute2 'ip' not installed"
else
    # Add a rule for an unused high uid, then remove it. Harmless either way.
    _UID=65099
    if ip rule add uidrange "${_UID}-${_UID}" lookup main pref 30999 2>/dev/null; then
        ip rule del pref 30999 2>/dev/null || true
        ok "uidrange supported -- primary loop-prevention design works"
    else
        warn "uidrange NOT supported -- falling back to nftables 'meta skuid' + policy route"
        warn "  (not a blocker; it changes Phase 3 implementation only)"
    fi
fi

# ------------------------------------------------------------- TUN + sing-box
head_ "TUN and sing-box"

if [ -c /dev/net/tun ]; then
    ok "/dev/net/tun present"
elif [ -e /dev/net/tun ]; then
    warn "/dev/net/tun exists but is not a character device"
else
    if command -v modprobe >/dev/null 2>&1 && modprobe tun 2>/dev/null && [ -c /dev/net/tun ]; then
        ok "/dev/net/tun available after 'modprobe tun'"
    else
        bad "no /dev/net/tun -- install kmod-tun; the TUN data path requires it"
    fi
fi

if command -v sing-box >/dev/null 2>&1; then
    SBV=$(sing-box version 2>/dev/null | head -1)
    ok "sing-box installed: ${SBV:-unknown}"
    case "$SBV" in
        *1.12*) ok "  -> will use the 1.12 config template" ;;
        *1.13*) ok "  -> will use the 1.13 config template" ;;
        *)      warn "  -> unrecognised version; no config template exists for it yet" ;;
    esac
else
    warn "sing-box not installed yet (the package depends on it; this is expected pre-install)"
fi

# ------------------------------------------------------- check 4: SFU reachability
head_ "Check 4: SFU reachability"

# Only TCP/443 to a public Jitsi instance is tested. No account, no room
# created, nothing joined -- this establishes that the signalling path is not
# blocked, not that a tunnel works.
SFU_HOST="${SFU_HOST:-meet.jit.si}"
if command -v uclient-fetch >/dev/null 2>&1; then
    if uclient-fetch -q -O /dev/null --timeout=10 "https://${SFU_HOST}/" 2>/dev/null; then
        ok "HTTPS to ${SFU_HOST} succeeded"
    else
        warn "HTTPS to ${SFU_HOST} failed -- try another instance (docs/jitsi.instances.yaml upstream)"
    fi
elif command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 -o /dev/null "https://${SFU_HOST}/"; then
        ok "HTTPS to ${SFU_HOST} succeeded"
    else
        warn "HTTPS to ${SFU_HOST} failed -- try another instance"
    fi
else
    warn "no uclient-fetch or curl; skipped"
fi

# ------------------------------------------------------------------ storage
head_ "Storage"

AVAIL_KB=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
[ -z "$AVAIL_KB" ] && AVAIL_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAIL_KB" ]; then
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [ "$AVAIL_MB" -ge 120 ]; then
        ok "${AVAIL_MB} MB free -- ample for olcrtc + sing-box"
    elif [ "$AVAIL_MB" -ge 60 ]; then
        warn "${AVAIL_MB} MB free -- tight; olcrtc plus sing-box is roughly 40-60 MB"
    else
        bad "${AVAIL_MB} MB free -- not enough"
    fi
else
    warn "could not determine free space"
fi

# ------------------------------------------------------------------- netifd
head_ "netifd"

if [ -d /lib/netifd/proto ]; then
    ok "/lib/netifd/proto exists (protocol handler install path)"
else
    bad "/lib/netifd/proto missing -- netifd protocol handlers unsupported"
fi

if [ -d /www/luci-static/resources/protocol ]; then
    ok "LuCI protocol resource dir exists"
else
    warn "LuCI protocol dir missing -- install luci before luci-proto-olcrtc"
fi

# ------------------------------------------------------------------ summary
printf '\n== Summary\n  pass %d   warn %d   fail %d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf '\nBlockers found. Resolve the FAIL lines before Phase 3.\n'
    exit 1
fi
printf '\nNo blockers. Warnings are design inputs, not stoppers.\n'
exit 0
