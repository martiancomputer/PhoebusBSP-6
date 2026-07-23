# PhoebusBSP-6

Linux **6.18 LTS** board support for Realtek Phoebus (RTL9607C / RTL9607Cv2 —
big-endian MIPS32r2 interAptiv, MIPS_CPS + MT SMP / 4 VPEs, GIC).

Built on the shared [Phoebus-SDK](https://github.com/martiancomputer/Phoebus-SDK)
(vendor SoC code + toolchain fetch + tools), wired in as the `sdk/` submodule.
The mainline/bleeding-edge line lives in
[PhoebusBSP-7](https://github.com/martiancomputer/PhoebusBSP-7).

## What's here (the *port*, not the kernel)

```
build.sh        one-shot: fetch kernel + toolchain, graft vendor, overlay port, build, package
configs/
  rtl9607c.config   working kernel .config (RTK_SOC_RTL9607C=y, CPS+MT SMP, GIC, 8250, squashfs, initramfs)
overlay/        exact ported sources for the ~86 files we changed vs upstream 6.18.39
                (arch/mips platform + Kconfig/Makefile wiring, the rtl86900 SDK 6.18
                 API edits, header deltas, scripts/Makefile.lib). build.sh copies this
                over the pristine+vendor tree — reliable against the SDK's CRLF files.
docs/
  port-vs-upstream-6.18.39.diff   human-readable changelog of every edit vs pristine 6.18.39
sdk/            Phoebus-SDK submodule (vendor SoC code, toolchain fetch, image tools, rootfs)
```

Nothing here duplicates upstream or the vendor SDK: `build.sh` reconstructs a full
buildable tree from three pinned ingredients (pristine kernel + `sdk/` vendor code +
`overlay/`). Verified: pristine 6.18.39 + graft + overlay == the tree that boots.

## Build

```sh
git clone --recurse-submodules https://github.com/martiancomputer/PhoebusBSP-6
cd PhoebusBSP-6
git submodule update --init          # pulls Phoebus-SDK
./build.sh                            # -> images/uImage  (load 0x80001000)
```

## Boot / test on hardware (no flash writes)

U-Boot is `Phoebus#`, NAND+UBI. RAM-boot the image over serial (no Ethernet needed):

```
U-Boot> setenv bootargs console=ttyS0,115200 loglevel=8
U-Boot> loady 0x83000000        # send images/uImage via ymodem (picocom: sb)
U-Boot> bootm 0x83000000
```

## Status

Boots to userspace on real RTL9607C: 4-CPU SMP, 256 MB RAM, GIC timer/clocksource,
ttyS0 console, GPIO, USB PHY (rev C), switch core + FleetConntrack init. See
`PORT_NOTES.md` for the full port log and the open peripheral-IRQ items
(switch link-change / USB host IRQs — hardcoded legacy GIC numbers being migrated
to DT-based mapping). xPON/GPON/EPON retained and Kconfig-selectable.
