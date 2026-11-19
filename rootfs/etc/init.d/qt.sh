#!/bin/sh

case "$1" in
    start)
	### if you use "dbus session-bus", un-comment following
	export DBUS_SESSION_BUS_ADDRESS=`cat /tmp/dbus_session_bus_addr`
	###
	export LD_PRELOAD="/usr/lib/preloadable_libiconv.so $LD_PRELOAD"
	###

	cd /usr/local/bin

	until [ -e /tmp/EVENTDEV_CREATED ]
	do
		sleep 0.1
	done

	echo "WakeUp Qt"
	### boombox: keep qtapp's output (QML errors from the new screens) in RAM-backed /tmp
	catchsegv qtapp -platform eglfs -plugin qclmultitouch:touch=/dev/input/event3 -plugin Qclkey:device=/dev/input/PseudoKeyDrv > /tmp/qtapp.log 2>&1 &

	if [ -f /tmp/STD_BOOT ]; then
		exit 0
	fi
  	touch /tmp/warpstart
  	until [ -e /tmp/WarpEnd ]
  	do
  		sleep 0.1
  	done
      ;;
    stop)

      ;;
    *)
        echo "Usage: /etc/init.d/qt.sh {start|stop}"
        exit 1
        ;;
esac

exit 0

