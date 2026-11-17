include $(TOPDIR)/rules.mk

PKG_VERSION:=0.1.6
PKG_RELEASE:=36
LUCI_TITLE:=LuCI support for BJUT Auto Login
LUCI_URL:=https://github.com/key-zhzr/BJUT-Auto-Login-OpenWrt
LUCI_DEPENDS:=+luci-base +bjut-autologin
LUCI_PKGARCH:=all
PKG_LICENSE:=MIT
PKG_MAINTAINER:=key-zhzr

# LuCI uses luci-base's cache version for loaded modules. Give this package
# its own resource URLs so a plugin-only update also refreshes its modules.
LUCI_BJUT_ASSET_DIR:=bjut-autologin-$(subst .,-,$(PKG_VERSION))-r$(PKG_RELEASE)
LUCI_BJUT_RESOURCES=$(PKG_BUILD_DIR)/htdocs/luci-static/resources

define Build/Prepare/luci-app-bjut-autologin
	$(SED) 's@"path": "bjut-autologin/@"path": "$(LUCI_BJUT_ASSET_DIR)/@g' \
		$(PKG_BUILD_DIR)/root/usr/share/luci/menu.d/luci-app-bjut-autologin.json
	$(FIND) $(LUCI_BJUT_RESOURCES)/bjut-autologin $(LUCI_BJUT_RESOURCES)/view/bjut-autologin \
		-type f -name '*.js' -exec $(SED) \
		"s/require bjut-autologin\./require $(LUCI_BJUT_ASSET_DIR)./g; s@L\.resource('bjut-autologin/@L.resource('$(LUCI_BJUT_ASSET_DIR)/@g" {} +
	mv $(LUCI_BJUT_RESOURCES)/bjut-autologin $(LUCI_BJUT_RESOURCES)/$(LUCI_BJUT_ASSET_DIR)
	mv $(LUCI_BJUT_RESOURCES)/view/bjut-autologin $(LUCI_BJUT_RESOURCES)/view/$(LUCI_BJUT_ASSET_DIR)
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
