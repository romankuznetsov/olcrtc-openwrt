#
# olcrtc -- OpenWrt package
#
# This package does NOT compile olcRTC. The binary is cross-compiled with the
# official Go toolchain (see scripts/build-binary.sh) and staged into
# ./prebuilt/olcrtc by CI before this Makefile runs.
#
# That is deliberate: upstream requires Go 1.26.3, which is newer than the SDK
# ships. Packaging a prebuilt binary decouples us from the SDK's Go version
# entirely, and the same Makefile then produces ipk on 24.10 and apk on 25.12
# because the SDK decides the output format.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=olcrtc
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=WTFPL
PKG_LICENSE_FILES:=
PKG_MAINTAINER:=olcrtc-openwrt contributors

include $(INCLUDE_DIR)/package.mk

define Package/olcrtc
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=olcRTC tunnel (netifd protocol)
  URL:=https://github.com/openlibrecommunity/olcrtc
  # hev-socks5-tunnel bridges the TUN device to olcRTC's SOCKS5 listener.
  #
  # https-dns-proxy used to be a hard dependency here: in catchall mode the
  # router's own traffic is routed into the tunnel, so dnsmasq's plain-UDP
  # queries could not survive and DoH over TCP/443 was the only way to resolve
  # anything. route_mode 'mark' removes that constraint -- router-originated
  # traffic never enters the tunnel -- so the resolver is now the operator's
  # choice, and forcing DoH is actively harmful on a whitelist carrier that
  # blocks the public DoH endpoints (measured: 1.1.1.1:443, 8.8.8.8:443 and
  # cloudflare-dns.com:443 all refused, taking DNS down completely).
  #
  # Recommend it, do not require it, and say what it is for.
  DEPENDS:=+hev-socks5-tunnel +kmod-tun +ip-full
  # Dedicated service account. It exists so `ip rule uidrange` can force
  # olcRTC's own signalling to the main routing table -- otherwise the daemon's
  # traffic to the conferencing service is routed into the tunnel it is trying
  # to establish, and bring-up deadlocks. USERID lets the build system create
  # it correctly on both apk and ipk targets.
  USERID:=olcrtc=8808:olcrtc=8808
  PKGARCH:=$(ARCH)
endef

define Package/olcrtc/description
Tunnels TCP over the WebRTC datachannel of a public conferencing service,
exposed as a netifd protocol so it appears and is controllable under
Network -> Interfaces in LuCI.

The tunnel carries TCP over IPv4 only. UDP, QUIC and IPv6 cannot traverse it
and are rejected rather than allowed to leak; see /usr/share/olcrtc/README.
endef

# No conffiles. An earlier version declared /etc/config/olcrtc, which nothing
# creates: the settings live in the `olcrtc` interface in /etc/config/network
# and in the firewall zone, both seeded by uci-defaults. Declaring a path that
# does not exist made sysupgrade preserve nothing while looking like it did.

# Nothing to configure, patch or compile: Build/Compile is intentionally a
# no-op. The binary already exists.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
	$(if $(wildcard ./prebuilt/olcrtc),,$(error prebuilt/olcrtc missing -- run scripts/build-binary.sh first))
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) ./prebuilt/olcrtc $(PKG_BUILD_DIR)/olcrtc
endef

define Package/olcrtc/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/olcrtc $(1)/usr/bin/olcrtc

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/olcrtc-link $(1)/usr/libexec/olcrtc-link

	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/olcrtc.proto $(1)/lib/netifd/proto/olcrtc.sh

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/olcrtc.uci-defaults $(1)/etc/uci-defaults/90-olcrtc

	$(INSTALL_DIR) $(1)/usr/share/olcrtc
	$(INSTALL_DATA) ./files/hev-tunnel.yaml.template $(1)/usr/share/olcrtc/
	$(INSTALL_DATA) ./files/olcrtc.yaml.template $(1)/usr/share/olcrtc/
	$(INSTALL_DATA) ./files/README $(1)/usr/share/olcrtc/README
endef

define Package/olcrtc/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
ifdown olcrtc 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,olcrtc))
