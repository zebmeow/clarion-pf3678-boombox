#!/bin/sh
# boombox: one minute after each boot, write a report to the SD card's FAT partition
# (folder BOOMBOX on the large FAT32 partition) so it can be read on any computer
# without a shell on the unit. One file per boot: BOOT001.TXT, BOOT002.TXT, ...

case "$1" in
    start)
	;;
    *)
	exit 0
	;;
esac

echo "diag start: `cut -d' ' -f1 /proc/uptime`" >> /tmp/boombox_times
sleep 60

grep -q ' /media/map ' /proc/mounts || { mkdir -p /media/map; mount /dev/mmcblk0p2 /media/map; } || exit 0
D=/media/map/BOOMBOX
mkdir -p $D /var/local

n=`cat /var/local/boombox-boots 2>/dev/null || echo 0`
n=$((n + 1))
echo $n > /var/local/boombox-boots
f=$D/BOOT`printf %03d $n`.TXT

{
	echo "boombox build:          `cat /tmp/boombox_build 2>/dev/null`"
	echo "resumed from snapshot:  `cat /proc/warp/stat 2>/dev/null` (1 = Warp resume, 0 = cold boot)"
	echo "uptime:                 `cat /proc/uptime`"
	echo "--- boot timing (uptime seconds)"
	cat /tmp/boombox_times 2>/dev/null
	echo "--- Warp reset attempts by navi.sh (/var/local)"
	for x in /var/local/boombox-warp.*; do
		[ -f $x ] || continue
		case $x in
		*.bak) echo "$x: backup of the original Warp info area (`wc -c < $x` bytes)" ;;
		*) echo "$x: `cat $x` reset attempt(s) for that build" ;;
		esac
	done
	echo "--- EQ state"
	wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?get'
	echo "--- /tmp/btaeq.log (EQ library)"
	tail -n 40 /tmp/btaeq.log 2>/dev/null
	echo "--- /tmp/qtapp.log (UI; QML errors appear here)"
	tail -n 150 /tmp/qtapp.log 2>/dev/null
	echo "--- processes"
	ps
	echo "--- /proc/mtd"
	cat /proc/mtd
	echo "--- /etc/rcS.d"
	ls /etc/rcS.d
	echo "--- kernel log"
	dmesg | tail -n 60
} > $f 2>&1

# keep the folder small: drop the report from 50 boots ago
rm -f $D/BOOT`printf %03d $((n - 50))`.TXT
sync
exit 0
