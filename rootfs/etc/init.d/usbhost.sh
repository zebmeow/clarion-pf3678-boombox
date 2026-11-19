#!/bin/sh
# boombox: replaces usbaudio.sh. Loads the USB host controller driver (needed for a
# USB-Ethernet adapter / telnet access) without starting the Usb media app
# (USB music, iPod, Pandora, Aha).

case "$1" in
    start)
	modprobe ti81xx
      ;;
    stop)

      ;;
    *)
        echo "Usage: /etc/init.d/usbhost.sh {start|stop}"
        exit 1
        ;;
esac

exit 0
