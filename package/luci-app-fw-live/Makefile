include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fw-live
PKG_VERSION:=1.0.8
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Local build

include $(INCLUDE_DIR)/package.mk

# Shell, ucode and LuCI JavaScript only, so the package fits any target.
PKGARCH:=all

define Package/luci-app-fw-live
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Live firewall accept/deny view
  DEPENDS:=+luci-base +rpcd-mod-ucode +conntrack
endef

define Package/luci-app-fw-live/description
 A live view of what the firewall is accepting and refusing, in LuCI. Denied
 packets come from the firewall's own kernel log, accepted connections from
 the conntrack event stream. It adds no firewall rules and inspects no
 packets, so software and hardware flow offloading are untouched.
endef

define Package/luci-app-fw-live/conffiles
/etc/config/fw-live
endef

# Nothing to build. Without these two lines the default rule runs make in an
# empty build directory and the package fails to compile.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-fw-live/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/fw-live $(1)/etc/config/fw-live
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/fw-live $(1)/etc/init.d/fw-live
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/fwlive-follow $(1)/usr/bin/fwlive-follow
	$(INSTALL_BIN) ./files/usr/bin/fwlive-logging $(1)/usr/bin/fwlive-logging
	$(INSTALL_BIN) ./files/usr/bin/fwlive-query $(1)/usr/bin/fwlive-query
	$(INSTALL_BIN) ./files/usr/bin/fwlive-status $(1)/usr/bin/fwlive-status
	$(INSTALL_BIN) ./files/usr/bin/fwlive-subnets $(1)/usr/bin/fwlive-subnets
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/luci.fw_live.uc $(1)/usr/share/rpcd/ucode/luci.fw_live.uc
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-fw-live.json $(1)/usr/share/rpcd/acl.d/luci-app-fw-live.json
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-fw-live.json $(1)/usr/share/luci/menu.d/luci-app-fw-live.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/fw-live
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fw-live/main.js $(1)/www/luci-static/resources/view/fw-live/main.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fw-live/settings.js $(1)/www/luci-static/resources/view/fw-live/settings.js
endef

define Package/luci-app-fw-live/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/fw-live enable
# Stop and start rather than restart, and swallow the stop: procd leaves an
# unchanged instance alone, so a plain start would keep the old process running
# against the newly installed files, while restart complains that it cannot
# delete a service procd does not know about. Not running is normal here, both
# on a first install and after prerm has already stopped it.
/etc/init.d/fw-live stop >/dev/null 2>&1
/etc/init.d/fw-live start
/etc/init.d/rpcd reload >/dev/null 2>&1
# LuCI caches the menu and the module index; both have to go or the new entry
# will not show up until something else invalidates them.
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
exit 0
endef

define Package/luci-app-fw-live/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/fw-live stop >/dev/null 2>&1
# opkg passes "upgrade" when a newer version is replacing this one, and only a
# real removal should drop the rc.d symlink. Disabling on upgrade leaves the
# service off permanently if the install dies before the new postinst runs.
[ "$$1" = "upgrade" ] || /etc/init.d/fw-live disable >/dev/null 2>&1
exit 0
endef

define Package/luci-app-fw-live/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/fw-live
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
/etc/init.d/rpcd reload >/dev/null 2>&1
# /etc/config/firewall is left exactly as it was: this package never wrote it.
exit 0
endef

$(eval $(call BuildPackage,luci-app-fw-live))
