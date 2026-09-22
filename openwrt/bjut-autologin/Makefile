include $(TOPDIR)/rules.mk

PKG_NAME:=bjut-autologin
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=key-zhzr

include $(INCLUDE_DIR)/package.mk

define Package/bjut-autologin
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Low-overhead BJUT campus network auto-login
  URL:=https://github.com/key-zhzr/BJUT-Auto-Login
  DEPENDS:=+ca-bundle +curl +jshn +jsonfilter +rpcd-mod-iwinfo
endef

define Package/bjut-autologin/description
 A small procd-managed OpenWrt service for the BJUT bjut-sushe,
 bjut_wifi and lgn wired captive portals. Requests are bound to a
 configured upstream interface and credentials are sent only after
 a protocol-specific, read-only gateway probe succeeds.
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	$(MKDIR) $(PKG_BUILD_DIR)
	$(CP) ./src/bjut-codec.c $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-std=c99 -Wall -Wextra -Werror \
		-o $(PKG_BUILD_DIR)/bjut-codec \
		$(PKG_BUILD_DIR)/bjut-codec.c $(TARGET_LDFLAGS)
endef

define Package/bjut-autologin/conffiles
/etc/config/bjut-autologin
endef

define Package/bjut-autologin/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/bjut-autologin $(1)/etc/config/bjut-autologin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/bjut-autologin $(1)/etc/init.d/bjut-autologin
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/95-bjut-autologin \
		$(1)/etc/hotplug.d/iface/95-bjut-autologin
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bjut-codec $(1)/usr/libexec/bjut-codec
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/bjut-autologin $(1)/usr/sbin/bjut-autologin
endef

define Package/bjut-autologin/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || chmod 0600 /etc/config/bjut-autologin 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,bjut-autologin))
