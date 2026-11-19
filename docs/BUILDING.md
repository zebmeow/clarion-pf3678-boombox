# Building, flashing and testing

Paths below are relative to the repository root.

## Building a flashable image (macOS)

```sh
brew install e2fsprogs zig
python3 tools/build_image.py --stages eq,ui --out build/boombox-eq-ui.img
python3 tools/build_image.py --stages eq,ui,debloat,fastbt --out build/boombox-full.img
```

Only partition 3 (SYSTEM) is edited, via debugfs on a copy of the dump. The build
checks the filesystem with e2fsck, reads every written file back, and confirms all
bytes outside partition 3 match the original. Stock files are kept as `*.orig` and
disabled boot links go to `/etc/rcS.d.off`, so `sh install.sh / restore` on the unit
returns those files to stock.

## Warp!! fast boot (read before flashing)

The unit uses Lineo Warp!! hibernation. On a cold boot, `qt.sh` (S60) waits while
SystemManager runs `wr_snapshot`, which saves a RAM snapshot; later boots resume that
snapshot at the same point and only run S61 onwards. The car logs show 111 resume boots
against 13 cold boots. The snapshot's info area is NOR flash `/dev/mtdblock18`, not the
SD card, so flashing a new SD image does not clear it: the unit would resume the old
system (old qtapp + old UI bundles, stock S61+ script list) on top of the new files.

Clarion's updater clears it after every root filesystem update (`reset_warpinfo_area`
in upldetect: 64 KiB of 0xFF at offset 0 of mtdblock18). `tools/warp_reset.sh` does
the same on the unit, with a backup and read-back check:

```sh
sh warp_reset.sh            # show state (this boot resumed? info area set?)
sh warp_reset.sh --reset    # back up to /var/local, then reset
sh warp_reset.sh --restore /var/local/warpinfo-mtd18-<date>.bin
```

After a reset the next boot is a cold boot; it runs every script and SystemManager
takes a new snapshot of whatever system is on the card. Consequences for the mod:
- boot scripts before S61 only run on cold boots, so the debloat only touches S61+
  (earlier services might be part of the readiness count that gates the snapshot)
- `cat /proc/warp/stat` on the unit: 1 = this boot resumed from a snapshot

## Flashing and testing

Keep the original dump (and ideally the original SD card) untouched as the fallback.

There is no shell on the unit, so the card handles Warp by itself:
- `boombox-mark.sh` (S11, before the snapshot point) writes the image's build id to
  `/tmp`, so it ends up inside any snapshot taken from this system.
- `navi.sh` (S62, runs after every resume) is rewritten in place: same inode, blocks and
  size as stock, so it still runs even if a resumed kernel has the old directory cached.
  If the unit resumed a snapshot without this build's id, it backs up the Warp info area
  to `/var/local/boombox-warp.bak`, resets it like Clarion's updater, and reboots. It
  tries at most twice per build, so it cannot loop.
- `boombox-diag.sh` writes `BOOMBOX/BOOTnnn.TXT` to the FAT partition a minute after
  each boot (Warp state, boot timing, EQ state, UI and EQ logs, processes, kernel log).

Expected sequence after flashing: the first power-on may come up on the old UI and
reboot by itself within about a minute; then a slower cold boot to the new UI, which
takes a new snapshot; from then on fast resumes into the new system. If it still shows
the old UI after two automatic reboots, the guard has given up: pull the card and read
the BOOMBOX reports.

```sh
diskutil list                                  # find the SD card, e.g. /dev/disk6
diskutil unmountDisk /dev/disk6
sudo dd if=build/boombox-eq-ui.img of=/dev/rdisk6 bs=4m status=progress
sync && diskutil eject /dev/disk6
```

Test in two steps:

1. `boombox-eq-ui.img`: new screens + EQ, stock boot otherwise. Check that it boots
   to the boombox screen (HOME should also land there), that a phone pairs and plays,
   that prev/next/play work, and that EQ presets audibly change the sound.
2. `boombox-full.img`: adds the debloat and parallel Bluetooth start. Time boot to
   "phone can connect" against the stock ~20 s.

Reading results without a shell: power off, take the card out, open the large FAT
partition on any computer, and read `BOOMBOX/BOOTnnn.TXT` (one per boot).

If a shell is ever available (telnet/serial, root, no password):

```sh
cat /tmp/qtapp.log            # QML errors from the new screens show up here
cat /tmp/btaeq.log            # EQ config loads and "EQ load: N% of real time"
wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?get'
sh warp_reset.sh              # Warp state; --reset / --restore if needed manually
```

