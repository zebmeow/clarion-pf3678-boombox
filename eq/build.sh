#!/bin/sh
# Build libbtaeq.so for the head unit (ARMv7 Cortex-A8, soft-float ABI, glibc 2.11)
# and run the host-side DSP tests. Requires zig (brew install zig).
set -e
cd "$(dirname "$0")"
mkdir -p out

cc -O2 -ffp-contract=off -Wall -Wextra -o out/test_dsp test_dsp.c dsp.c -lm
./out/test_dsp

# Note: zig 0.16 keeps this target on VFPv3 even when NEON is requested, so dsp.c's
# NEON path compiles down to scalar VFP here (correct, just slower). A GCC armel
# toolchain with -mfpu=neon -mfloat-abi=softfp would use real NEON.
zig cc -target arm-linux-gnueabi.2.11 -mcpu=cortex_a8 -mfloat-abi=softfp \
	-O2 -ffast-math -fPIC -shared -fno-stack-protector -Wall \
	-Wl,--version-script=btaeq.map -Wl,-soname,libbtaeq.so -s \
	-o out/libbtaeq.so btaeq.c dsp.c -ldl -lm

# Load-compatibility variants, tested on the unit before use (rootfs-var start.sh):
# conservative linking for old glibc, and a constructor-only probe library.
COMPAT="-Wl,-z,lazy -Wl,-z,norelro -Wl,--hash-style=sysv -Wl,-z,max-page-size=4096 -Wl,-z,common-page-size=4096"
zig cc -target arm-linux-gnueabi.2.11 -mcpu=cortex_a8 -mfloat-abi=softfp \
	-O2 -ffast-math -fPIC -shared -fno-stack-protector -Wall \
	-Wl,--version-script=btaeq.map -Wl,-soname,libbtaeq.so -s $COMPAT \
	-o out/libbtaeq-compat.so btaeq.c dsp.c -ldl -lm
zig cc -target arm-linux-gnueabi.2.11 -mcpu=cortex_a8 -mfloat-abi=softfp \
	-O2 -fPIC -shared -fno-stack-protector -s $COMPAT -o out/hello.so hello.c

echo "built out/libbtaeq.so out/libbtaeq-compat.so out/hello.so"
