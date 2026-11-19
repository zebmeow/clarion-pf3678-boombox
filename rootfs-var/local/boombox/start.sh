#!/bin/sh
# boombox: run by phone.sh on every boot (after the Warp resume), before Bluetooth starts.
B=/var/local/boombox

# 1. Which EQ library build can this glibc actually load? Each one is preloaded into
#    /bin/true first; only one that loads AND runs its constructor is used for the
#    Bluetooth stack (/tmp/btaeq-ok). hello.so is a constructor-only probe.
: > /tmp/btaeq-tests.txt
for v in hello.so libbtaeq.so libbtaeq-compat.so; do
	rm -f /tmp/btaeq-t.log
	LD_PRELOAD=$B/$v BTAEQ_LOG=/tmp/btaeq-t.log /bin/true > /tmp/btaeq-t.out 2>&1
	rc=$?
	{ echo "== $v exit=$rc"; cat /tmp/btaeq-t.out /tmp/btaeq-t.log 2>/dev/null; } >> /tmp/btaeq-tests.txt
	case $v in
	lib*)
		if [ $rc = 0 ] && grep -q loaded /tmp/btaeq-t.log 2>/dev/null && [ ! -f /tmp/btaeq-ok ]; then
			echo $B/$v > /tmp/btaeq-ok
		fi
		;;
	esac
done

# 2. EQ control service for the UI, and a status report on the FAT partition
[ -f /var/local/btaeq.conf ] || QUERY_STRING=preset=boombox $B/www/cgi-bin/eq > /dev/null 2>&1
ifconfig lo > /tmp/lo-before.txt 2>&1
ifconfig lo | grep -q UP || ifconfig lo 127.0.0.1 up
httpd -p 127.0.0.1:8088 -h $B/www

# 3. WEFUNK player service for the APPS screen (static binary; app + music on the card)
if [ -x $B/wfplay ]; then
	$B/wfplay --probe > /tmp/wfplay-probe.txt 2>&1
	[ -d /media/map/APPS/wefunk ] && $B/wfplay --root /media/map/APPS/wefunk > /tmp/wfplay.log 2>&1 &
fi
( sleep 90; $B/report.sh ) > /dev/null 2>&1 &
exit 0
