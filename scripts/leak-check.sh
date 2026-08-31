#!/bin/sh
# leak-check.sh -- assert that client traffic cannot escape the olcRTC tunnel.
#
# Run ON THE ROUTER:
#     sh /tmp/leak-check.sh [--mark 0x4]
#
# Phase 4 of docs/plan.md requires four properties. This checks all of them and
# exits non-zero on any leak, so it can gate a deploy:
#
#   1. UDP cannot reach the tunnel interface        (rejected, not blackholed)
#   2. QUIC (udp/443) likewise                      (so browsers fall back to TCP)
#   3. IPv6 forwarding from the LAN is rejected     (the tunnel is IPv4-only)
#   4. KILL-SWITCH: with the tunnel down, marked client traffic fails closed
#      rather than falling back to the clear WAN path
#
# Check 4 is the one that matters most and the one that is easiest to get wrong,
# because it must hold when the protocol handler is NOT running -- rules that
# the handler installs disappear with it. In mark mode it is satisfied by two
# static `config rule` stanzas in /etc/config/network: fwmark -> table, then
# fwmark -> unreachable. This script verifies the second exists and that the
# first has nowhere to send traffic once the table is flushed.
#
# Read-only by default. --toggle additionally takes the interface down and back
# up to prove the kill-switch in its real state; without it, that check is
# static (rule present + table contents) rather than empirical.

set -u

MARK=0x4
IFACE=olcrtc0
CFG=olcrtc
TABLE=8808
TOGGLE=0

while [ $# -gt 0 ]; do
	case "$1" in
	--mark)   MARK="$2"; shift 2 ;;
	--iface)  IFACE="$2"; shift 2 ;;
	--table)  TABLE="$2"; shift 2 ;;
	--toggle) TOGGLE=1; shift ;;
	-h|--help) sed -n '2,28p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

fails=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  LEAK  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  skip  %s\n' "$*"; }

# nft output is matched rather than parsed: the chain names are ours, the rule
# text is nft's, and a substring match survives nft reformatting between
# versions in a way that field indexing does not.
nft_has() { nft list chain inet fw4 "$1" 2>/dev/null | grep -q -- "$2"; }

echo "olcRTC leak check (mark $MARK, iface $IFACE, table $TABLE)"
echo

# ---------------------------------------------------------------- interface up?
up=0
if [ -d "/sys/class/net/$IFACE" ]; then
	up=1
	echo "interface $IFACE is present"
else
	echo "interface $IFACE is ABSENT -- checking the fail-closed path only"
fi
echo

# ------------------------------------------------- 1-3: while the tunnel is up
echo "leak prevention while up:"
if [ "$up" = 1 ]; then
	nft_has olcrtc_fwd "l4proto udp" \
		&& pass "UDP toward $IFACE is rejected" \
		|| fail "UDP toward $IFACE is NOT rejected"

	nft_has olcrtc_fwd "udp dport 443" \
		&& pass "QUIC (udp/443) toward $IFACE is rejected" \
		|| fail "QUIC (udp/443) toward $IFACE is NOT rejected"

	nft_has olcrtc_fwd "nfproto ipv6" \
		&& pass "forwarded IPv6 from the LAN is rejected" \
		|| fail "forwarded IPv6 from the LAN is NOT rejected"

	# A rule with no interface match would reject everything forwarded, which
	# has happened: nft folded a family qualifier into the reject statement and
	# left a bare `reject`. Every rule in this chain must name an interface.
	bare="$(nft list chain inet fw4 olcrtc_fwd 2>/dev/null \
		| grep -c 'reject' 2>/dev/null || echo 0)"
	scoped="$(nft list chain inet fw4 olcrtc_fwd 2>/dev/null \
		| grep -c -E '(oifname|iifname).*reject' 2>/dev/null || echo 0)"
	if [ "$bare" = "$scoped" ]; then
		pass "every reject in olcrtc_fwd is scoped to an interface ($scoped)"
	else
		fail "olcrtc_fwd has $((bare - scoped)) unscoped reject rule(s) -- would drop unrelated traffic"
	fi
else
	skip "tunnel is down; up-state checks not applicable"
fi
echo

# ------------------------------------------------------------- 4: kill-switch
echo "kill-switch:"

