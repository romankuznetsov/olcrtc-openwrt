# The package feed

Two ways to install, and which one you get depends on your OpenWrt release
rather than on preference.

| Release | Format | How |
|---|---|---|
| 25.x and newer | `apk` | **Signed feed** on GitHub Pages — recommended |
| 24.10 | `ipk` | Loose files attached to a GitHub release |

## Why only 25.x gets a feed

OpenWrt 25.x signs repository metadata as `packages.adb`, using an EC P-256
keypair. 24.10's opkg feeds are signed with `usign`, a different scheme with
different keys that **cannot** sign `packages.adb` — the two formats do not
share a signing mechanism. Running both would mean maintaining two key
hierarchies for one small package set, so 24.10 keeps using release assets.
This is the same split [amneziawg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)
arrived at.

## Installing from the feed (25.x)

Trust the signing key once, add the feed for your architecture, then install:

```sh
# 1. the key that signs the repository index
wget -O /etc/apk/keys/olcrtc-feed.pem \
  https://<owner>.github.io/olcrtc-openwrt/keys/olcrtc-feed.pem

# 2. the feed itself -- substitute your release and architecture
echo "https://<owner>.github.io/olcrtc-openwrt/25.12.5/$(apk --print-arch)/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

# 3. install
apk update
apk add olcrtc luci-proto-olcrtc
```

`apk --print-arch` prints the value to substitute. The feed index page lists
every published release and architecture with the exact URL, so you can copy it
rather than assemble it.

After that, `apk upgrade` picks up new versions like any other package, which is
the whole reason to prefer this over downloading files.

## Installing loose files

On 24.10:

```sh
opkg install ./olcrtc_*.ipk ./luci-proto-olcrtc_*.ipk
```

On 25.x, if you would rather not add the feed, `--allow-untrusted` is required —
a loose `.apk` carries no repository signature, so apk refuses it otherwise:

```sh
apk add --allow-untrusted ./olcrtc_*.apk ./luci-proto-olcrtc_*.apk
```

Verify what you downloaded first. Every release ships `SHA256SUMS` plus a
minisign signature over it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
minisign -Vm SHA256SUMS -P <public key from the repository>
```

## Which architectures are built

`aarch64_cortex-a53`, `aarch64_cortex-a72`, `arm_cortex-a7`, `x86_64`.

The packages are per **architecture**, not per target/subtarget: olcRTC ships no
kernel module, so nothing here is tied to a kernel ABI and a second subtarget of
the same architecture would produce byte-identical files. (This is the one place
the design differs from amneziawg-openwrt, which must enumerate every subtarget
because `kmod-amneziawg` has to match the running kernel exactly.)

If your router's architecture is missing, it is a one-line addition to the
matrices in `.github/workflows/build.yml` and `feed.yml` — open an issue with
the output of `apk --print-arch` (or `opkg print-architecture`) and the target.

## Maintainer notes

### Keys

The feed needs two repository secrets, and the workflow fails rather than
publishing an unverifiable feed if they are absent:

| Secret | Contents |
|---|---|
| `OLCRTC_FEED_APK_PRIVATE_KEY` | EC P-256 private key, PEM |
| `OLCRTC_FEED_APK_PUBLIC_KEY` | matching public key, PEM |

```sh
openssl ecparam -name prime256v1 -genkey -noout -out olcrtc-feed.pem
openssl ec -in olcrtc-feed.pem -pubout > olcrtc-feed.pub.pem
```

These are **not** usign keys, and not the minisign key used for `SHA256SUMS`.
Three different signatures, three different purposes: apk repository metadata,
opkg indexes, and release checksums.

The public half is published to `keys/olcrtc-feed.pem` on Pages so devices can
fetch it. Rotating the private key invalidates every installed feed until
devices fetch the new public key, so treat it as long-lived.

### Publishing

`feed.yml` runs on a `v*` tag (via `release.yml`) and can also be dispatched
manually for a specific release. Each run builds only the architectures in its
matrix for one release, so the deploy job **restores the existing `gh-pages`
branch first** and merges the new files on top. Without that, publishing would
delete every other release already served.

Requirements on the repository: Pages enabled with `gh-pages` as the source, and
the repo public (Pages on a private repo needs a paid plan).

### What the feed job verifies

Beyond "the files exist":

- `PACKAGE_DIR` collects both packages into one directory — needed because
  `olcrtc` is `PKGARCH:=$(ARCH)` and `luci-proto-olcrtc` is `PKGARCH:=all`, so
  by default they land in different trees.
- Anything else that `PACKAGE_DIR` collected (it is inherited by dependency
  builds) is **deleted before** `make package/index`, so the signature covers
  only what we mean to ship.
- The index is read back with the SDK's own `apk adbdump` and checked to contain
  both packages — and checked *not* to contain `busybox`, `libc`, `ubus` or
  `netifd`. A feed that offers base packages would shadow the official ones on
  any router that adds it.
