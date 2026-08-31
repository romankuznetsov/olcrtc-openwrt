# Phase 0 — feasibility results

Checks that could invalidate the architecture in [plan.md](plan.md). Two are answered here from
the OpenWrt package servers; three need the target hardware and are covered by
[`scripts/phase0-device-check.sh`](../scripts/phase0-device-check.sh).

**Verified 2026-08-27** against `downloads.openwrt.org`.

---

## 1. Package format per release — CONFIRMED

The assumption in the plan held, and it is now checked rather than inferred from version
numbers:

| Release | Index file | Format |
|---|---|---|
| 24.10.8 | `Packages`, `Packages.gz` | **opkg / ipk** |
| 25.12.5 | `packages.adb` | **apk** |

Latest points on each line are 24.10.8 and 25.12.5. The apk migration landed between them, so
25.12 takes apk and 24.10 takes ipk — exactly the split the build pipeline already targets.

## 2. TUN→SOCKS5 bridge — CONFIRMED as `hev-socks5-tunnel`

**`tun2socks` is not in the OpenWrt feeds at all** — not under that name, and not as
`badvpn-tun2socks`. Searched `packages`, `luci`, `routing` and `telephony` for 24.10.8: zero
hits. The OpenWrt equivalent is the `hev-socks5-*` family, and the one we want is
`hev-socks5-tunnel`: a small C daemon that creates a TUN device and forwards it to a SOCKS5
upstream, which is exactly tun2socks' job.

Available on every target architecture in both releases:

| Architecture | 24.10.8 (ipk) | 25.12.5 (apk) | Installed size |
|---|---|---|---|
| `aarch64_cortex-a53` | 2.17.0-r1 | 2.17.0-r2 | 270 KB |
| `aarch64_cortex-a72` | 2.17.0-r1 | 2.17.0-r2 | 270 KB |
| `arm_cortex-a7` | 2.17.0-r1 | 2.17.0-r2 | 210 KB |
| `x86_64` | 2.17.0-r1 | 2.17.0-r2 | 250 KB |

**Two things fall out of this, and the second is the more valuable.**

*Size.* At 210–270 KB it is roughly **70× smaller than sing-box**, which was the reason for the
change. Total runtime footprint becomes the olcRTC binary plus a quarter-megabyte, rather than
the olcRTC binary plus a second Go binary of comparable size.

*The version-skew problem disappears.* Both releases ship **2.17.0** — the same upstream
version, differing only in OpenWrt package revision. The sing-box plan needed two config
templates and a runtime version probe because 1.12 and 1.13 do not share a schema. That is now
one template, no probe, and no CI matrix to validate two schemas. This is a real simplification,
not just a smaller binary.

**What sing-box was also doing, and where it moves:**

| Job | Was | Now |
|---|---|---|
| TUN device + SOCKS5 bridge | sing-box `tun` in / `socks` out | `hev-socks5-tunnel` |
| Block UDP and QUIC | sing-box route rules | nftables on the router |
| DNS over TCP | sing-box built-in DNS | `https-dns-proxy` (DoH) or `stubby` (DoT) |

The nftables rules were already required for the Phase 4 fail-closed guarantees, so moving UDP
and QUIC blocking there removes a duplicate mechanism rather than adding work. DNS becomes an
explicit dependency instead of a config block — arguably clearer, since it is now visible in the
package manifest.

## 2b. DNS resolvers — CONFIRMED

Both TCP-based options are present on all four architectures in both releases, so DNS can be
forced through the tunnel:

| Package | 24.10.8 | 25.12.5 | Transport |
|---|---|---|---|
| `https-dns-proxy` | 2026.05.06-r1 | 2026.05.06-r1 | DoH over TCP/443 |
| `stubby` | 0.4.3-r1 | 0.4.3-r3 | DoT over TCP/853 |

`https-dns-proxy` is the default: it has a LuCI companion app, and DoH on TCP/443 is
indistinguishable from ordinary HTTPS to anything watching the tunnel, whereas DoT's TCP/853 is
a distinctive port. `stubby` remains selectable via `dns_mode`.

## 3. `ip rule uidrange` support — NEEDS HARDWARE

Loop prevention keys on it. The fallback if unsupported is an nftables `meta skuid` mark plus a
policy route, which is more moving parts but equivalent. Checked by the device script.

## 4. SFU reachability from the router's network — NEEDS HARDWARE

Worth confirming before building packaging around it. Checked by the device script.

## 5. Binary size and RAM — DEFERRED, NOT A GATE

No longer go/no-go: the target has roughly 1.8 GB free overlay, so footprint is irrelevant.
Deferred to the Phase 1 pipeline, which reports the stripped size per architecture as a build
artifact. Recorded for the record, not as a decision input.

There is no Go toolchain on the workstation used to prepare this, so no local measurement was
taken — my earlier 18–25 MB estimate remains an estimate until CI produces a real number.

---

## Outcome

**No blockers.** The TUN data path stands on all four target architectures and both releases,
now built on `hev-socks5-tunnel` rather than sing-box.

