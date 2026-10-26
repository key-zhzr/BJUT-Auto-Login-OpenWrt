include $(TOPDIR)/rules.mk

PKG_NAME:=bjut-autologin
PKG_VERSION:=0.1.6
PKG_RELEASE:=25
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=key-zhzr

include $(INCLUDE_DIR)/package.mk

define Package/bjut-autologin
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Low-overhead BJUT campus network auto-login
  URL:=https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt
  DEPENDS:=+ca-bundle +curl +jshn +jsonfilter +rpcd-mod-iwinfo +rpcd +ip-full +coreutils-sha256sum
endef

define Package/bjut-autologin/description
 A small procd-managed OpenWrt service for the BJUT bjut-sushe,
 bjut_wifi and lgn wired captive portals. Requests are bound to a
 configured upstream interface and credentials are sent only after
 a protocol-specific, read-only gateway probe succeeds.
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/bjut-html.c $(PKG_BUILD_DIR)/
	$(CP) ./src/bjut-codec.c $(PKG_BUILD_DIR)/
	$(CP) ./LICENSE $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-std=c99 -Wall -Wextra -Werror \
		-o $(PKG_BUILD_DIR)/bjut-codec \
		$(PKG_BUILD_DIR)/bjut-codec.c $(TARGET_LDFLAGS)
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-std=c99 -Wall -Wextra -Werror -o $(PKG_BUILD_DIR)/bjut-html \
		$(PKG_BUILD_DIR)/bjut-html.c $(TARGET_LDFLAGS)
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
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bjut-html $(1)/usr/libexec/bjut-html
	$(INSTALL_BIN) ./files/usr/libexec/bjut-billing $(1)/usr/libexec/bjut-billing
	$(INSTALL_BIN) ./files/usr/libexec/bjut-billing-monitor $(1)/usr/libexec/bjut-billing-monitor
	$(INSTALL_BIN) ./files/usr/libexec/bjut-traffic-monitor $(1)/usr/libexec/bjut-traffic-monitor
	$(INSTALL_BIN) ./files/usr/libexec/bjut-traffic-sample $(1)/usr/libexec/bjut-traffic-sample
	$(INSTALL_BIN) ./files/usr/libexec/bjut-maintenance $(1)/usr/libexec/bjut-maintenance
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/bjut-autologin $(1)/usr/libexec/rpcd/bjut-autologin
	$(INSTALL_DIR) $(1)/usr/lib/bjut-autologin
	$(INSTALL_DATA) ./files/usr/lib/bjut-autologin/*.sh $(1)/usr/lib/bjut-autologin/
	$(INSTALL_DIR) $(1)/www/.well-known
	$(INSTALL_DATA) ./files/www/.well-known/bjut-autologin.json $(1)/www/.well-known/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/bjut-autologin.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/bjut-autologin $(1)/usr/sbin/bjut-autologin
endef

define Package/bjut-autologin/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
 chmod 0600 /etc/config/bjut-autologin 2>/dev/null || true
 /usr/sbin/bjut-autologin setup >/dev/null 2>&1 || true
 [ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/bjut-autologin/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
 /etc/init.d/bjut-autologin stop >/dev/null 2>&1 || true
 /usr/sbin/bjut-autologin cleanup >/dev/null 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,bjut-autologin))
