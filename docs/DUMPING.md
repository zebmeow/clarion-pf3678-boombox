# Dumping the firmware

The PF-3678 boots from an SD card inside the unit. A dump is a byte-for-byte copy of
that card.

## Taking the dump (macOS)

Remove the card from the unit, put it in a card reader, then:

```sh
diskutil list                                   # find the card, e.g. /dev/disk6
diskutil unmountDisk /dev/disk6
sudo dd if=/dev/rdisk6 of=firmware/clarion-pf3678-golden.img bs=4m status=progress
shasum -a 256 firmware/clarion-pf3678-golden.img
chmod a-w firmware/clarion-pf3678-golden.img    # never edit the original
```

Take the dump twice and compare the checksums before trusting it.

## The dump this mod was developed against

| | |
|---|---|
| Size | 3,934,257,152 bytes (7,684,096 sectors of 512) |
| SHA-256 | `aad2d9f9e11f3b9c3e574d07e897521cfb3e4ec1b49b32b941b876e6912864d5` |

Your dump will have a different checksum if the unit has different settings, paired
phones or software version. The build tools only need the partition layout to match.

## Partition layout

MBR, sector size 512.

| # | Type | Start sector | Sectors | Use |
|---|---|---|---|---|
| 2 | FAT32 (0x0C) | 385,560 | 5,976,180 | Large data partition. The mod writes its boot reports here (`BOOMBOX/BOOTnnn.TXT`). |
| 3 | Linux (0x83) | 6,361,740 | 771,120 | **SYSTEM**: the ext2 root filesystem. The only partition the mod edits. |
| 4 | Extended (0x05) | 7,132,860 | 546,210 | Holds further Linux partitions (first logical: start 7,132,923, 353,367 sectors). |

Partition 1 is unused. The space before partition 2 is not part of any partition and is
left untouched.

## What else holds state

The unit uses Lineo Warp!! hibernation. Its snapshot info area is NOR flash
(`/dev/mtdblock18`), not the SD card, so it is not part of this dump and is not cleared
by flashing a new card. [BUILDING.md](BUILDING.md) explains how the mod deals with that.

## Privacy

A dump of a used unit contains personal data: paired phone names and Bluetooth
addresses, and possibly synced contacts and call history. Do not share a dump without
checking for that.
