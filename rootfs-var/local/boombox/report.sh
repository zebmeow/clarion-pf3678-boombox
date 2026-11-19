#!/bin/sh
# boombox: status report for reading on any computer (no shell on the unit). Written to
# BOOMBOX/BOOTnnn.TXT on the large FAT partition, one file per boot, last 50 kept.

grep -q ' /media/map ' /proc/mounts || { mkdir -p /media/map; mount /dev/mmcblk0p2 /media/map; } || exit 0
D=/media/map/BOOMBOX
mkdir -p $D

n=`cat /var/local/boombox-boots 2>/dev/null || echo 0`
n=$((n + 1))
echo $n > /var/local/boombox-boots
f=$D/BOOT`printf %03d $n`.TXT

{
	echo "resumed from snapshot:  `cat /proc/warp/stat 2>/dev/null` (1 = Warp resume)"
	echo "uptime now:             `cut -d' ' -f1 /proc/uptime`"
	echo "EQ disabled by NOEQ:    `[ -f $D/NOEQ ] && echo yes || echo no`"
	echo "EQ watchdog fired:      `[ -f $D/EQFAIL ] && echo 'yes (EQFAIL; delete it to retry)' || echo no`"
	echo "EQ build preloaded:     `cat /tmp/btaeq-ok 2>/dev/null || echo none`"
	echo "PhoneBTA running:       `pidof PhoneBTA > /dev/null && echo yes || echo NO`"
	echo "--- EQ library load tests (preloaded into /bin/true)"
	cat /tmp/btaeq-tests.txt 2>/dev/null
	echo "--- boot timing (uptime seconds since resume)"
	cat /tmp/boombox_times 2>/dev/null
	echo "--- EQ state"
	wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?get'
	echo "--- /tmp/btaeq.log (EQ library; 'EQ load' = CPU share of real time)"
	tail -n 40 /tmp/btaeq.log 2>/dev/null
	echo "--- WEFUNK player (wfplay)"
	echo "loopback before boombox: `grep -c UP /tmp/lo-before.txt` (1 = was up)"
	cat /tmp/wfplay-probe.txt 2>/dev/null
	echo "status: `wget -qO- http://127.0.0.1:8089/status`"
	tail -n 30 /tmp/wfplay.log 2>/dev/null
	echo "--- QML errors (QMLLOG.TXT)"
	tail -n 20 $D/QMLLOG.TXT 2>/dev/null
	echo "--- card FAT partition"
	grep media/map /proc/mounts
	ls /media/map/APPS /media/map/APPS/wefunk 2>&1 | head -20
	echo "--- storage (for bigger cards)"
	echo "mmcblk0 sectors seen by the kernel: `cat /sys/block/mmcblk0/size`"
	cat /proc/partitions
	dd if=/dev/mmcblk0 of=/dev/null bs=512 skip=8388608 count=1 2>&1 | tail -n 1 | sed 's/^/read at 4 GiB: /'
	df 2>/dev/null | grep -e mmc -e Filesystem
	echo "--- processes"
	ps
	echo "--- kernel log"
	dmesg | tail -n 60
} > $f 2>&1

rm -f $D/BOOT`printf %03d $((n - 50))`.TXT
sync
exit 0
