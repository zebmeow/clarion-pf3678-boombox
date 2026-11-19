#!/bin/sh
# boombox: records which build this system is. It runs before the Warp snapshot point
# (S60), so the value ends up inside every snapshot taken from this system; navi.sh
# compares it after a resume to detect a snapshot left over from a different system.

case "$1" in
    start)
	echo @BUILD@ > /tmp/boombox_build
      ;;
esac

exit 0
