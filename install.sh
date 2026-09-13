#!/bin/sh
# Install straight onto a running router, no package manager involved.
# Copy this whole directory to the router and run it there:
#
#   scp -r luci-app-fw-live-src root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/luci-app-fw-live-src/install.sh'
#
# Uninstall: sh install.sh --remove

set -e

SRC=$(cd "$(dirname "$0")" && pwd)/package/luci-app-fw-live/files

# Everything the package ships, as destination paths, read from the files tree
# rather than listed again here, so adding a file needs no change to this
# script. The config file is left out and handled on its own below: it is
# neither overwritten on install nor removed on uninstall.
FILES=$(cd "$SRC" && find . -type f ! -path './etc/config/*' | sed 's|^\.||' | sort)

if [ "$1" = "--remove" ]; then
	/etc/init.d/fw-live stop 2>/dev/null || true
	/etc/init.d/fw-live disable 2>/dev/null || true
	for f in $FILES; do rm -f "$f"; done
	rm -rf /tmp/fw-live /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache
	/etc/init.d/rpcd reload 2>/dev/null || true
	echo "Removed. /etc/config/fw-live was left in place, and /etc/config/firewall"
	echo "was never touched."
	exit 0
fi

[ -d /etc/init.d ] || { echo "This does not look like an OpenWrt system."; exit 1; }

command -v conntrack >/dev/null 2>&1 || \
	echo "Warning: conntrack not found. Run opkg install conntrack, or accepted connections stay empty."

command -v ucode >/dev/null 2>&1 || [ -f /usr/lib/rpcd/ucode.so ] || \
	echo "Warning: rpcd-mod-ucode does not seem to be installed; the LuCI page will have no backend."

for f in $FILES; do
	mkdir -p "$(dirname "$f")"
	cp "$SRC$f" "$f"
	case "$f" in
		/etc/init.d/*|/usr/bin/*) chmod 0755 "$f" ;;
	esac
done

if [ ! -f /etc/config/fw-live ]; then
	cp "$SRC/etc/config/fw-live" /etc/config/fw-live
	echo "Wrote default config to /etc/config/fw-live"
else
	echo "Kept existing /etc/config/fw-live"
fi

/etc/init.d/fw-live enable
# Stopping a service procd does not know about reports a failure that is not
# one, so the stop is silenced; start alone would leave an already running
# instance untouched and still on the old files.
/etc/init.d/fw-live stop >/dev/null 2>&1
/etc/init.d/fw-live start
/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart
rm -rf /tmp/luci-indexcache /tmp/luci-indexcache.* /tmp/luci-modulecache

echo
echo "Installed. Status:"
/usr/bin/fwlive-status
echo
echo "The page is under Status -> Firewall Live."
