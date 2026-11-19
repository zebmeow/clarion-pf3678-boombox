#!/bin/sh
# Build wfplay: a static ARM binary for the head unit (no dependency on its glibc 2.11)
# and a host build for the desktop preview (--null output, paced by the clock).
set -e
cd "$(dirname "$0")"
mkdir -p out
cc -O2 -Wall -Wextra -Wno-unused-function -o out/wfplay-host wfplay.c ../eq/dsp.c -lm -lpthread
zig cc -target arm-linux-musleabihf -mcpu=cortex_a8 -mfpu=neon -static \
	-O2 -Wall -Wno-unused-function -s -o out/wfplay wfplay.c ../eq/dsp.c -lm -lpthread
file out/wfplay
echo "built out/wfplay out/wfplay-host"
