# olcRTC for OpenWrt — implementation plan

**Status: awaiting confirmation.** Nothing has been built yet. This document is the proposal.

**Revision 2** — reworked after confirmation that the tunnel must appear as a managed interface
in LuCI, and that the target device has ample storage. Both changed the architecture; see
[What changed in revision 2](#what-changed-in-revision-2).

## What this is

An OpenWrt package that runs the [olcRTC](https://github.com/openlibrecommunity/olcrtc) client
on a router and exposes it as a **first-class network interface**. It appears under
Network → Interfaces in LuCI with working Start / Stop / Restart buttons and a configuration
form, is assignable to a firewall zone, and carries LAN traffic with no client-side setup on
any device.

| Target | Package format | Role |
|---|---|---|
| OpenWrt 25.12 | **apk** | Primary |
| OpenWrt 24.10 | **ipk** (opkg) | Built and published alongside |

Both come from one build. 24.10 predates the apk migration, so it takes ipk; 25.12 is the first
release where apk is the default. Phase 0 confirms this against the actual devices rather than
trusting the version numbers.

The package is architecture-agnostic by construction — adding a router family is one row in a
build matrix, because olcRTC is pure Go and builds with `CGO_ENABLED=0`.

---

## The constraint that shapes everything

olcRTC's client is a **SOCKS5 proxy that speaks CONNECT only, and its server egress dials
`tcp4`**. Verified in upstream source rather than inferred:

- `internal/client/socks.go` — `socks5Request` rejects any command byte other than `1`, so
  there is no `UDP ASSOCIATE` (`0x03`) and no `BIND` (`0x02`).
- `internal/server/egress.go` — `dialer.Dial("tcp4", addr)`, hardcoded.

**The tunnel carries TCP over IPv4. It cannot carry UDP, and it cannot carry IPv6.**

This matters *more* now that the design uses a TUN interface, not less. A TUN device accepts
every packet the routing table sends it — UDP, IPv6, everything — and the tunnel behind it can
only carry a subset. Anything else must be explicitly rejected at the interface, or it becomes
a silent failure or a leak:

| Traffic | Unhandled outcome |
|---|---|
| DNS (UDP/53) | Cannot traverse. Falls back to the router's normal resolver — a plaintext leak that also reveals every domain visited. |
| QUIC / HTTP3 (UDP/443) | Cannot traverse. Browsers prefer it, so pages stall until they fall back, or fail outright. |
| IPv6 | Cannot traverse. If the LAN has working IPv6, that traffic exits the WAN in the clear while the user believes they are tunnelled. |

The IPv6 row is not hypothetical: it is the most serious defect in `SpaceNeuroX/qwdtt-openwrt`,
the closest comparable project in this survey — IPv4-only by construction, with a README that
never tells the operator to disable IPv6. **This package fails closed on all three by default**
(Phase 4).

---

## Architecture

```
LAN device (no configuration)
    │
    ▼
br-lan ──▶ routing table ──▶ olcrtc0        ← real TUN device, managed by netifd,
    │                            │             visible and controllable in LuCI
    │                            ▼
    │                     sing-box: tun in → socks out
    │                       · TCP only; UDP and QUIC → block
    │                       · DNS → DoT over TCP, through the tunnel
    │                       · auto_route off — netifd owns routing
    │                            │
    │                            ▼
    │                     olcrtc cnc   SOCKS5 127.0.0.1:8808  (CONNECT only)
    │                            │
    │                            ▼
    │                     WebRTC datachannel / VP8 → SFU (Jitsi, Telemost, WB Stream)
    │                            │
    │                            ▼
    │                     olcrtc srv (your VPS) ──▶ internet
    │
    └──▶ olcrtc's own SFU traffic bypasses olcrtc0 via `ip rule uidrange` (see below)
```

**Why a TUN interface rather than transparent redirection.** Revision 1 proposed nftables
`REDIRECT` into `redsocks`, chosen to keep the flash footprint small. That approach cannot
satisfy the LuCI requirement: there is no device for netifd to manage, so nothing appears under
Network → Interfaces and there is nothing to start or stop. A TUN device is what makes the
interface real — and with roughly 1.8 GB of free overlay on the target, the footprint argument
that motivated redsocks no longer applies.

**Why sing-box.** It creates the TUN, bridges it to olcRTC's SOCKS5, and — critically —
expresses the three exclusions declaratively in one config: block UDP, block QUIC, and resolve
DNS over TCP through the proxy. tun2socks is lighter but has no DNS handling and would attempt
UDP over SOCKS5, which olcRTC rejects. Since sing-box is already packaged for OpenWrt, it does
the whole job; Phase 0 confirms availability per architecture, with tun2socks plus a separate
DNS resolver as the fallback.

`auto_route` and `strict_route` are deliberately **off**. sing-box would otherwise install its
own routes and fight netifd — and netifd owning routing is precisely what makes LuCI's
Start/Stop behave correctly.

### Preventing the routing loop

With a default route via `olcrtc0`, olcRTC's own signalling and WebRTC media would be routed
into the tunnel it is trying to establish, deadlocking on start.

SFU addresses are dynamic and change on failover, so an IP allowlist will not hold. The daemon
instead runs as a dedicated system user, and a routing rule keyed on that user forces its
traffic to the main table:

```sh
ip rule add uidrange ${olcrtc_uid}-${olcrtc_uid} lookup main pref 100
```

Stable across SFU changes, provider switches and failover profiles. It is the same class of fix
`qwdtt-openwrt` implements with `iif br-lan` policy routing, but keyed on process identity, so
it also protects traffic the router itself originates.

---

## LuCI integration

This is the part that carries the most new work, and it is standard OpenWrt plumbing rather
than anything custom.

**1. netifd protocol handler** — `/lib/netifd/proto/olcrtc.sh`

Registers `proto olcrtc` with netifd. On `proto_setup` it renders olcRTC's YAML from UCI,
starts the daemon and sing-box, waits for `olcrtc0` to appear, then hands the device to netifd:

```sh
proto_init_update "olcrtc0" 1
proto_add_ipv4_address "$ipaddr" "$netmask"
proto_send_update "$interface"
```

`proto_teardown` stops both cleanly. Because netifd owns the lifecycle, `ifup olcrtc` /
`ifdown olcrtc` and LuCI's Start / Stop / Restart buttons all work with no extra code, and the
interface reports genuine up/down state rather than a guess.

**2. Interface definition** — `/etc/config/network`

```
config interface 'olcrtc'
    option proto      'olcrtc'
    option provider   'jitsi'          # jitsi | telemost | wbstream
    option room       ''               # room URL; must match the server
    option transport  'datachannel'
    option key_file   '/etc/olcrtc/olcrtc.key'   # 0600, never inline
    option socks_port '8808'
    option block_quic '1'
    option block_ipv6 '1'
    option dns_mode   'dot'            # dot | doh | off
    option auto       '0'              # fail-safe: install ≠ enable
```

Living in `/etc/config/network` is what places it in the Interfaces tab. The 32-byte key is a
`0600` file referenced by `key_file` — upstream supports `crypto.key_file` for exactly this —
so the secret never sits in UCI, never reaches LuCI's form state, and never lands in a config
backup in cleartext.

**3. LuCI protocol form** — `luci-proto-olcrtc`

A client-side JS module at `/www/luci-static/resources/protocol/olcrtc.js`, matching the modern
LuCI convention used by `luci-proto-wireguard`:

```js
'require form'; 'require network';
return network.registerProtocol('olcrtc', {
    getI18n:        () => _('olcRTC Tunnel'),
    getIfname:      () => 'olcrtc0',
    getOpkgPackage: () => 'olcrtc',
    isFloating:     () => true,
    isVirtual:      () => true,
    renderFormOptions: (s) => { /* provider, room, transport, leak toggles */ }
});
```

`isVirtual` tells LuCI not to expect a physical device. The form exposes provider, room,
transport and the leak-prevention toggles, with the key handled as a file path rather than a
text field.

**Result:** Network → Interfaces lists **olcrtc** alongside `lan` and `wan`, with live status,
Start/Stop/Restart, an Edit form, and normal firewall-zone assignment.

---

## Repository layout

```
_olcrtc-openwrt/
├── UPSTREAM                              # pinned repo + commit + Go version
├── README.md
├── docs/{plan.md, install.md, troubleshoot.md}
├── .github/workflows/{build.yml, release.yml}
├── scripts/
│   ├── build-binary.sh                   # cross-compile from the pin
│   ├── mkpkg-apk.sh                      # 25.12
│   ├── mkpkg-ipk.sh                      # 24.10
│   └── leak-check.sh                     # on-device: asserts no DNS/IPv6/UDP escape
└── package/
    ├── olcrtc/
    │   ├── Makefile
    │   └── files/
    │       ├── olcrtc.proto              # → /lib/netifd/proto/olcrtc.sh
    │       ├── olcrtc.init               # procd, for socks-only mode
    │       ├── singbox-tun.json.template
    │       └── olcrtc.uci-defaults       # creates the interface, does not enable it
    └── luci-proto-olcrtc/
        ├── Makefile
        └── htdocs/luci-static/resources/protocol/olcrtc.js
```

Two packages, following the `wireguard-tools` / `luci-proto-wireguard` convention: the proto
handler ships with the daemon, the LuCI form is separate so a headless router need not install
a web UI. `luci-proto-olcrtc` depends on `olcrtc`.

---

## Build pipeline

**Source.** A pinned upstream commit built with the official Go toolchain, not the OpenWrt
SDK's — upstream requires Go 1.26.3, newer than the SDK ships. The SDK is used only to assemble
packages around the prebuilt binary, the standard binary-package pattern, which sidesteps the
version mismatch entirely.

```
# UPSTREAM
REPO=https://github.com/openlibrecommunity/olcrtc
REF=f616f57bb3a90740f1755922ffeaa7acc5cfe4ed   # master @ 2026-08-18
GO=1.26.3
```

Bumping upstream is a one-line edit. A scheduled job compares the pin against upstream `master`
and opens an issue on divergence, so the pin stays deliberate rather than forgotten.

**Matrix.**

| OpenWrt arch | GOARCH | Notes |
|---|---|---|
| `aarch64_cortex-a53` | `arm64` | Primary target |
| `aarch64_cortex-a72` | `arm64` | Higher-end ARM platforms |
| `arm_cortex-a7` | `arm`, `GOARM=7` | 32-bit ARM |
| `x86_64` | `amd64` | VM/container testing without hardware |

Each builds for both 25.12 (apk) and 24.10 (ipk) — eight artifacts per release.

MIPS is excluded: those devices ship 8–32 MB of flash and will not fit the binary. Adding them
later is one matrix row plus `GOMIPS=softfloat`.

**Build command** (matching upstream's own flags):

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOARM=$goarm \
  go build -trimpath -ldflags "-s -w" -o olcrtc ./cmd/olcrtc
```

**Gates.** `build.yml` runs on every push and PR: `go vet`, upstream's test suite at the pinned
commit, `shellcheck` over the proto handler and init scripts, and a package lint asserting the
proto handler defines `proto_olcrtc_init_config` / `_setup` / `_teardown` and calls
`add_protocol`. A missing teardown is exactly the bug that leaves a dead interface stuck "up"
in LuCI, so it is worth failing the build over.

**Release.** Tag `v*` → build all architectures → emit apk and ipk → `SHA256SUMS` → sign →
publish a GitHub Release plus static apk and opkg feed indexes, so installation is one feed line
and `apk add luci-proto-olcrtc`. Unsigned artifacts are not published; several projects in this
survey ship binaries with no integrity story at all, and that is worth not repeating.

---

## Phases

### Phase 0 — Feasibility

No longer gated on binary size. With ~1.8 GB free overlay the footprint is irrelevant, so this
phase now targets the assumptions that can still invalidate the design:

1. **Confirm `sing-box` is in the 25.12 and 24.10 feeds** for each architecture, and that its
   TUN inbound works with `auto_route: false`. Fallback is tun2socks plus a separate resolver.
2. **Confirm package format per release** — that 25.12 is apk and 24.10 is opkg on the actual
   images, rather than assuming from version numbers.
3. **Verify `ip rule uidrange`** is supported by the installed iproute2. If not, fall back to an
   nftables `meta skuid` mark plus a policy route.
4. **Confirm a room reaches an SFU from the router's network** before building packaging around
   it.
5. Measure binary size and idle/loaded RAM for the record, not as a gate.

### Phase 1 — Build pipeline
Cross-compile from the pin across the matrix; publish checksummed artifacts. Deliverable: a
binary per architecture, reproducible from a clean checkout.

### Phase 2 — Base package and daemon
Package skeleton, UCI→YAML rendering, dedicated system user, `0600` key file, `logd` logging,
procd service for socks-only operation. Deliverable: a working SOCKS5 listener on loopback,
verified with `curl --socks5`.

### Phase 3 — netifd protocol handler
`/lib/netifd/proto/olcrtc.sh`, sing-box TUN config generation, `proto_send_update`, the
`uidrange` loop-prevention rule, and clean teardown. Deliverable: `ifup olcrtc` brings up
`olcrtc0` and routes traffic; `ifdown olcrtc` removes it with no residue.

### Phase 4 — Leak prevention (must not be skipped)
- **DNS:** sing-box's DNS server forwards over DoT (TCP/853) through the proxy outbound;
  dnsmasq points at it on loopback. `dns_mode 'off'` exists for users who accept plaintext DNS,
  but is not the default.
- **QUIC:** a route rule sends `protocol: quic` to `block`, so browsers fall back to TCP rather
  than silently bypassing the tunnel.
- **IPv6:** no IPv6 address or route on `olcrtc0`, and IPv6 forwarding rejected while the
  interface is up. Optionally stop advertising IPv6 on the LAN so clients never acquire an
  address they cannot use.
- **Kill-switch:** if olcRTC dies, traffic fails closed rather than falling back to the clear
  WAN path. netifd marks the interface down and the firewall does not open in the gap.
- `scripts/leak-check.sh` asserts all four from the router and exits non-zero on any leak.

### Phase 5 — LuCI package
`luci-proto-olcrtc`, the protocol form, status rendering and translation stubs. Deliverable:
the interface is fully configurable from the browser without touching a shell.

### Phase 6 — Validation
Install on real hardware for both releases. Run `leak-check.sh`; measure throughput and memory
over a sustained transfer; verify recovery across WAN loss, reboot and sysupgrade; confirm
Start/Stop/Restart behave correctly from LuCI, including repeated cycling.

Per your answer, **CI does not deploy to a device** — this phase is manual, and no address or
identifying detail appears anywhere in the repository.

---

## Risks

**Throughput will be modest.** Traffic is TCP inside a WebRTC datachannel inside DTLS/SCTP,
reassembled by a Go userspace process, now with a TUN hop on top. Treat it as a browsing and
whitelist-bypass path, not a bulk-transfer link, and measure before promising numbers.

**TCP-in-TCP meltdown.** Carrying TCP over a reliable datachannel stacks two congestion
controllers; under loss this degrades sharply. olcRTC's KCP-backed transports exist partly to
address this, so Phase 6 should compare `datachannel` against them rather than assuming the
default is best.

**Two moving dependencies, not one.** The design now rests on sing-box as well as olcRTC. A
sing-box config-schema change between OpenWrt releases would break the generated config, so the
template is validated in CI against the version each release ships.

**Upstream is a moving target.** olcRTC has one tag, no releases, a five-month history, 78% of
commits from one author, and four dependencies in maintainer-personal namespaces that have been
re-tagged in place. Pinning is what makes this buildable; expect each bump to need real testing
rather than a rubber stamp.

**Sudden obsolescence.** The technique depends on a third party that has not agreed to be
depended upon. Any provider-side change can close it without warning, as happened to
`jaykaiperson/lionheart`. Nothing here mitigates that; it is the cost of the category.

**Account risk.** Provider-backed profiles may tie the tunnel to a real account. Documentation
defaults to Jitsi, which needs no account at all.

---

## What changed in revision 2

| | Revision 1 | Revision 2 |
|---|---|---|
| Data path | nftables `REDIRECT` → redsocks | TUN device → sing-box |
| Why | Smallest possible footprint | Only a real device can appear in LuCI Interfaces |
| Packages | `olcrtc` + `olcrtc-tproxy` | `olcrtc` (incl. proto handler) + `luci-proto-olcrtc` |
| Loop prevention | nftables `meta skuid` | `ip rule uidrange` |
| Releases | apk "24.10+", ipk older | 25.12 apk primary, 24.10 ipk alongside |
| Phase 0 gate | Binary size — go/no-go | Size irrelevant; now sing-box availability |
| Dropped risks | Flash footprint, extroot, UPX | — |

---

## Remaining open question

**Server-side scope.** This plan covers the router client only, and assumes an `olcrtc srv`
already running on a VPS with a matching room and key. Say if provisioning that should also be
in scope — it would add a phase, and the natural shape is a deploy script rather than a package.

Everything else is settled: 25.12 primary with 24.10 alongside, storage is ample, and CI does
not touch a device.

---

## Confirm before I start

Approve the switch to a TUN-based data path with sing-box (the change that makes LuCI
integration possible), the two-package split, and the fail-closed defaults in Phase 4 — then
answer the server-side question above. Phase 0 runs first regardless, since sing-box
availability can still change the shape of Phase 3.