The switch away from sing-box removed a design problem rather than creating one. It was adopted
on size grounds — 270 KB against roughly 20 MB — but the larger benefit is that both OpenWrt
releases ship the *same* `hev-socks5-tunnel` version, so the two config templates and the
runtime version probe that sing-box's 1.12/1.13 schema split forced are no longer needed. UDP
and QUIC blocking moves to nftables, where Phase 4 needed rules anyway, and DNS becomes an
explicit package dependency.

Checks 3 and 4 need the hardware and do not block Phases 1, 2 or S.

---

# Phase 6 — hardware validation results

**Validated 2026-08-31** on OpenWrt 25.12.2, `aarch64_cortex-a53`, apk, against an
Ubuntu 24.04 x86_64 VPS.

## Outcome: working

Whole-LAN transparent routing verified end to end — LAN → `olcrtc0` →
`hev-socks5-tunnel` → olcRTC SOCKS5 → WebRTC datachannel → VPS → internet.

| Check | Result |
|---|---|
| Routed probes exiting at the VPS | **10/10** |
| DNS resolution through the tunnel | resolved (3/3 hosts) |
| olcRTC reconnects during the run | 0 |
| Daemon instances after restart | exactly 1 olcRTC + 1 hev |
| UDP / QUIC / IPv6 rejected | yes / yes / yes |
| Management path protected | yes (pref 143) |
| `ip rule uidrange` | supported — fwmark fallback not used |
| LuCI protocol form | renders (after fixing `getPackageName`) |

Measured binary sizes, which Phase 0 deferred: **28 MiB** (aarch64), **30 MiB** (x86_64).
My earlier 18–25 MB estimate was low.

## Ten bugs found, none visible in review

1. **busybox has neither `su` nor `stat`.** The key-readability check used `su`, which fails
   unconditionally when absent, so the interface could never start.
2. **Directory traversal, not file permissions.** `/etc/olcrtc` and `/var/run/olcrtc` were
   `0750 root:root`; the service account could not traverse them. The error names the *file*,
   which sends you to the wrong place — and a check that validates only the file reports a
   false OK.
3. **nft folded a family qualifier into the reject statement**, turning
   `meta nfproto ipv6 reject with icmpv6 …` into a bare `reject` matching every forwarded
   packet. Every rule now carries an explicit interface match and uses `icmpx`.
4. **`start-stop-daemon -b` discards stdout and stderr**, so startup failures had no
   diagnosable cause. olcRTC now execs with output to `/var/log/olcrtc.log`.
5. **netifd's `proto_add_ipv4_route()` exposes only 5 of 7 route fields and drops `table`.**
   Passing it as a 7th argument is silently ignored and the route lands in `main`.
6. **Tunnel routes in `main` defeated the uid exemption.** The exemption pointed *at* `main`,
   where `0.0.0.0/1` outranked the WAN default, so exempted traffic followed the tunnel too.
   The tunnel default now lives in its own table.
7. **The catch-all rule captured the router's own management traffic.** Replies to hosts on
   its LAN and WAN subnets went into a tunnel that cannot carry RFC1918. **This locked the
   router out and required a power cycle.** Fixed with bypass rules at pref 141-146.
8. **The fwmark fallback broke the mechanism it backs up.** Its `route` hook re-evaluates
   routing after marking, losing the socket uid, so the uidrange rule stopped matching. Now
   emitted only when uidrange is unavailable.
9. **A hard netifd restart orphans both daemons**, since the supervisor is killed without
   running its EXIT trap. The replacement then fails with "address already in use" while the
   orphaned bridge fights the live one over the TUN. Startup now reaps orphans.

10. **The LuCI form used the wrong API name.** `getOpkgPackage()` is the older entry point;
    luci-base 26.089 (OpenWrt 25.12) expects **`getPackageName()`**. With the wrong name — or
    with the file simply absent — Network → Interfaces shows *"Unsupported protocol type.
    Install protocol extensions…"* rather than the configuration form. The
    `registerPatternVirtual` pattern was also wrong: it matched `olcrtc-*` when the device is
    `olcrtc0`. Verified against the shipped `wireguard.js` on the device, which is the reliable
    way to pin this API down; `registerPatternVirtual` is used by 18 shipped protocols.

## Operational notes

**Allow settling time.** The first 30–60 s after bring-up is unstable while both ends
negotiate; probes taken in that window fail and then recover. Judge health after it settles,
not during.

**Newly declared UCI options need a netifd restart**, not just `ifup` — netifd caches the
protocol schema from `init_config`.

**Do not point olcRTC at the router's own DoH proxy.** That proxy runs unprivileged, so it is
not uid-exempted; its traffic goes through the tunnel, and the tunnel needs DNS to come up.
olcRTC uses a direct resolver (uid-exempted, always reachable); LAN clients still resolve
through DoH over the tunnel. Give the DoH proxy an **IP-literal** resolver URL so it needs no
plaintext bootstrap lookup, and make sure dnsmasq has no dead upstreams — a stale entry for a
removed instance causes intermittent resolution failures.

**`meet.jit.si` requires a token** and cannot be used. Upstream's curated instance list exists
for this reason; verify a candidate is reachable from *both* ends before committing to it.
