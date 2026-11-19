#!/bin/sh
# boombox: software EQ support.
#  - seeds /var/local/btaeq.conf from the "boombox" preset on first boot
#  - serves the EQ control endpoint for the UI on 127.0.0.1:8088 (loopback only)

WWW=/usr/local/share/btaeq/www
CGI=$WWW/cgi-bin/eq

case "$1" in
    start)
	mkdir -p /var/local
	if [ ! -f /var/local/btaeq.conf ]; then
		QUERY_STRING="preset=boombox" $CGI > /dev/null 2>&1
	fi
	httpd -p 127.0.0.1:8088 -h $WWW
      ;;
    stop)
	killall httpd 2> /dev/null
      ;;
    *)
        echo "Usage: /etc/init.d/btaeq.sh {start|stop}"
        exit 1
        ;;
esac

exit 0
