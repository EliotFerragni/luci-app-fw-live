#!/bin/sh
# Build the .ipk without an OpenWrt SDK. The package contains only shell,
# ucode and JavaScript, so nothing needs cross compiling. Run on any Linux
# box (or on the router itself) from the directory holding this script.
#
#   ./build-ipk.sh  ->  luci-app-fw-live_<version>_all.ipk

set -e

SRC=$(cd "$(dirname "$0")" && pwd)/package/luci-app-fw-live
VERSION=$(sed -n 's/^PKG_VERSION:=//p' "$SRC/Makefile")
RELEASE=$(sed -n 's/^PKG_RELEASE:=//p' "$SRC/Makefile")
OUT="luci-app-fw-live_${VERSION}-${RELEASE}_all.ipk"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/control"

cp -a "$SRC/files/." "$WORK/data/"
chmod 0755 "$WORK/data/etc/init.d/fw-live" \
           "$WORK/data/usr/bin/fwlive-follow" \
           "$WORK/data/usr/bin/fwlive-logging" \
           "$WORK/data/usr/bin/fwlive-query" \
           "$WORK/data/usr/bin/fwlive-status" \
           "$WORK/data/usr/bin/fwlive-subnets"

SIZE=$(du -sb "$WORK/data" 2>/dev/null | cut -f1 || du -sk "$WORK/data" | cut -f1)

cat > "$WORK/control/control" <<EOC
Package: luci-app-fw-live
Version: ${VERSION}-${RELEASE}
Depends: luci-base, rpcd-mod-ucode, conntrack
Section: luci
Architecture: all
Installed-Size: ${SIZE}
Maintainer: Local build
License: Apache-2.0
Description: Live firewall accept/deny view for LuCI.
 Shows what the firewall is accepting and refusing as it happens. Denied
 packets come from the firewall's kernel log, accepted connections from the
 conntrack event stream. No firewall rules, no packet inspection and no
 effect on flow offloading.
EOC

echo "/etc/config/fw-live" > "$WORK/control/conffiles"

cat > "$WORK/control/postinst" <<'EOC'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/fw-live enable
# Stop and start rather than restart, and swallow the stop: procd leaves an
# unchanged instance alone, so a plain start would keep the old process running
# against the newly installed files, while restart complains that it cannot
# delete a service procd does not know about. Not running is normal here, both
# on a first install and after prerm has already stopped it.
/etc/init.d/fw-live stop >/dev/null 2>&1
/etc/init.d/fw-live start
/etc/init.d/rpcd reload >/dev/null 2>&1
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
exit 0
EOC

cat > "$WORK/control/prerm" <<'EOC'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/fw-live stop >/dev/null 2>&1
/etc/init.d/fw-live disable >/dev/null 2>&1
exit 0
EOC

cat > "$WORK/control/postrm" <<'EOC'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/fw-live
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
/etc/init.d/rpcd reload >/dev/null 2>&1
exit 0
EOC

chmod 0755 "$WORK/control/postinst" "$WORK/control/prerm" "$WORK/control/postrm"

( cd "$WORK/data" && tar --numeric-owner --owner=0 --group=0 -czf ../data.tar.gz ./* )
( cd "$WORK/control" && tar --numeric-owner --owner=0 --group=0 -czf ../control.tar.gz ./* )
echo "2.0" > "$WORK/debian-binary"

( cd "$WORK" && tar --numeric-owner --owner=0 --group=0 -czf package.tar.gz \
	./debian-binary ./data.tar.gz ./control.tar.gz )

cp "$WORK/package.tar.gz" "$OUT"
echo "built $OUT"
