#!/usr/bin/env bash
#
# Phase S -- provision the olcRTC server on a fresh Ubuntu 24.04 LTS x86_64 VPS.
#
# READ THIS BEFORE RUNNING IT. It is meant to be reviewed, not trusted.
#
# What it does, in order:
#   1. apt update + security upgrades, enable unattended-upgrades
#   2. create an unprivileged system account (no shell, no home, no login)
#   3. install the olcrtc binary from a source YOU name, verifying SHA-256
#   4. generate a 32-byte shared key, mode 0640 root:olcrtc
#   5. write the server config (mode: srv)
#   6. install a hardened systemd unit and start it
#   7. ufw: default-deny inbound, SSH only        [--with-firewall]
#   8. SSH: disable password auth                 [--with-ssh-hardening]
#
# Steps 7 and 8 are OPT-IN because they can lock you out of a remote host.
# Both are applied last, and step 8 refuses to run unless it can prove you
# already have a working authorized_keys entry.
#
# WHAT IT NEVER DOES
#   - no `curl | bash`; every download is checksum-verified before use
#   - no secrets printed to logs, and none written into this repository
#   - no inbound port is opened: olcRTC's server has no listener at all
#     (verified upstream: internal/server/ contains no net.Listen)
#
# It is idempotent. Re-running updates in place rather than duplicating state.
#
# Usage:
#   sudo ./provision-server.sh --binary ./olcrtc --room https://meet.example.org/my-room
#   sudo ./provision-server.sh --binary-url URL --binary-sha256 SHA --room URL
#   sudo ./provision-server.sh --dry-run --binary ./olcrtc      # print, change nothing
#
set -euo pipefail

SERVICE_USER=olcrtc
CONF_DIR=/etc/olcrtc
STATE_DIR=/var/lib/olcrtc
BIN_PATH=/usr/local/bin/olcrtc
UNIT=/etc/systemd/system/olcrtc.service
KEY_FILE="$CONF_DIR/olcrtc.key"
CONF_FILE="$CONF_DIR/server.yaml"

PROVIDER=jitsi
TRANSPORT=datachannel
DNS_ADDR="1.1.1.1:53"
ROOM=""
BINARY=""
BINARY_URL=""
BINARY_SHA256=""
DRY_RUN=0
WITH_FIREWALL=0
WITH_SSH=0

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi
}

usage() { sed -n '2,40p' "$0"; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)              BINARY="$2"; shift 2 ;;
        --binary-url)          BINARY_URL="$2"; shift 2 ;;
        --binary-sha256)       BINARY_SHA256="$2"; shift 2 ;;
        --room)                ROOM="$2"; shift 2 ;;
        --provider)            PROVIDER="$2"; shift 2 ;;
        --transport)           TRANSPORT="$2"; shift 2 ;;
        --dns)                 DNS_ADDR="$2"; shift 2 ;;
        --with-firewall)       WITH_FIREWALL=1; shift ;;
        --with-ssh-hardening)  WITH_SSH=1; shift ;;
        --dry-run)             DRY_RUN=1; shift ;;
        -h|--help)             usage ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# ----------------------------------------------------------------- preflight
say "Preflight"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    [ "${ID:-}" = "ubuntu" ] || info "WARNING: written and tested for Ubuntu; continuing anyway"
else
    die "/etc/os-release unreadable; cannot identify the distribution"
fi

ARCH=$(uname -m)
info "Arch: $ARCH"
[ "$ARCH" = "x86_64" ] || info "WARNING: expected x86_64; make sure the binary matches"

command -v systemctl >/dev/null || die "systemd required"

# A binary source must be named explicitly. Defaulting to a download URL is how
# supply-chain accidents happen, so this fails closed instead.
if [ -n "$BINARY" ]; then
    [ -f "$BINARY" ] || die "--binary '$BINARY' not found"
    info "Binary source: local file $BINARY"
elif [ -n "$BINARY_URL" ]; then
    [ -n "$BINARY_SHA256" ] || die "--binary-url requires --binary-sha256 (refusing to install an unverified binary)"
    info "Binary source: $BINARY_URL"
