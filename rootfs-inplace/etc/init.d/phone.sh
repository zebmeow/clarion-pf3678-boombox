#!/bin/sh
# boombox: stock phone.sh rewritten IN PLACE (same inode/size). Run early by navi.sh
# (S62); the S99 call then hits the lock. Preloads the EQ build that passed start.sh's
# load test, unless BOOMBOX/NOEQ or BOOMBOX/EQFAIL exist on the FAT partition.
export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
case "$1" in
start)
	mkdir /tmp/boombox-phone 2>/dev/null || exit 0
	until [ -e /tmp/HCI_RESET_DONE ]; do sleep 0.1; done
	mknod /dev/hfp-mcasp c 77 0
	export BTA_OPEN_PARMIT_FOLDER_PATH=/tmp/
	export BTA_OPEN_PARMIT_FILE_NAME="BTA_OPEN_PARMIT.log"
	export STUPMGR_PRINT_LOG=1
	echo "bt_daemon `cut -d' ' -f1 /proc/uptime`" >> /tmp/boombox_times
	nice -n -10 catchsegv bt_daemon &
	sleep 0.5
	B=/var/local/boombox
	F=/media/map/BOOMBOX
	[ -x $B/start.sh ] && $B/start.sh
	L=`cat /tmp/btaeq-ok 2>/dev/null`
	[ -f $F/NOEQ ] || [ -f $F/EQFAIL ] && L=
	if [ -n "$L" ]; then
		LD_PRELOAD=$L BTAEQ_LOG=/tmp/btaeq.log catchsegv startupManager > /dev/null 2>&1 &
		# watchdog: no PhoneBTA after 30 s -> restart the chain without the EQ
		( sleep 30
		pidof PhoneBTA > /dev/null && exit 0
		mkdir -p $F; touch $F/EQFAIL
		killall startupManager MemBkupProx sysMain cpf ComMid PhoneBTA SPCOMM
		sleep 1
		catchsegv startupManager > /dev/null 2>&1 ) > /dev/null 2>&1 &
	else
		catchsegv startupManager > /dev/null 2>&1 &
	fi
	;;
esac
exit 0