To go back to stock: reflash the original dump, or run `sh install.sh / restore`.

## Previewing the UI on the Mac

```sh
python3 -m venv .venv && .venv/bin/pip install PySide6-Essentials   # once
.venv/bin/python preview/preview.py btaudio/BtAudioTopScreen.qml --watch   # live window
.venv/bin/python preview/preview.py btaudio/BtAudioTopScreen.qml --shot out.png
python3 tools/qt4check.py   # before repacking: catches Qt Quick 2 / ES6 constructs
```

The preview loads the stock QML with `ui/` overrides on top, the real image bundle
and strings, and generated mocks for the C++ side. `preview/scenarios/*.json` set mock
values (`--scenario NAME`); enum values are written as `"@CBTAudioControl.STREAM_STATE_ON"`.
Calls into the C++ side (`requestPlayPause`, ...) are printed as `call ...` lines.

Limits: it runs Qt 6, so check with `qt4check.py`; text uses Helvetica Neue in place of
the unit's DFHei-Nissan-P (a DynaComware FDL font desktop Qt cannot load).

## Later: album art (needs a new Bluetooth stack)

The stock Bluetooth stack (libbluedragon / libfusionappl, bt_daemon, PhoneBTA) supports
A2DP, AVRCP metadata + browsing (1.3/1.4), HFP, PBAP, MAP, SPP, OPP and HID, but no BIP,
so AVRCP 1.6 cover art is impossible with it. The stock BT screen never showed real art
either (it uses the fixed image bmp_AUDIO_ARTWORK_BTA_CURRENT; only the iPod and HD Radio
screens have real artwork components). Qt on the unit can display JPEG and PNG.

Plan: replace the stack with BlueZ, which supports AVRCP 1.6 cover art. Starting points:
- the chip is on UART `/dev/ttyO7` (ALPS module; the `.psr` persistent-store files on
  BACKUP_AREA suggest a CSR BlueCore)
- kernel 2.6.37; the PRODUCT_TEST partition already ships `bluetooth`, `l2cap`, `rfcomm`,
  `sco`, `bnep`, `hidp` and `hci_uart` modules
- it replaces PhoneBTA's A2DP → ALSA path (where `libbtaeq.so` hooks in today) and the
  `myCBTAudioControl` data feed the now-playing screen reads

## Install and test one stage at a time

```sh
eq/build.sh
sh install.sh /mnt/system eq        # SYSTEM partition (p3) mounted at /mnt/system
# boot, play Bluetooth audio, check it works; then:
sh install.sh /mnt/system debloat
sh install.sh /mnt/system fastbt
sh install.sh /mnt/system restore   # undo everything
```

## EQ on the unit

```sh
wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?get'
wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?preset=bass'      # flat boombox bass vocal night
wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?g=3,2,0,-1,0,1,2,2,1&pre=-3&hpf=45'
wget -qO- 'http://127.0.0.1:8088/cgi-bin/eq?on=0'             # bypass
```

Bands: 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz (±12 dB). `hpf` is the speaker
protection high-pass (20–150 Hz). Changes apply live within ~0.25 s.

To measure CPU cost, add `export BTAEQ_LOG=/tmp/btaeq.log` next to the `LD_PRELOAD`
line in `/etc/init.d/phone.sh`; the log reports "EQ load: N% of real time" every 10 s.

## Apps on the card (WEFUNK player)

The APPS screen (`ui/smartaccess/SmartAccessMenuScreen.qml`, in its stock slot) only
loads `file:///media/map/APPS/Apps.qml` from the FAT map partition, so apps are plain
files there and can be updated by copying them onto the card's `NAVI_MAP` volume.

- `apps/` – the launcher (`Apps.qml`) and `wefunk/` (WEFUNK Radio archive player in the
  style of `~/Downloads/work/mscplr/player.html`, touch-safe layout)
- `wfplay/` – the player service: static ARM binary (minimp3 + ALSA ioctls + our EQ),
  HTTP on 127.0.0.1:8089, plays to `/dev/snd/pcmC0D0p` (the card Bluetooth audio uses)
  and releases it while paused. `wfplay/build.sh` also builds a host copy for previews.
- `tools/build_wefunk.py` – stages catalog/art/audio from mscplr into `build/fat/APPS`
- `tools/build_slots_image.py --with-apps` – full image incl. FAT apps and wfplay on /var

Preview: `.venv/bin/python preview/preview.py APPS/wefunk/Main.qml --scenario wefunk --prop tab=1`
(runs the host wfplay with silent output against the staged content).
