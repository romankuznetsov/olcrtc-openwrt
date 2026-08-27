# olcRTC for OpenWrt — implementation plan

**Status: awaiting confirmation.** Nothing has been built yet. This document is the proposal.

## What this is

An OpenWrt package that runs the [olcRTC](https://github.com/openlibrecommunity/olcrtc) client
on a router and transparently routes LAN traffic through it, so no device on the network needs
any client-side configuration.

Distributed as an **apk** package — OpenWrt's package format since 24.10, built on Alpine's
`apk-tools`. This is unrelated to Android APKs. An **ipk** is produced from the same build for
OpenWrt 23.05 and earlier.

The package is architecture-agnostic by construction: adding a router family is one row in a
build matrix, because olcRTC is pure Go and builds with `CGO_ENABLED=0`.

---

## The constraint that shapes everything

olcRTC's client is a **SOCKS5 proxy that speaks CONNECT only, and its server egress dials
`tcp4`**. Verified in the upstream source rather than inferred:

- `internal/client/socks.go` — `socks5Request` rejects any command byte other than `1`, so
  there is no `UDP ASSOCIATE` (`0x03`) and no `BIND` (`0x02`).
- `internal/server/egress.go` — `dialer.Dial("tcp4", addr)`, hardcoded.

**Consequence: the tunnel carries TCP over IPv4. It cannot carry UDP, and it cannot carry
IPv6.** Every design decision below follows from this. Three things break if it is ignored:

| Traffic | What happens if unhandled |
|---|---|
| DNS (UDP/53) | Cannot traverse the tunnel. Resolves via the router's normal path — a plaintext leak that also reveals every domain visited. |
| QUIC / HTTP3 (UDP/443) | Cannot traverse. Browsers prefer it, so pages hang until they fall back, or fail outright. |
| IPv6 | Cannot traverse. If the LAN has working IPv6, that traffic exits the WAN in the clear while the user believes they are tunnelled. |

That last row is not hypothetical. It is the single most serious defect found in
`SpaceNeuroX/qwdtt-openwrt`, the closest comparable project in this survey — it is IPv4-only by
construction and never tells the operator to disable IPv6. **This package fails closed on all
three by default** (see Phase 4).

---

## Architecture

```
LAN device (no configuration)
    │
    ▼
br-lan
    │  nftables: TCP → REDIRECT to 127.0.0.1:1088
    │            UDP/443 → reject   (forces QUIC→TCP fallback)
    │            IPv6 forward → reject
    ▼
redsocks            reads SO_ORIGINAL_DST, forwards to SOCKS5
    │
    ▼
olcrtc cnc          SOCKS5 on 127.0.0.1:8808  (CONNECT only)
    │
    ▼
WebRTC datachannel / VP8 track → SFU (Jitsi, Telemost, WB Stream)
    │
    ▼
olcrtc srv (your VPS) ──▶ internet
```

**Why `REDIRECT` + redsocks rather than `tproxy` + sing-box.** REDIRECT is DNAT to a local
port; the original destination is recovered via `SO_ORIGINAL_DST`. It works for TCP only —
which is all we have — and avoids `kmod-nft-tproxy`, a policy routing rule and a `local` route
in a separate table. redsocks is a small C daemon; sing-box is a Go binary of roughly the same
size as olcRTC itself, which would double the flash footprint to buy UDP support the tunnel
cannot use anyway.

Phase 0 verifies redsocks is present in the target feed for each architecture. If it is not,
the fallback is sing-box with a `tproxy` inbound and a `socks` outbound, at a cost of roughly
20 MB.

### Preventing the routing loop

olcRTC's own signalling and WebRTC media must reach the SFU *outside* the tunnel. If its
traffic is redirected into its own SOCKS5 listener the tunnel deadlocks on startup.

SFU addresses are dynamic, so an IP allowlist will not hold. Instead the daemon runs as a
dedicated system user and nftables exempts that user's traffic:

```
chain output {
    type nat hook output priority -100;
    meta skuid $olcrtc_uid return       # olcrtc's own traffic never redirected
    ...
}
```

This is stable across SFU changes, provider switches and failover profiles, and it is the same
class of fix `qwdtt-openwrt` implements with `iif br-lan` policy routing — but keyed on process
identity rather than interface, so it also protects traffic the router itself originates.

---

## Repository layout

```
_olcrtc-openwrt/
├── UPSTREAM                          # pinned upstream repo + commit + Go version
├── README.md
├── docs/
│   ├── plan.md                       # this file
│   ├── install.md                    # end-user install
│   └── troubleshoot.md               # leak checks, log reading
├── .github/workflows/
│   ├── build.yml                     # matrix build, runs on every push/PR
│   └── release.yml                   # tag → apk + ipk + checksums + feed index
├── scripts/
│   ├── build-binary.sh               # cross-compile olcrtc from the pin
│   ├── mkpkg-apk.sh                  # wrap prebuilt binary as apk
│   ├── mkpkg-ipk.sh                  # wrap prebuilt binary as ipk
│   └── leak-check.sh                 # run on-device, asserts no DNS/IPv6/UDP escape
└── package/
    ├── olcrtc/                       # base: binary, procd service, UCI, SOCKS5
    │   ├── Makefile
    │   └── files/{olcrtc.init, olcrtc.config, olcrtc.uci-defaults}
    └── olcrtc-tproxy/                # transparent routing: nftables, redsocks, DNS
        ├── Makefile
        └── files/{olcrtc-tproxy.init, firewall.nft, redsocks.conf.template}
```

Two packages rather than one, so the routing layer — the part that can take the LAN down — can
be removed without losing the tunnel. `olcrtc-tproxy` depends on `olcrtc`; installing it pulls
both.

---

## Configuration

UCI is the source of truth. The init script renders olcRTC's YAML from it at every start, so
users never hand-edit YAML and `/etc/config/olcrtc` survives sysupgrade normally.

```
config olcrtc 'main'
    option enabled       '0'          # fail-safe default: install ≠ enable
    option mode          'tproxy'     # 'tproxy' (whole LAN) | 'socks' (endpoint only)
    option provider      'jitsi'      # jitsi | telemost | wbstream
    option room          ''           # room URL, must match the server
    option transport     'datachannel'
    option key_file      '/etc/olcrtc/olcrtc.key'   # 0600, not in UCI
    option socks_port    '8808'
    option redsocks_port '1088'
    option lan_zone      'lan'
    option block_quic    '1'          # reject UDP/443 so browsers fall back to TCP
    option block_ipv6    '1'          # reject IPv6 forwarding; prevents clear-text leak
    option dns_mode      'dot'        # 'dot' | 'doh' | 'off'

list bypass_cidr '192.168.0.0/16'     # RFC1918 + multicast bypassed by default
list bypass_mac  ''                   # devices excluded from the tunnel
```

The 32-byte key lives in a `0600` file referenced by `key_file`, never inline in UCI — upstream
supports `crypto.key_file` for exactly this. `enabled '0'` by default means installing the
package cannot silently reroute someone's network.

---

## Build pipeline

**Source.** Pinned upstream commit, built with the official Go toolchain rather than the
OpenWrt SDK's — upstream requires Go 1.26.3, which is newer than the SDK ships. The SDK is used
only to assemble packages around the prebuilt binary, which is the standard binary-package
pattern and sidesteps the version mismatch entirely.

```
# UPSTREAM
REPO=https://github.com/openlibrecommunity/olcrtc
REF=f616f57bb3a90740f1755922ffeaa7acc5cfe4ed   # master @ 2026-08-18
GO=1.26.3
```

Bumping upstream is a one-line edit. A scheduled CI job compares the pin against upstream
`master` and opens an issue when they diverge, so the pin is deliberate rather than forgotten.

**Matrix.** Confirmed targets:

| OpenWrt arch | GOARCH | Notes |
|---|---|---|
| `aarch64_cortex-a53` | `arm64` | Primary target |
| `aarch64_cortex-a72` | `arm64` | Higher-end ARM platforms |
| `arm_cortex-a7` | `arm` + `GOARM=7` | 32-bit ARM |
| `x86_64` | `amd64` | VM/container CI testing without hardware |

MIPS is deliberately excluded. Those devices typically ship 8–32 MB of flash and the binary
will not fit; adding them later is one matrix row plus `GOMIPS=softfloat` if that changes.

**Build command** (identical to upstream's own, which already sets these):

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=$goarm \
  go build -trimpath -ldflags "-s -w" -o olcrtc ./cmd/olcrtc
```

**Gates.** `build.yml` runs on every push and PR: `go vet`, upstream's own test suite at the
pinned commit, a shellcheck pass over the init scripts, and a package-lint step asserting the
procd script declares `START`/`STOP` and the Makefile declares its dependencies. A build that
produces a binary but fails a gate does not publish.

**Release.** Tag `v*` → build all four architectures → emit apk and ipk per arch → generate
`SHA256SUMS` → sign → publish a GitHub Release and a static apk/opkg feed index so installation
is `apk add olcrtc-tproxy` after adding one feed line. Unsigned artifacts are not published;
several projects in this survey ship binaries with no integrity story at all, and that is worth
not repeating.

---

## Phases

Each phase is independently verifiable. Phase 0 exists because it can kill the approach, and
should run before anything else is written.

### Phase 0 — Feasibility (do this first)

1. **Measure the binary.** Cross-compile for `arm64` and record the stripped size. olcRTC pulls
   pion/webrtc, livekit protocol, kcp-go and smux; my estimate is **18–25 MB stripped, 8–12 MB
   compressed in the package**, but this is an estimate — I could not build locally, as there
   is no Go toolchain on this machine. If it lands far above that, options are UPX (roughly
   halves it, complicates debugging), trimming unused transports, or requiring extroot.
2. **Measure RAM** under a sustained transfer. pion plus Go's GC on a router is the other
   plausible blocker.
3. **Confirm `redsocks`** exists in the target release feed for each architecture; if not,
   switch to sing-box and revise the flash budget.
4. **Confirm a room reaches the SFU from the router's network** at all, before building
   packaging around it.

**Go/no-go:** if the binary exceeds free overlay space on a mainstream router, the package
becomes extroot-only and that changes the install story materially.

### Phase 1 — Build pipeline
Cross-compile from the pin across the matrix; publish artifacts with checksums. Deliverable: a
downloadable binary per architecture, reproducible from a clean checkout.

### Phase 2 — Base package (`olcrtc`)
procd init script with `respawn`, UCI schema, UCI→YAML rendering, dedicated system user,
`0600` key file, logging to `logd`. Deliverable: `service olcrtc start` yields a working SOCKS5
listener on loopback, verified with `curl --socks5`.

### Phase 3 — Transparent routing (`olcrtc-tproxy`)
nftables REDIRECT for LAN TCP, redsocks bridging to SOCKS5, `meta skuid` loop-prevention
bypass, RFC1918 and multicast bypass sets, per-MAC exclusions, and a firewall zone integrated
via `/etc/config/firewall` rather than raw rules that sysupgrade will lose. Deliverable: an
unconfigured LAN device reaches the internet through the tunnel.

### Phase 4 — Leak prevention (the part that must not be skipped)
- **DNS:** run a TCP-based resolver — DoT via `stubby` (TCP/853) or DoH via `https-dns-proxy`
  (TCP/443) — and point dnsmasq at it on loopback. Its TCP traffic is redirected like any
  other, so resolution happens through the tunnel. `dns_mode 'off'` is available for users who
  accept plaintext DNS, but it is not the default.
- **QUIC:** reject forwarded UDP/443 so browsers fall back to TCP, rather than silently
  bypassing the tunnel.
- **IPv6:** reject IPv6 forwarding while the tunnel is up. Optionally stop advertising IPv6 on
  the LAN so clients never acquire an address they cannot use.
- **Kill-switch:** if olcRTC dies, LAN forwarding fails closed rather than falling back to the
  clear WAN path. procd restarts it; the firewall does not open in the gap.
- `scripts/leak-check.sh` asserts all four from the router and exits non-zero on any leak.

### Phase 5 — Distribution
apk and ipk from one build, a signed static feed, and `docs/install.md`. Deliverable:
`apk add olcrtc-tproxy` on a clean router.

### Phase 6 — On-device validation
Install on real hardware, run `leak-check.sh`, measure throughput and memory over a sustained
transfer, verify recovery across WAN loss, reboot and sysupgrade.

---

## Risks

**Flash footprint** is the main technical risk and Phase 0 quantifies it. A 20 MB Go binary is
large for a router even before redsocks and a DNS resolver.

**Throughput will be modest.** Traffic is TCP inside a WebRTC datachannel inside DTLS/SCTP,
reassembled by a Go userspace process on a router CPU. Treat this as a browsing and
whitelist-bypass path, not a bulk-transfer link, and measure before promising numbers.

**TCP-in-TCP meltdown.** Carrying TCP over a reliable datachannel stacks two congestion
controllers; under loss this degrades sharply. olcRTC's KCP transports exist partly to address
this, so Phase 6 should compare `datachannel` against KCP-backed profiles rather than assuming
the default is best.

**Upstream is a moving target.** olcRTC has one tag, no releases, a five-month history, 78% of
commits from one author, and four dependencies in maintainer-personal namespaces that have been
re-tagged in place. Pinning a commit is what makes this buildable at all; expect the pin to
need real testing on each bump rather than a rubber stamp.

**Sudden obsolescence.** The whole technique depends on a third party that has not agreed to be
depended upon. Any provider-side change can close it without warning, as happened to
`jaykaiperson/lionheart`. Nothing in this plan mitigates that; it is the cost of the category.

**Account risk.** Provider-backed profiles may associate the tunnel with a real account.
Default the documentation to Jitsi, which needs no account at all.

---

## Open questions

1. **Target OpenWrt release for the primary device** — 24.10, 25.12 or a vendor fork? It
   decides whether apk or ipk is the tested-first path. I have assumed apk-first with ipk built
   alongside.
2. **Free overlay space** on the primary device, which Phase 0 checks against the measured
   binary.
3. **Should CI deploy to a device for smoke testing?** Feasible via a self-hosted runner or an
   SSH deploy step. It would need a host and credentials held as secrets, and per your
   instruction no address or identifying detail would appear in the repository. Default
   assumption: **no** — Phase 6 stays manual.
4. **Server side.** This plan covers the router client only and assumes an `olcrtc srv` already
   running on a VPS with a matching room and key. Say if provisioning that should also be in
   scope.

---

## Confirm before I start

The concrete asks: approve the architecture (REDIRECT + redsocks over tproxy + sing-box), the
two-package split, the fail-closed defaults in Phase 4, and answer the four open questions
above. Phase 0 runs first regardless, since its result can change the shape of everything after
it.
