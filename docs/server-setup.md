# Phase S — VPS server setup

Provisioning the server end of the tunnel on **Ubuntu 24.04 LTS, x86_64**, using
[`scripts/provision-server.sh`](../scripts/provision-server.sh).

Read the script before running it. It is written to be reviewed — every step is commented with
why, not just what.

---

## What you need first

**The binary.** The Phase 1 release pipeline does not exist yet, so there is nothing to
download. Build it once on any machine with Go 1.26.3, using the pin from
[`UPSTREAM`](../UPSTREAM):

```sh
git clone https://github.com/openlibrecommunity/olcrtc olcrtc-src
cd olcrtc-src
git checkout f616f57bb3a90740f1755922ffeaa7acc5cfe4ed
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w' -o olcrtc ./cmd/olcrtc
sha256sum olcrtc          # note this; you will want it later
```

Copy `olcrtc` to the VPS. Once Phase 1 lands, this is replaced by
`--binary-url` plus `--binary-sha256` against a signed release.

**A room.** For Jitsi, a room is created implicitly by joining its URL, so pick an instance and
invent a long random name:

```sh
openssl rand -hex 12      # e.g. 8f3c1d5a9e2b7c4d6f0a1b93
```

Giving `https://meet.example.org/8f3c1d5a9e2b7c4d6f0a1b93`. Upstream's
`docs/jitsi.instances.yaml` lists instances; check in a browser that the one you choose is
reachable from **both** the VPS and the router before committing to it.

A short or guessable room name is a real risk: anyone who joins the same room sees your
encrypted frames and can attempt to disrupt the session, even though the shared key stops them
reading anything.

---

## Run it

Start with a dry run. It prints every action and changes nothing:

```sh
sudo ./provision-server.sh \
  --binary ./olcrtc \
  --room https://meet.example.org/8f3c1d5a9e2b7c4d6f0a1b93 \
  --dry-run
```

Then for real:

```sh
sudo ./provision-server.sh \
  --binary ./olcrtc \
  --room https://meet.example.org/8f3c1d5a9e2b7c4d6f0a1b93
```

The script is idempotent — re-running updates in place. It will not regenerate an existing key
unless you delete `/etc/olcrtc/olcrtc.key` first.

### The two opt-in steps

Firewall and SSH hardening are **off by default**, because both can lock you out of a remote
host. Add them once the tunnel works:

```sh
sudo ./provision-server.sh --binary ./olcrtc --with-firewall --with-ssh-hardening
```

`--with-ssh-hardening` refuses to run unless it finds a non-empty `authorized_keys`, tests the
config with `sshd -t` before reloading, and reverts if the test fails. Even so: **keep your
current session open and confirm a second one works before closing the first.** Undo is one
command, printed by the script.

---

## Why no inbound port is opened

Worth stating plainly, because it looks like an omission. olcRTC's server has **no listener at
all** — `internal/server/` contains no `net.Listen` of any kind. Both ends *join* a conference
outbound, and the SFU relays between them. The VPS never accepts an incoming connection.

So `--with-firewall` sets default-deny inbound with SSH as the only exception, and adds nothing
for olcRTC. There is no port to scan, no listener to fingerprint, and no service to expose.

This is a genuine advantage over the DTLS-based projects in the wider survey, where the server
is an open UDP listener that anyone reaching the port can hand traffic to — several of them
with `InsecureSkipVerify` set, making them unauthenticated open relays by default.

---

## The systemd unit

Runs unprivileged with an empty capability set. Two directives need explanation rather than
copying:

**`AF_NETLINK` must stay in `RestrictAddressFamilies`.** Go's `net` package enumerates
interfaces over netlink, and olcRTC's `internal/protect` walks them to filter ICE candidates.
Remove it and candidate gathering fails in a way that presents as a network fault rather than a
sandbox denial — an afternoon lost to debugging the wrong layer.

**`MemoryDenyWriteExecute` is deliberately absent.** Go does not JIT, so it *should* be safe,
but "should" is not verification. To test it:

```sh
sudo systemctl edit olcrtc      # add [Service] / MemoryDenyWriteExecute=true
sudo systemctl restart olcrtc
journalctl -u olcrtc -n 50 --no-pager
```

If the service stays up through a real transfer, keep it. If it dies, drop it — the rest of the
sandbox is doing the meaningful work.

---

## Verify

```sh
systemctl status olcrtc
journalctl -u olcrtc -f
```

A healthy server logs joining the room and then waits. It stays idle until the router connects
— no client, no traffic, no errors.

```sh
ss -lntup | grep olcrtc      # expect NOTHING: there is no listener
```

Empty output is correct here, not a fault.

---

## Hand the key to the router

Both ends must agree on **provider, room, transport and key**. Disagree on any one and the link
silently never forms — there is no error that says "wrong key", it simply never connects.

```sh
sudo cat /etc/olcrtc/olcrtc.key
```

Transfer it over a channel you trust. Not a chat window, not this repository, not an
unencrypted config backup. It is the only thing authenticating the two ends to each other:
anyone holding it who can find the room can use your tunnel, and read what crosses it.

---

## Rotating the key

```sh
sudo systemctl stop olcrtc
sudo rm /etc/olcrtc/olcrtc.key
sudo ./provision-server.sh --binary /usr/local/bin/olcrtc     # regenerates and restarts
sudo cat /etc/olcrtc/olcrtc.key                               # update the router too
```

The tunnel stays down until the router has the new value.

---

## Uninstall

```sh
sudo systemctl disable --now olcrtc
sudo rm -f /etc/systemd/system/olcrtc.service /usr/local/bin/olcrtc
sudo rm -rf /etc/olcrtc /var/lib/olcrtc
sudo userdel olcrtc
sudo systemctl daemon-reload
```

Firewall and SSH changes are left alone deliberately — they are system policy, not part of this
service. Reverse them yourself if you want to.
