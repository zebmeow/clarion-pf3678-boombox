# Adding your own mods

All mods follow the same loop: change files in this repository, build an image from
your dump, flash it, and read the boot reports.

## Unpack the stock UI

The UI lives in Qt 4 resource bundles on the SYSTEM partition. Copy them out of your
dump into `stock/` (not included in this repository), then:

```sh
python3 tools/rcc_extract.py stock/res_qml_files_bf4.rcc   out/qml      # every QML file
python3 tools/rcc_extract.py stock/res_image_files_bf4.rcc out/images   # every image
python3 tools/qm_dump.py     stock/res_language_us_gen_bf4.qm           # UI strings
```

## Change or add a screen

Put a QML file under `ui/` at the same path as the stock file it replaces, for example
`ui/btaudio/BtAudioTopScreen.qml`. When the image is built, files in `ui/` replace the
stock ones inside the bundle.

The unit runs Qt 4 (Qt Quick 1). Before building:

```sh
python3 tools/qt4check.py        # flags Qt Quick 2 and ES6 constructs the unit cannot run
```

## Preview on a computer

```sh
python3 -m venv .venv && .venv/bin/pip install PySide6-Essentials
.venv/bin/python preview/preview.py btaudio/BtAudioTopScreen.qml --watch
.venv/bin/python preview/preview.py btaudio/BtAudioTopScreen.qml --shot out.png
```

The preview loads the stock QML with `ui/` on top and mocks the C++ side.
`preview/scenarios/*.json` set the mock values.

## Images and icons

New images go in `ui/images/`. The image bundle has fixed slots, so new icons take over
slots of stock images the mod no longer shows; `tools/rcc_slots.py` and
`tools/build_slots_image.py` handle that mapping.

## Add an app

Apps are QML under `apps/<name>/`, listed in `apps/Apps.qml`. An app that needs native
code talks to a small local service over HTTP with `XMLHttpRequest`; `wfplay/` is the
example (a static binary, started from a boot script in `rootfs/etc/init.d/`).

## EQ

`eq/dsp.c` is the signal processing, `eq/btaeq.c` the hook into the Bluetooth audio
path. `eq/build.sh` runs the host tests, then cross-compiles with zig. Presets are
installed from `rootfs/`.

## Boot scripts

Files under `rootfs/` are copied onto the SYSTEM partition at the same path. Read the
Warp!! section of [BUILDING.md](BUILDING.md) first: scripts before S61 only run on cold
boots.

## Build, flash, check

See [BUILDING.md](BUILDING.md). There is no shell on the unit, so results come back as
`BOOMBOX/BOOTnnn.TXT` files on the card's FAT partition, one per boot.
