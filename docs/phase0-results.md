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

## 2. sing-box availability — CONFIRMED, with a caveat

Present on every target architecture in both releases, so the TUN data path is viable
everywhere and the tun2socks fallback is not needed:

| Architecture | 24.10.8 (ipk) | 25.12.5 (apk) |
|---|---|---|
| `aarch64_cortex-a53` | 1.12.22-r1 | 1.13.18-r1 |
| `aarch64_cortex-a72` | 1.12.22-r1 | 1.13.18-r1 |
| `arm_cortex-a7` | 1.12.22-r1 | 1.13.18-r1 |
| `x86_64` | 1.12.22-r1 | 1.13.18-r1 |

**The caveat is the version gap, and it is the concrete form of a risk the plan flagged in the
abstract.** The two releases ship sing-box minor versions that do not share one config schema.
Between 1.12 and 1.13 the areas we depend on most are exactly the ones that moved: protocol
sniffing migrated from an inbound flag to a route rule action, TUN address fields were
renamed, and the DNS block was restructured. A single hand-written config will not validate on
both.

**Decision:** the init script detects the installed sing-box version and renders a matching
template, rather than shipping one config and hoping. Concretely:

- `files/singbox-1.12.json.template` for 24.10
- `files/singbox-1.13.json.template` for 25.12
- version detected via `sing-box version` at interface bring-up
- both templates validated with `sing-box check` in CI against both versions, so a schema drift
  fails the build instead of failing on someone's router

This costs one extra template and one CI job. The alternative — targeting the oldest schema and
relying on deprecation shims — breaks the moment a shim is removed, which is what the 1.12→1.13
changes demonstrate.

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

**No blockers.** The TUN plus sing-box architecture stands on all four target architectures and
both releases. One design change falls out of check 2: per-version sing-box config templates
rather than a single file. Checks 3 and 4 need the hardware and do not block Phases 1, 2 or S.
