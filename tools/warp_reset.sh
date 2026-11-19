#!/bin/sh
# Invalidate the Lineo Warp!! resume snapshot so the next boot is a cold boot.
# Runs ON THE HEAD UNIT (busybox ash), as root.
#
#   sh warp_reset.sh            show Warp state, change nothing
#   sh warp_reset.sh --reset    back up and reset the Warp info area
#   sh warp_reset.sh --restore FILE   write a backup taken by --reset back
#
# This is the same operation Clarion's own updater performs after it rewrites the
# root filesystem (upldetect: reset_warpinfo_area): 64 KiB of 0xFF written at offset
# 0 of /dev/mtdblock18 (NOR flash). Without it, the unit resumes the snapshot taken
# from the previous system and the new root filesystem's boot scripts never run.
# After a reset the next boot is a cold boot, and SystemManager takes a fresh
# snapshot of the new system by itself (wr_snapshot).

MTD=${WARP_MTD:-/dev/mtdblock18}   # override only for testing
# Note: the unit's busybox dd (1.19.3) has no conv= option at all; a block device is
# never truncated, so plain dd is correct there. Tests on a regular file must pre-size it.
SIZE=65536
FF_MD5=ecb99e6ffea7be1e5419350f725da86b   # md5 of 65536 bytes of 0xFF

say() { echo "warp_reset: $*"; }

show() {
	say "this boot: $( [ "$(cat /proc/warp/stat 2>/dev/null)" = 1 ] && echo 'resumed from snapshot' || echo 'cold boot (or no /proc/warp)')"
	say "STD_BOOT (Warp disabled for this model): $( [ -f /tmp/STD_BOOT ] && echo yes || echo no)"
	say "mtd18: $(grep '^mtd18:' /proc/mtd 2>/dev/null || echo 'not listed in /proc/mtd')"
	if [ -e $MTD ]; then
		cur=$(dd if=$MTD bs=$SIZE count=1 2>/dev/null | md5sum | cut -d' ' -f1)
		[ "$cur" = "$FF_MD5" ] && say "Warp info area: already reset (all 0xFF)" || say "Warp info area: holds snapshot info (md5 $cur)"
	fi
}

case "$1" in
"")
	show
	echo "Run with --reset to invalidate the snapshot."
	;;
--reset)
	show
	[ -e $MTD ] || { say "$MTD missing - not resetting"; exit 1; }
	BACKUP_DIR=${WARP_BACKUP_DIR:-/var/local}
	mkdir -p $BACKUP_DIR
	backup=$BACKUP_DIR/warpinfo-mtd18-$(date +%Y%m%d-%H%M%S).bin
	dd if=$MTD of=$backup bs=$SIZE count=1 2>/dev/null && [ "$(wc -c < $backup)" -eq $SIZE ] \
		|| { say "backup failed - not resetting"; exit 1; }
	say "backup: $backup"

	# 16 bytes of 0xFF doubled 12 times = 65536 bytes
	ff=/tmp/warp_reset_ff.bin
	printf '\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377\377' > $ff
	i=0
	while [ $i -lt 12 ]; do cat $ff $ff > $ff.2 && mv $ff.2 $ff; i=$((i + 1)); done
	[ "$(md5sum < $ff | cut -d' ' -f1)" = "$FF_MD5" ] || { say "could not build the 0xFF block - not resetting"; exit 1; }

	dd if=$ff of=$MTD bs=$SIZE count=1 2>/dev/null
	sync
	rm -f $ff
	if [ "$(dd if=$MTD bs=$SIZE count=1 2>/dev/null | md5sum | cut -d' ' -f1)" = "$FF_MD5" ]; then
		say "reset done; the next boot will be a cold boot and take a new snapshot"
	else
		say "read-back mismatch! restore with: sh $0 --restore $backup"
		exit 1
	fi
	;;
--restore)
	[ -f "$2" ] && [ "$(wc -c < "$2")" -eq $SIZE ] || { say "usage: $0 --restore BACKUP (64 KiB file)"; exit 1; }
	dd if="$2" of=$MTD bs=$SIZE count=1 2>/dev/null
	sync
	cmp -s "$2" "$(dd if=$MTD bs=$SIZE count=1 2>/dev/null > /tmp/warp_rb.bin; echo /tmp/warp_rb.bin)" \
		&& say "restored $2" || { say "restore read-back mismatch"; exit 1; }
	rm -f /tmp/warp_rb.bin
	;;
*)
	echo "usage: $0 [--reset | --restore FILE]"
	exit 1
	;;
esac
