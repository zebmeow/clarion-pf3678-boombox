#!/bin/sh
# boombox probe: stock navi.sh behaviour + Warp diagnostics, written in place
case "$1" in
start)
export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
mkdir -p /media/map /var/apps/navi /var/local
grep -q mmcblk0p6 /proc/partitions && mount /dev/mmcblk0p2 /media/map
O=/var/local/probe.txt
{
echo "=== boot `cat /proc/uptime`"
cat /proc/cmdline /proc/mtd
for f in stat saveno loadno compress shrink separate oneshot halt silent switch canceled; do
	echo "warp/$f=`cat /proc/warp/$f 2>&1`"
done
mount
ls -l /dev/mtd*18*
dd if=/dev/mtdblock18 bs=65536 count=1 2>/dev/null | md5sum
if [ "`cat /proc/warp/stat`" = 1 ] && [ ! -f $O.w ]; then
	touch $O.w
	printf '\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377' > /tmp/f
	i=0
	while [ $i -lt 12 ]; do cat /tmp/f /tmp/f > /tmp/g; mv /tmp/g /tmp/f; i=$((i + 1)); done
	dd if=/tmp/f of=/dev/mtdblock18 bs=65536 count=1
	echo "write exit=$?"
	sync
	dd if=/dev/mtdblock18 bs=65536 count=1 2>/dev/null | md5sum
fi
dmesg | tail -n 100
} >> $O 2>&1
cp $O /media/map/PROBE.TXT
sync
until [ -e /dev/input/PseudoTouchDrv_forNavi ]; do sleep 0.1; done
/etc/init.d/vics.sh start
catchsegv /usr/local/bin/Navi > /dev/null 2>&1 &
sleep 10s
;;
esac
exit 0