else
    die "no binary source. Pass --binary <path>, or --binary-url <url> --binary-sha256 <sha>.
    Until the Phase 1 release pipeline exists, build it yourself:
      git clone $(grep -oP '(?<=^REPO=).*' "$(dirname "$0")/../UPSTREAM" 2>/dev/null || echo https://github.com/openlibrecommunity/olcrtc) olcrtc-src
      cd olcrtc-src && git checkout <REF from UPSTREAM>
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o olcrtc ./cmd/olcrtc"
fi

if [ -z "$ROOM" ]; then
    if [ -f "$CONF_FILE" ]; then
        info "No --room given; keeping the room already in $CONF_FILE"
    else
        die "--room is required on first run, e.g. --room https://meet.example.org/<random-name>
    Pick an instance from upstream docs/jitsi.instances.yaml and a long random room name.
    Generate one:  openssl rand -hex 12"
    fi
fi

[ "$DRY_RUN" = 1 ] && info "DRY RUN -- nothing will be changed"

# ------------------------------------------------------------ 1. base system
say "1/8  Base system"

export DEBIAN_FRONTEND=noninteractive
run "apt-get update -qq"
run "apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade"
run "apt-get -y -qq install ca-certificates openssl curl unattended-upgrades"
run "systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true"
info "security updates enabled"

# ------------------------------------------------------------ 2. service user
say "2/8  Service account"

if id "$SERVICE_USER" >/dev/null 2>&1; then
    info "user '$SERVICE_USER' already exists"
else
    run "useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin '$SERVICE_USER'"
    info "created system user '$SERVICE_USER' (no shell, no home)"
fi

run "install -d -m 0750 -o root -g '$SERVICE_USER' '$CONF_DIR'"
run "install -d -m 0750 -o '$SERVICE_USER' -g '$SERVICE_USER' '$STATE_DIR'"

# ---------------------------------------------------------------- 3. binary
say "3/8  Binary"

TMPBIN=$(mktemp)
trap 'rm -f "$TMPBIN"' EXIT

if [ -n "$BINARY" ]; then
    run "cp '$BINARY' '$TMPBIN'"
else
    run "curl -fsSL --proto '=https' --tlsv1.2 -o '$TMPBIN' '$BINARY_URL'"
fi

if [ -n "$BINARY_SHA256" ] && [ "$DRY_RUN" = 0 ]; then
    GOT=$(sha256sum "$TMPBIN" | awk '{print $1}')
    [ "$GOT" = "$BINARY_SHA256" ] || die "checksum mismatch
    expected $BINARY_SHA256
    got      $GOT"
    info "SHA-256 verified"
elif [ "$DRY_RUN" = 0 ]; then
    info "SHA-256: $(sha256sum "$TMPBIN" | awk '{print $1}')  (local file, not verified against a published sum)"
fi

run "install -m 0755 -o root -g root '$TMPBIN' '$BIN_PATH'"
# olcrtc takes exactly one argument -- the config path. There is no --version
# flag, so identify the build by size and hash rather than asking it.
if [ "$DRY_RUN" = 0 ]; then
    info "installed $BIN_PATH ($(stat -c%s "$BIN_PATH" 2>/dev/null || echo '?') bytes)"
fi

# ------------------------------------------------------------------- 4. key
say "4/8  Shared key"

if [ -s "$KEY_FILE" ]; then
    info "key already present -- keeping it (delete $KEY_FILE to rotate)"
else
    run "umask 077 && openssl rand -hex 32 > '$KEY_FILE'"
    run "chown root:'$SERVICE_USER' '$KEY_FILE'"
    run "chmod 0640 '$KEY_FILE'"
    info "generated a new 32-byte key"
    info "the router needs this exact value -- print it with the command shown at the end"
fi

# ---------------------------------------------------------------- 5. config
say "5/8  Server config"

if [ -z "$ROOM" ] && [ -f "$CONF_FILE" ]; then
    ROOM=$(awk '/^room:/{f=1;next} f&&/id:/{gsub(/.*id:[ ]*"?|"?[ ]*(#.*)?$/,""); print; exit}' "$CONF_FILE")
fi

if [ "$DRY_RUN" = 0 ]; then
    umask 027
    cat > "$CONF_FILE" <<YAML
# olcRTC server -- generated by provision-server.sh
# Client and server must agree on provider, room, transport and key,
# or the link silently never forms.

mode: srv

auth:
  provider: $PROVIDER

room:
  id: "$ROOM"

crypto:
  key_file: "$KEY_FILE"

net:
  transport: $TRANSPORT
  dns: "$DNS_ADDR"

liveness:
  interval: 10s
  timeout: 15s
  failures: 4

socks:
  proxy_addr: ""
  proxy_port: 0

debug: false
YAML
    chown root:"$SERVICE_USER" "$CONF_FILE"
    chmod 0640 "$CONF_FILE"
fi
info "provider=$PROVIDER transport=$TRANSPORT"
info "room=$ROOM"

# ------------------------------------------------------------------ 6. unit
say "6/8  systemd unit"

# Hardening notes -- two of these are load-bearing and easy to get wrong:
#
#   AF_NETLINK is REQUIRED. Go's net package enumerates interfaces over
#   netlink, and olcRTC's internal/protect walks them to filter ICE
#   candidates. Removing it breaks candidate gathering in a way that looks
#   like a network fault, not a sandbox denial.
#
#   MemoryDenyWriteExecute is deliberately ABSENT. Go does not JIT so it
#   should be safe, but it is verified before being enabled rather than
#   assumed. See docs/server-setup.md.
if [ "$DRY_RUN" = 0 ]; then
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=olcRTC server
Documentation=https://github.com/openlibrecommunity/olcrtc
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_PATH $CONF_FILE
WorkingDirectory=$STATE_DIR
Restart=always
RestartSec=5s

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
ReadWritePaths=$STATE_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
UNITEOF
    chmod 0644 "$UNIT"
fi

run "systemctl daemon-reload"
run "systemctl enable olcrtc >/dev/null 2>&1"
run "systemctl restart olcrtc"

if [ "$DRY_RUN" = 0 ]; then
    sleep 3
    if systemctl is-active --quiet olcrtc; then
        info "service is running"
    else
        info "service is NOT running -- diagnose with: journalctl -u olcrtc -n 50 --no-pager"
    fi
fi

# -------------------------------------------------------------- 7. firewall
say "7/8  Firewall"

if [ "$WITH_FIREWALL" = 1 ]; then
    run "apt-get -y -qq install ufw"
    run "ufw --force default deny incoming"
    run "ufw --force default allow outgoing"
    run "ufw allow OpenSSH"
    run "ufw --force enable"
    info "default-deny inbound, SSH permitted"
    info "no port opened for olcRTC -- its server has no listener"
else
    info "skipped (pass --with-firewall to apply)"
    info "olcRTC needs NO inbound port; a default-deny inbound policy is safe"
fi

# ------------------------------------------------------- 8. ssh hardening
say "8/8  SSH hardening"

if [ "$WITH_SSH" = 1 ]; then
    KEYS_FOUND=0
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [ -s "$f" ] && KEYS_FOUND=1
    done
    if [ "$KEYS_FOUND" = 0 ]; then
        info "REFUSING: no non-empty authorized_keys found anywhere."
        info "Disabling password auth now would lock you out. Add your key first."
    else
        run "install -d -m 0755 /etc/ssh/sshd_config.d"
        if [ "$DRY_RUN" = 0 ]; then
            cat > /etc/ssh/sshd_config.d/60-olcrtc-hardening.conf <<'SSHEOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHEOF
        fi
        if run "sshd -t"; then
            run "systemctl reload ssh"
            info "password authentication disabled"
            info "KEEP THIS SESSION OPEN and verify a NEW one before closing it."
            info "Undo: rm /etc/ssh/sshd_config.d/60-olcrtc-hardening.conf && systemctl reload ssh"
        else
            info "sshd config test FAILED -- reverting"
            run "rm -f /etc/ssh/sshd_config.d/60-olcrtc-hardening.conf"
        fi
    fi
else
    info "skipped (pass --with-ssh-hardening to apply)"
fi

# ----------------------------------------------------------------- summary
say "Done"
cat <<SUMMARY

  Service   systemctl status olcrtc
  Logs      journalctl -u olcrtc -f
  Config    $CONF_FILE
  Key       $KEY_FILE   (mode 0640, root:$SERVICE_USER)

  The router must be configured with the SAME four values:

      provider   $PROVIDER
      room       $ROOM
      transport  $TRANSPORT
      key        <see below>

  Print the key for out-of-band transfer to the router:

      sudo cat $KEY_FILE

  Transfer it over a channel you trust. Do not paste it into a chat window, a
  git repository, or an unencrypted config backup. It is the only thing
  authenticating the two ends to each other.

SUMMARY
