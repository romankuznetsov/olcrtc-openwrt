#
# luci-proto-olcrtc -- LuCI protocol form for the olcRTC tunnel.
#
# Split from the olcrtc package so a headless router can run the tunnel without
# pulling in a web UI. Follows the same convention as luci-proto-wireguard.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-olcrtc
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=WTFPL
PKG_MAINTAINER:=olcrtc-openwrt contributors

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-olcrtc
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=olcRTC protocol support for LuCI
  DEPENDS:=+luci-base +olcrtc
  PKGARCH:=all
endef

define Package/luci-proto-olcrtc/description
Adds olcRTC to the protocol list in LuCI's Network -> Interfaces page, with a
configuration form for provider, room, transport, key file and the
leak-prevention toggles.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-proto-olcrtc/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/olcrtc.js \
		$(1)/www/luci-static/resources/protocol/olcrtc.js
endef

$(eval $(call BuildPackage,luci-proto-olcrtc))
