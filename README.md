# olcrtc-openwrt

OpenWrt packaging for the [olcRTC](https://github.com/openlibrecommunity/olcrtc) tunnel, exposed
as a managed network interface in LuCI.

The tunnel appears under **Network → Interfaces** with working Start / Stop / Restart, a
configuration form, and normal firewall-zone assignment — so a router carries LAN traffic
through it with no client-side setup on any device.

| | |
|---|---|
| Targets | OpenWrt **25.12** (apk) primary, **24.10** (ipk) alongside |
| Architectures | `aarch64_cortex-a53`, `aarch64_cortex-a72`, `arm_cortex-a7`, `x86_64` |
| Server | Ubuntu 24.04 LTS, x86_64 |
| Upstream | Pinned commit, built with the official Go toolchain — see [`UPSTREAM`](UPSTREAM) |

> **Status: early.** Phase 0 and Phase S are done. The packages themselves are not built yet.
> See [docs/plan.md](docs/plan.md) for the full plan and phase order.

---

## How it works

```
LAN device (no configuration)
    │
    ▼
br-lan ──▶ olcrtc0            real TUN device, managed by netifd, controlled from LuCI
               │
               ▼
  hev-socks5-tunnel           ~270 KB C daemon: TUN → SOCKS5
               │
               ▼
        olcrtc cnc            SOCKS5 on loopback (CONNECT only)
               │
               ▼
        WebRTC datachannel ──▶ SFU ──▶ olcrtc srv (your VPS) ──▶ internet
```

**The constraint worth knowing before anything else:** olcRTC carries **TCP over IPv4 only**.
Its SOCKS5 accepts `CONNECT` and nothing else, and its server egress dials `tcp4`. Both verified
in upstream source, not inferred.

That means UDP, QUIC and IPv6 cannot traverse the tunnel. Left alone they do not merely fail —
they leak, exiting the WAN in the clear while the tunnel looks up. So the package **rejects them
by default**: nftables rejects UDP, QUIC and IPv6 forwarding while the interface is up, and DNS
is forced over TCP via `https-dns-proxy`. Some traffic visibly fails instead of silently escaping.
That is the intended trade.

---

## Repository

```
UPSTREAM                          pinned upstream commit + Go version
docs/
  plan.md                         full implementation plan and phases
  phase0-results.md               feasibility findings (verified against OpenWrt feeds)
  server-setup.md                 VPS walkthrough
scripts/
  phase0-device-check.sh          read-only router checks
  provision-server.sh             VPS provisioning (Ubuntu 24.04)
```

## Getting started

**On the router** — read-only, changes nothing:

```sh
scp scripts/phase0-device-check.sh root@<router>:/tmp/
ssh root@<router> sh /tmp/phase0-device-check.sh
```

**On the VPS** — see [docs/server-setup.md](docs/server-setup.md). Dry-run first:

```sh
sudo ./scripts/provision-server.sh --binary ./olcrtc --room <url> --dry-run
```

---

## Notes on trust

No `curl | bash`. Every binary install verifies a SHA-256, and the provisioning script refuses
to install an unverified download rather than defaulting to one.

No secrets in this repository. The shared key is generated on the server, stored `0640`, and
transferred out of band. No hostname, address or credential belonging to any deployment appears
here.

The server opens **no inbound port** — it has no listener at all. A default-deny inbound
firewall is correct and complete.

---

## Risks

**Throughput is modest.** TCP inside a WebRTC datachannel inside DTLS/SCTP, reassembled by a Go
process on a router CPU, with a TUN hop on top. A browsing path, not a bulk-transfer link.

**Upstream is young.** One tag, no releases, a five-month history, most commits from one author,
and several dependencies re-tagged in place. Pinning is what makes this buildable; each bump
needs real testing.

**Sudden obsolescence.** The technique depends on a third party that has not agreed to be
depended upon. A provider-side change can close it without warning. Treat this as having
unbounded risk of stopping abruptly, independent of code quality.

**Account risk.** Provider-backed profiles may tie the tunnel to a real account. Documentation
defaults to Jitsi, which needs no account at all.

---

## Licence

Packaging in this repository is separate from upstream olcRTC, which is WTFPL. A licence will
be added before the first release.
