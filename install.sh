#!/bin/sh
# Boombox mod installer for the Clarion PF-3678 SYSTEM partition.
#
#   sh install.sh ROOT eq        stage 1: software EQ + remove the 10 s navigation sleep
#   sh install.sh ROOT ui        boombox screens (needs tools/build_ui.py output in build/ui)
#   sh install.sh ROOT debloat   stage 2: stop car/media services not needed for Bluetooth
#   sh install.sh ROOT fastbt    stage 3: start Bluetooth in parallel instead of last
#   sh install.sh ROOT status    show what is installed / disabled
#   sh install.sh ROOT restore   undo everything
#
# ROOT is "/" when run on the head unit, or the mounted SYSTEM partition (p3) when run
# on a Linux PC. Run it from this directory (it copies files from ./rootfs and ./eq/out).
# Every stage is reversible: originals are kept as *.orig and disabled boot links are
# moved to etc/rcS.d.off/.
set -e

ROOT=${1:?usage: install.sh ROOT eq|ui|debloat|fastbt|status|restore}
ACTION=${2:?usage: install.sh ROOT eq|ui|debloat|fastbt|status|restore}
HERE=$(cd "$(dirname "$0")" && pwd)
RCS=$ROOT/etc/rcS.d
OFF=$ROOT/etc/rcS.d.off
INIT=$ROOT/etc/init.d
SKIN=$ROOT/usr/local/share/skin

# boot links not needed for a Bluetooth-only boombox (stage 2). Only links after S60:
# qt.sh (S60) blocks until the Warp snapshot is taken and resume boots start at S61, so
# earlier services never run on normal boots and could gate the snapshot.
DEBLOAT="S61smartphonelink.sh S62cdplayer S63hdr.psh S64initspeech.psh
S65MeterInfo.sh S69usbaudio.sh S70usbstrage.sh S99upcheckapp.sh"

[ -d "$RCS" ] && [ -d "$INIT" ] || { echo "no etc/rcS.d under $ROOT - wrong partition?"; exit 1; }

case "$ACTION" in
eq|ui|debloat|fastbt)
	# Superseded: images now carry build-specific files (Warp snapshot guard, navi.sh
	# rewritten in place) that only tools/build_image.py produces.
	echo "install stages are superseded: build an SD image with tools/build_image.py"
	exit 1
	;;
esac

replace() { # stock init.d script; keeps the first original as name.orig
	[ -f "$INIT/$1.orig" ] || cp -p "$INIT/$1" "$INIT/$1.orig"
	add "$1"
}

add() { # init.d script that is new with this mod
	cp "$HERE/rootfs/etc/init.d/$1" "$INIT/$1"
	chmod 755 "$INIT/$1"
}

link() { # link name, target script
	rm -f "$RCS/$1"
	ln -s "../init.d/$2" "$RCS/$1"
}

disable() { # boot link name
	if [ -e "$RCS/$1" ] || [ -L "$RCS/$1" ]; then
		mkdir -p "$OFF"
		mv "$RCS/$1" "$OFF/$1"
		echo "  disabled $1"
	fi
}

case "$ACTION" in
eq)
	[ -f "$HERE/eq/out/libbtaeq.so" ] || { echo "build first: eq/build.sh"; exit 1; }
	cp "$HERE/eq/out/libbtaeq.so" "$ROOT/usr/local/lib/libbtaeq.so"
	chmod 755 "$ROOT/usr/local/lib/libbtaeq.so"
	mkdir -p "$ROOT/usr/local/share"
	rm -rf "$ROOT/usr/local/share/btaeq"
	cp -R "$HERE/rootfs/usr/local/share/btaeq" "$ROOT/usr/local/share/btaeq"
	chmod 755 "$ROOT/usr/local/share/btaeq/www/cgi-bin/eq"
	replace navi.sh
	replace phone.sh
	add btaeq.sh
	link S21btaeq.sh btaeq.sh
	echo "stage 1 installed: EQ library, EQ service, navigation sleep removed"
	;;
ui)
	replace qt.sh
	for f in qml/res_qml_files_bf4.rcc image/res_image_files_bf4.rcc; do
		[ -f "$HERE/build/ui/$f" ] || { echo "build first: python3 tools/build_ui.py"; exit 1; }
		[ -f "$SKIN/$f.orig" ] || cp -p "$SKIN/$f" "$SKIN/$f.orig"
		cp "$HERE/build/ui/$f" "$SKIN/$f"
		chmod 644 "$SKIN/$f"
	done
	echo "ui installed: boombox screens (stock bundles kept as *.orig)"
	;;
debloat)
	for l in $DEBLOAT; do disable "$l"; done
	add usbhost.sh
	link S69usbhost.sh usbhost.sh
	echo "stage 2 installed: car/media services disabled (USB host driver still loads)"
	;;
fastbt)
	disable S99phone.sh
	link S62phone.psh phone.sh
	echo "stage 3 installed: Bluetooth starts in parallel at S62"
	;;
status)
	echo "EQ library:   $([ -f "$ROOT/usr/local/lib/libbtaeq.so" ] && echo installed || echo -)"
	echo "EQ config:    $([ -f "$ROOT/var/local/btaeq.conf" ] && echo present || echo '- (created on first boot)')"
	echo "patched:      $(cd "$INIT" && ls *.orig 2>/dev/null | sed 's/\.orig$//' | tr '\n' ' ')"
	echo "UI bundles:   $(ls "$SKIN"/qml/*.orig >/dev/null 2>&1 && echo boombox || echo stock)"
	echo "added links:  $(cd "$RCS" && ls S21btaeq.sh S69usbhost.sh S62phone.psh 2>/dev/null | tr '\n' ' ')"
	echo "disabled:     $( [ -d "$OFF" ] && ls "$OFF" | tr '\n' ' ')"
	;;
restore)
	rm -f "$RCS/S21btaeq.sh" "$RCS/S69usbhost.sh" "$RCS/S62phone.psh"
	if [ -d "$OFF" ]; then
		for l in $(ls "$OFF"); do mv "$OFF/$l" "$RCS/$l" && echo "  re-enabled $l"; done
		rmdir "$OFF"
	fi
	for o in "$INIT"/*.orig "$SKIN"/qml/*.orig "$SKIN"/image/*.orig; do
		[ -f "$o" ] || continue
		mv "$o" "${o%.orig}"
		echo "  restored $(basename "${o%.orig}")"
	done
	rm -f "$INIT/btaeq.sh" "$INIT/usbhost.sh" "$ROOT/usr/local/lib/libbtaeq.so"
	rm -rf "$ROOT/usr/local/share/btaeq"
	echo "restored (EQ settings in /var/local/btaeq.* were left in place)"
	;;
*)
	echo "unknown action: $ACTION"
	exit 1
	;;
esac
