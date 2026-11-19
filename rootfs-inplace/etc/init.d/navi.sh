#!/bin/sh
# boombox: stock navi.sh rewritten IN PLACE (same inode and size; runs after every
# Warp resume at S62). No 10 s sleep, and Bluetooth starts here instead of at S99.
case "$1" in
start)
export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
echo "navi.sh `cut -d' ' -f1 /proc/uptime`" >> /tmp/boombox_times
mkdir -p /media/map /var/apps/navi
grep -q mmcblk0p6 /proc/partitions && mount /dev/mmcblk0p2 /media/map
/etc/init.d/phone.sh start &
until [ -e /dev/input/PseudoTouchDrv_forNavi ]; do sleep 0.1; done
/etc/init.d/vics.sh start
catchsegv /usr/local/bin/Navi > /dev/null 2>&1 &
;;
esac
exit 0