# The unreachable rule must be present regardless of tunnel state. This is the
# whole point: it is declared statically, not by the handler.
if ip rule show | grep -q "fwmark $MARK unreachable"; then
	pass "static 'fwmark $MARK unreachable' rule is present"
else
	fail "no 'fwmark $MARK unreachable' rule -- marked clients revert to the clear WAN when the tunnel dies"
fi

# ...and it must sit BEHIND the lookup rule, or nothing ever reaches the tunnel.
lookup_pref="$(ip rule show | awk -v m="$MARK" '$0 ~ "fwmark " m " lookup" { sub(/:/, "", $1); print $1; exit }')"
unreach_pref="$(ip rule show | awk -v m="$MARK" '$0 ~ "fwmark " m " unreachable" { sub(/:/, "", $1); print $1; exit }')"
if [ -n "$lookup_pref" ] && [ -n "$unreach_pref" ]; then
	if [ "$lookup_pref" -lt "$unreach_pref" ]; then
		pass "rule order is correct (lookup at $lookup_pref, unreachable at $unreach_pref)"
	else
		fail "unreachable at $unreach_pref precedes lookup at $lookup_pref -- the tunnel can never be used"
	fi
elif [ -z "$lookup_pref" ]; then
	fail "no 'fwmark $MARK lookup <table>' rule -- marked traffic never enters the tunnel"
fi

# Router-originated traffic must NOT be caught by the lane. Anything the router
# sends is unmarked, so it should route via main whether the tunnel is up or not.
r="$(ip route get 1.1.1.1 2>/dev/null | head -1)"
case "$r" in
*"$IFACE"*) fail "router-originated traffic routes via $IFACE: $r" ;;
*unreachable*) fail "router-originated traffic is unreachable: $r" ;;
*) pass "router-originated traffic is unaffected (${r:-no route})" ;;
esac

# And marked traffic must resolve to the tunnel while it is up, unreachable while
# it is not. `ip route get ... mark` asks the kernel the same question the
# forwarding path asks, which beats reasoning about the rule list.
marked="$(ip route get 1.1.1.1 mark "$MARK" 2>&1 | head -1)"
if [ "$up" = 1 ]; then
	case "$marked" in
	*"$IFACE"*) pass "marked traffic routes into $IFACE" ;;
	*) fail "marked traffic does not use $IFACE: $marked" ;;
	esac
else
	case "$marked" in
	*unreachable*|*"Network is unreachable"*) pass "marked traffic is unreachable with the tunnel down (fails closed)" ;;
	*) fail "marked traffic still has a route with the tunnel down: $marked" ;;
	esac
fi
echo

# ------------------------------------------------------ 4b: empirical toggle
if [ "$TOGGLE" = 1 ] && [ "$up" = 1 ]; then
	echo "kill-switch, empirical (taking $CFG down):"
	ifdown "$CFG"
	i=0
	while [ $i -lt 15 ] && [ -d "/sys/class/net/$IFACE" ]; do sleep 1; i=$((i + 1)); done

	left="$(ip route show table "$TABLE" 2>/dev/null | grep -c . || echo 0)"
	[ "$left" = 0 ] \
		&& pass "table $TABLE is empty" \
		|| fail "table $TABLE still holds $left route(s) -- stale default keeps sending traffic somewhere"

	marked="$(ip route get 1.1.1.1 mark "$MARK" 2>&1 | head -1)"
	case "$marked" in
	*unreachable*|*"Network is unreachable"*) pass "marked traffic fails closed: $marked" ;;
	*) fail "marked traffic escaped: $marked" ;;
	esac

	echo "  bringing $CFG back up ..."
	ifup "$CFG"
	i=0
	while [ $i -lt 90 ] && [ ! -d "/sys/class/net/$IFACE" ]; do sleep 1; i=$((i + 1)); done
	[ -d "/sys/class/net/$IFACE" ] \
		&& pass "$IFACE returned after ${i}s" \
		|| fail "$IFACE did not return within 90s"
	echo
fi

# ------------------------------------------------------------------- verdict
if [ "$fails" = 0 ]; then
	echo "PASS: no leak found"
	exit 0
fi
echo "FAIL: $fails leak(s)"
exit 1
