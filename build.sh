#!/bin/sh
# PhoebusBSP-6 — build a bootable Linux 6.18 LTS for RTL9607C/Cv2.
#
# Reconstructs the ported kernel tree from three ingredients:
#   1. pristine upstream linux-${KVER} (downloaded)
#   2. pristine vendor SoC code from the Phoebus-SDK submodule (grafted in)
#   3. our 6.18 port, applied as patches/rtl9607c-6.18-port.patch
# then configures, builds, and packages a U-Boot image.
#
# Usage: ./build.sh            # full build -> images/
#        KVER=6.18.40 ./build.sh   # rebase onto another 6.18 point release
set -e

BSP=$(cd "$(dirname "$0")" && pwd)
KVER="${KVER:-6.18.39}"
SDK="$BSP/sdk"                       # Phoebus-SDK submodule
WORK="$BSP/build"
K="$WORK/linux-$KVER"
CROSS_COMPILE="${CROSS_COMPILE:-mips-buildroot-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

[ -d "$SDK/vendor/realtek-net" ] || { echo "ERROR: Phoebus-SDK submodule missing. Run: git submodule update --init"; exit 1; }

# --- 1. toolchain (downloaded by the SDK, not committed) ---
"$SDK/scripts/fetch-toolchain.sh" "$BSP/toolchain"
export PATH="$BSP/toolchain/mips32--glibc--stable-2025.08-1/bin:$PATH"
export ARCH=mips CROSS_COMPILE

# --- 2. pristine kernel ---
mkdir -p "$WORK"; cd "$WORK"
[ -f "linux-$KVER.tar.xz" ] || curl -fL --retry 3 -O "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
rm -rf "$K"; tar xf "linux-$KVER.tar.xz"

# --- 3. graft pristine vendor SoC code (must match the baseline the patch was cut against) ---
cp -a "$SDK/vendor/realtek-net/."                            "$K/drivers/net/ethernet/realtek/"
cp -a "$SDK/vendor/platform/arch/mips/rtl9607c"              "$K/arch/mips/"
cp -a "$SDK/vendor/platform/arch/mips/boot/dts/realtek/."    "$K/arch/mips/boot/dts/realtek/"
cp -a "$SDK/vendor/platform/arch/mips/include/asm/mach-rtl960xc" "$K/arch/mips/include/asm/"
cp -a "$SDK/vendor/platform/drivers/clk/realtek"            "$K/drivers/clk/"
cp -a "$SDK/vendor/platform/drivers/gpio/gpio-rtk-soc.c"    "$K/drivers/gpio/"
cp -a "$SDK/vendor/platform/drivers/watchdog/rtl819x_wdt.c" "$K/drivers/watchdog/"
cp -a "$SDK/vendor/include/net/rtl"                         "$K/include/net/"
cp -a "$SDK/vendor/include/soc/cortina"                     "$K/include/soc/"
cp -a "$SDK/vendor/include/dt-bindings/soc/9607xc_irqs.h"   "$K/include/dt-bindings/soc/"

# --- 4. apply the 6.18 port: overlay the ported versions of changed files ---
# (overlay/ holds the exact ported sources — robust against CRLF/fuzz that a
#  unified-diff patch trips on; docs/port-vs-upstream-*.diff is the human changelog)
cp -a "$BSP/overlay/." "$K/"

# --- 5. rootfs (BEFORE the kernel: the initramfs is baked in during the kernel build) ---
"$SDK/rootfs/build-rootfs.sh" "$WORK/rootfs-tree"

# --- 6. configure + build ---
cp "$BSP/configs/rtl9607c.config" "$K/.config"
# Point the built-in initramfs at the rootfs we just built. This overrides any
# CONFIG_INITRAMFS_SOURCE value in the committed config (which must NOT carry a
# machine-specific absolute path — that was a portability bug).
sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$WORK/rootfs-tree $SDK/rootfs/initramfs-devnodes.txt\"|" "$K/.config"
# host bc is required by the kernel build; the SDK ships a fallback if the host lacks it
command -v bc >/dev/null 2>&1 || export PATH="$SDK/tools/hostbin:$PATH"
make -C "$K" olddefconfig
make -C "$K" -j"$JOBS" uImage.lzma

# --- 7. package ---
# (initramfs is baked in via CONFIG_INITRAMFS_SOURCE; for a separate squashfs+vm.img
#  use the SDK image tools — see README)
mkdir -p "$BSP/images"
cp "$K/arch/mips/boot/uImage.lzma" "$BSP/images/uImage"
echo
echo "Build complete: $BSP/images/uImage  (load 0x80001000)"
echo "RAM-boot test on the board (no flash writes):"
echo "  U-Boot> setenv bootargs console=ttyS0,115200 loglevel=8"
echo "  U-Boot> loady 0x83000000    (send images/uImage via ymodem)"
echo "  U-Boot> bootm 0x83000000"
