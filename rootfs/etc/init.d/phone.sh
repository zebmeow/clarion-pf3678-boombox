#!/bin/sh

### if you use "dbus session-bus", un-comment following
export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
###

case "$1" in
    start)

        until [ -e /tmp/HCI_RESET_DONE ]
        do
                sleep 0.1
        done


	### install ALPS bluetooth driver
#	cd /usr/v6
#	insmod bluetooth.ko
#	insmod crc16.ko
#	insmod sco.ko
#	insmod l2cap.ko
#	insmod rfcomm.ko

##	modprobe bluetooth
##	modprobe crc16
##	modprobe sco
##	modprobe l2cap
##	modprobe rfcomm

##	modprobe hfp-mcasp
	mknod /dev/hfp-mcasp c 77 0


	### install ALPS bluetooth daemon

	export BTA_OPEN_PARMIT_FOLDER_PATH=/tmp/
	export BTA_OPEN_PARMIT_FILE_NAME="BTA_OPEN_PARMIT.log"
        export STUPMGR_PRINT_LOG=1 

	echo "WakeUp bt_daemon priority=10"
	#catchsegv bt_daemon &
	nice -n -10 catchsegv bt_daemon &

	sleep 0.5

	#echo "WakeUp sysMain"
	#catchsegv sysMain > /dev/null 2>&1 &

	#echo "WakeUp MemBkupProx"
	#catchsegv MemBkupProx > /dev/null 2>&1 &

	#sleep 1

	#echo "WakeUp cpf"
	#catchsegv cpf > /dev/null 2>&1 &

	#sleep 0.5

	#echo "WakeUp ComMid"
	#catchsegv ComMid > /dev/null 2>&1 &

	#sleep 1

	#echo "Read psr file"
	#i2c_eeprom

	#echo "WakeUp PhoneBTA"
	#catchsegv PhoneBTA > /dev/null 2>&1 &

	### boombox: run PhoneBTA's Bluetooth audio through the software EQ.
	### Scoped to startupManager's children only; delete the file to disable.
	if [ -f /usr/local/lib/libbtaeq.so ]; then
		export LD_PRELOAD="/usr/local/lib/libbtaeq.so${LD_PRELOAD:+ $LD_PRELOAD}"
		export BTAEQ_LOG=/tmp/btaeq.log   # config reloads + "EQ load: N%" every 10 s
	fi

	echo "bluetooth start: `cut -d' ' -f1 /proc/uptime`" >> /tmp/boombox_times

	echo "Wakeup sartupManager"
	catchsegv startupManager > /dev/null 2>&1 &

      ;;
    stop)

      ;;
    *)
        echo "Usage: /etc/init.d/phone.sh {start|stop}"
        exit 1
        ;;
esac

exit 0

