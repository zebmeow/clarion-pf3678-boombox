#!/bin/sh
# boombox: stock navi.sh rewritten IN PLACE (same inode, same 1377 bytes) so it still
# runs after the unit resumes a Warp snapshot taken from the previous system.
case "$1" in
start)
export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
B=@BUILD@
F=/var/local/boombox-warp
if [ "`cat /proc/warp/stat 2>/dev/null`" = 1 ] && [ "`cat /tmp/boombox_build 2>/dev/null`" != $B ]; then
	# resumed a snapshot of another system: reset it like Clarion's updater, reboot
	n=`cat $F.$B 2>/dev/null || echo 0`
	if [ $n -lt 2 ]; then
		mkdir -p /var/local
		echo $((n + 1)) > $F.$B
		[ -f $F.bak ] || dd if=/dev/mtdblock18 of=$F.bak bs=65536 count=1 2>/dev/null
		printf '\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377' > /tmp/ff
		i=0
		while [ $i -lt 12 ]; do cat /tmp/ff /tmp/ff > /tmp/f2; mv /tmp/f2 /tmp/ff; i=$((i + 1)); done
		dd if=/tmp/ff of=/dev/mtdblock18 bs=65536 count=1 2>/dev/null
		sync
		reboot
		exit 0
	fi
fi
mkdir -p /media/map /var/apps/navi
grep -q mmcblk0p6 /proc/partitions && mount /dev/mmcblk0p2 /media/map
until [ -e /dev/input/PseudoTouchDrv_forNavi ]; do sleep 0.1; done
/etc/init.d/vics.sh start
catchsegv /usr/local/bin/Navi > /dev/null 2>&1 &
# no "sleep 10s": only the Navi stub runs and nothing waits on it
;;
esac
exit 0
