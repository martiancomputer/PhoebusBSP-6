# RTL9607C/Cv2 → Linux 6.18 LTS SDK port

Target: **RTL9607C / RTL9607Cv2** — big-endian MIPS32r2 **interAptiv** (MT), SMP via
MIPS_CPS + MIPS_MT_SMP, L2C (MIPS_CPU_SCACHE), vectored IRQs, builtin DTB,
kernel load address `0xffffffff80001000`.

## Source material
| Path | Role |
|---|---|
| `../rtl8198d-sdk-main/linux-5.10.x` | Vendor 5.10.226 tree with `arch/mips/rtl9607c/` platform — **porting base** |
| `../rtl8198d-sdk-main/oemconfig/linux-{nand,nor}.config` | Real vendor .config for the 9607C MIPS build (copied to `patches/`) |
| `../GPL-for-GP3000-main` | Same SDK, 9607F ARM board configs — reference only |
| `../AX10v3_GPL/rtl8198` | linux-4.4 MIPS tree + msdk-4.8.5 (gcc 4.8, too old) — reference only |
| `../rtl96xx-master` | Old Apollo 2.6.x SDK + `doc/RTL9607pdf/*.pdf` hardware docs |

## Vendor delta in the 5.10 tree (to graft onto 6.18)
- `arch/mips/rtl9607c/` (~30 files, ~4.1k LoC C) — setup/irq/irq-ipi/smp/timer/cevt-ext/serial/dma/pci/usb/of/prom/watchdog
- `arch/mips/include/asm/mach-rtl960xc/`
- `arch/mips/boot/dts/realtek/` — `rtl9607c_soc.dtsi`, `rtl9607c_engboard.dts`
- Hooks: `arch/mips/Kconfig` (`source arch/mips/rtl9607c/Kconfig`), `arch/mips/Kbuild.platforms`, top `Makefile` (`drivers-y += realtek/`, `rtk_voip/`)
- `realtek/` root dir (misc rtk modules), `drivers/clk/realtek` (COMMON_CLK_RTK_APRO / rtk-clk-apro-ocp)
- `drivers/net/ethernet/realtek/rtl86900` (88M switch/GPON SDK), `rtl82xx` (47M) — later phase
- `drivers/watchdog/rtl819x_wdt.c`, GPIO_RTK_SOC, spi-nand bits

## Toolchain
Old msdk gcc-4.8 can't build 6.18 (needs GCC ≥ 8). Using
**bootlin mips32--glibc--stable-2025.08-1** (big-endian mips32r2). Tune:
`-march=interaptiv` optional; baseline `CONFIG_CPU_MIPS32_R2` + MT.

## Plan
1. Diff vendor 5.10 vs vanilla 5.10.226 → `patches/vendor-delta/` (file lists + patch).
2. Unpack linux-6.18.39 as `linux-6.18.x/`, graft platform dirs, wire Kconfig/Kbuild.
3. Port API drift 5.10→6.18 (irq flow, clockevents, smp-ops, DMA noncoherent,
   `plat_mem_setup`/memblock, vdso, earlycon).
4. Seed `.config` from vendor nand config via `make olddefconfig`; build; iterate.
5. Bring up drivers in order: serial console → timer/IPI → spi-nand/mtd → ethernet/switch.

## Port log (2026-07-22)
- Host `bc` missing → built GNU bc 1.08.2 into `hostbin/` (gavinhoward bc configure broke on host sed).
- Kconfig fully wired; vendor nand config seeds `.config` via olddefconfig (RTK_SOC_RTL9607C=y, CPS+MT_SMP, GIC, 8250).
- API fixes applied:
  - `early_init_dt_scan_memory()` direct call (setup.c)
  - `TIMER_OF_DECLARE` rename; cevt-ext.c rewritten: cpuhp (CPUHP_AP_ONLINE_DYN) replaces CPU notifiers; `request_irq`+`irq_force_affinity` replaces vendor `mips_gic_init_one` GIC patch; `cycle_t`→u64; `__be32` addr handling
  - `linux/stdarg.h` (promlib.c), `ioremap` (serial.c), `pde_data()` (usb.c)
  - smp.c: dropped removed `register_cmp_smp_ops`
  - gpio-rtk-soc.c: `gpio/driver.h` include, `GPIO_LINE_DIRECTION_*`, int-returning `.set`, `fwnode` instead of `of_node`, `gpiochip_add_data`, void `.remove`
  - EXPORT_SYMBOL patches ported to mips-cm.c and mm/cache.c
- rtl86900 switch SDK copied (headers needed by gpio); its Kconfig NOT yet wired into 6.18 build — next big phase.
- irq-ipi.c compiles to empty stub under CPS — no port needed.

## Milestone 1 reached (2026-07-22)
**vmlinux builds clean**: Linux 6.18.39, ELF 32-bit MSB MIPS32r2, 14.2 MB,
builtin `rtl9607c_engboard` DTB embedded with `__dtb_start` pointing at it.
- dtb wiring: `subdir-$(CONFIG_RTK_MIPS_SOC)` added to arch/mips/boot/dts/Makefile;
  realtek dts Makefile rewritten for the generic BUILTIN_DTB_ALL wrapper
  (exactly one dtb-y per Luna SoC config); copied `dt-bindings/soc/9607xc_irqs.h`.
- Interim shims to revisit when rtl86900 SDK is wired in:
  - gpio-rtk-soc.c runs in direct-MMIO mode (`CONFIG_LUNA_SOC_GPIO` #define commented out)
  - `rtk_switch_version_get` weak stub in arch/mips/rtl9607c/usb.c (USB PHY uses default params)
Build: `cd linux-6.18.x && PATH=$PWD/../hostbin:$PWD/../toolchain/mips32--glibc--stable-2025.08-1/bin:$PATH make ARCH=mips CROSS_COMPILE=mips-buildroot-linux-gnu- -j$(nproc) vmlinux`
Next: image packaging (task 6), rtl86900 switch SDK port (task 7).

## Milestone 2: boot image packaging (2026-07-22)
- `make uImage.lzma` works: lzma kernel, load 0x80001000, entry = kernel_entry (0x808c2ae4).
- `tools/mk_images.sh` reproduces the vendor flow: 2k NAND alignment + genhead
  header (key 0xa0000203, flash base 0xbd000000) -> `images/uImage`, `images/vm.img`.
  Header verified against format: key/len/cksum/flashp + uImage magic 0x27051956.
- packimg tools rebuilt from AX10v3 sources with 64-bit fixes (flashp pointer->u32
  to preserve on-flash layout, fdInput lseek, fclose).
- Signed-FIT (phoebus) flow copied to tools/ but vendor RSA key PHOEBUS_UOOT_FIT_KEY
  is not in the GPL dumps; if the device U-Boot enforces signatures, flashing needs
  the non-secure path or the real key. rootfs part of vm.img pending userland phase.

## rtl86900 switch SDK wiring (in progress)
- Vendor Kconfig/Makefile deltas merged into 6.18 realtek net dir (patches/realtek-net-*.diff).
- Fixed vendor bugs 6.18's kconfig rejects: unterminated `source "...mvl88x3310/Kconfig`,
  and duplicate `config GPON_FEATURE`/EPON blocks under `if LUNA_G3_SERIES=y|!=y`
  (segfaulted menu_finalize; merged into single defs with LUNA_G3_SERIES deps).
- Compiler_Flag now includes $(objtree)/.config when built in-tree.
- Vendor core-header deltas ported: 33 applied via patch; hand-merged skbuff.h
  (Realtek private sk_buff fields + NET_SKB_PAD), x_tables.h (in/out/hooknum +
  xt_table_spin_lock_bh); skipped fs_context.h (mainlined) and
  nf_conntrack_ecache.h (CHAIN_EVENTS not in 9607C config).
- include/soc (cortina rtk_* headers) copied.
- scripts/Makefile.lib: restored EXTRA_*FLAGS -> ccflags-y compat (87 vendor
  Makefiles depend on it; removed upstream in 5.x).

## rtl86900 SDK compile port (iterations 12-16)
- Kernel Makefile now exports KDIR/NETDIR/APOLLODIR/SDKDIR for vendor sub-Makefiles.
- Compiler_Flag includes $(objtree)/.config in-tree.
- Batch API renames across subtree: del_timer[_sync]->timer_delete[_sync],
  strlcpy->strscpy, PDE_DATA->pde_data, <stdarg.h> -> <linux/stdarg.h>.
- GRO_DROP compat define (removed 5.12); netdev_max_backlog->net_hotdata.max_backlog;
  netif_napi_add->netif_napi_add_weight (4-arg form).
- FleetConntrack rtk_fc_assistant.c: neighbour walk -> neigh_for_each_in_bucket_rcu
  (hash_buckets/->next gone), br_allowed_ingress gains &vlan arg.
- rtk_fc_helper_ps.c: __init_timer -> timer_setup; BROPT_MULTICAST_QUERIER (removed
  from enum) -> br->multicast_ctx.multicast_querier.
- dal_rtl9607c_time.c: file-static `time_init` guard renamed (clashed with kernel
  time_init()); SO_RCVMARK dup dropped from mips + asm-generic socket.h (mainlined).
- Per-dir warning demotions in realtek/Makefile for GCC14 strictness (vendor code
  predates -Werror=int-conversion/incompatible-pointer-types/enum-conversion/
  missing-prototypes/return-type/old-style-declaration/date-time/implicit-int).

## Milestone 3: full switch/GPON SDK links (iterations 17-20)
- rtk_fc_internal.c: skb_recv_datagram 4->3 args; refcount .counter -> refcount_read().
- sdk osal thread.c: complete_and_exit -> kthread_complete_and_exit (removed 5.17).
- Copied vendor include/net/rtl/ (rtl_types.h etc) needed by epon modules.
- re8686_rtl9607c.c: NULL-terminated of_platform_rtk_gmac_table[] (modpost fatal).
- Remaining warning demotions: enum-int-mismatch, empty-body, implicit-fallthrough, address.
- RESULT: vmlinux links at 24 MB (was 14 MB); 1180+ switch/NIC/GPON/FC symbols present
  (rtk_fc_mgr_init, rtk_gmac, dal_rtl9607c, gpon). uImage.lzma 4.3 MB, images/vm.img packed.
- Non-fatal: section-mismatch warnings on __init_plat_ehci2 (vendor USB init refs
  .init.data from .text) - cosmetic, revisit if USB2 misbehaves.
- STILL TODO before real boot: revert gpio direct-MMIO shim + rtk_switch_version_get
  weak stub now that SDK is present; build userland/rootfs; serial-console bring-up on HW.

## Shims reverted (iteration 21) — no more interim stubs
- gpio-rtk-soc.c: re-enabled `#define CONFIG_LUNA_SOC_GPIO` (vendor default). Driver
  now drives GPIO via SDK HAL (rtk_gpio_state/mode/databit/intr_*); the .o carries
  U refs that resolve against the built-in rtl86900 SDK. Direct-MMIO path is dead code.
- arch/mips/rtl9607c/usb.c: removed the weak rtk_switch_version_get stub; the real
  SDK symbol (rtk/switch.h via dal_rtl9607c_switch.h) is used, so USB PHY now keys
  off the actual chip revision (RTL9607C_CHIP_ID / CHIP_REV_ID_C).
- vmlinux still links clean (24 MB). uImage.lzma 4.3 MB re-packaged.
- Remaining before HW boot: userland/rootfs build; on-target serial-console bring-up.

## Milestone 4: minimal busybox rootfs + full vm.img (2026-07-22)
- busybox 1.37.0 built STATIC for mips BE (bootlin toolchain). Fixed: disabled
  CONFIG_STATIC off->on, CONFIG_TC off, and x86-only CONFIG_SHA1/256_HWACCEL
  (sha*_shaNI undeclared on MIPS). Binary: ELF 32-bit MSB MIPS32 static.
- rootfs tree in rootfs-build/rootfs: busybox+applets, /etc/{inittab,fstab,passwd,
  group,init.d/rcS}, mountpoints. init->bin/busybox. DEVTMPFS_MOUNT=y provides
  /dev/console before init, so no static dev nodes needed.
- Squashfs via vendor tools/mksquashfs (32-bit i386 host binary) -comp xz -all-root
  -> images/rootfs (1.05 MB, squashfs v4.0 little-endian on-disk = standard; BE
  kernel driver byteswaps). 426 inodes, static busybox inside.
- images/vm.img (5.6 MB) = [genhead a0000203][uImage@0x40][genhead a0000403 @0x44F040]
  [squashfs hsqs @0x44F080]. genhead -o header = 64 bytes. Layout verified by magics.
- NOTE: on-HW boot needs real U-Boot + partition/UBI map to pass root= and split
  kernel/rootfs; cannot be validated in this environment. Image FORMAT matches the
  vendor non-secure vmimg flow.

## STATE SUMMARY
Kernel 6.18.39 (BE MIPS32r2, RTL9607C) + full rtl86900 switch/GPON SDK + minimal
busybox squashfs rootfs all build clean and package into images/vm.img. No stubs.
Next candidates: expand rootfs with vendor userland packages (rtl8198d-sdk-main/user,
148 pkgs) as needed; on-target serial bring-up; UBI-volume image (mkfs.ubifs/ubinize)
if the device uses raw NAND+UBI rather than the vm.img concat path.

## *** FIRST HARDWARE BOOT SUCCESS (2026-07-22) ***
Booted on real RTL9607C via U-Boot (Phoebus#) ymodem loady 0x83000000 + bootm
(no Ethernet -> serial transfer; no flash writes). Reached busybox userspace shell:
  "RTL9607C  Linux 6.18.39  (rtl86900 SDK)" + `~ #` prompt.
- Timekeeping VERIFIED: luna_watchdog kthread prints tv_sec advancing 5/10/15s in
  realtime + "CPU0 kick watchdog!" => cevt-ext.c timer/clocksource rewrite works,
  HW watchdog being fed, scheduler alive.
- Cosmetic issues to fix next image:
  1. luna_watchdog.c debug spam (line 155 `if(debug) printk("CPUx kick watchdog")`,
     line 208 `printk("tv_sec:...")`) -> set debug=0 / gate line 208.
  2. "/bin/sh: can't access tty; job control turned off" -> add cttyhack to inittab.
- RAM-boot recipe (serial-only): U-Boot `setenv bootargs console=ttyS0,115200 loglevel=8;
  loady 0x83000000` + picocom `--send-cmd "sb -vv"` C-a C-s; then `bootm 0x83000000`.
- Pending analysis: capture full dmesg (SMP 2nd CPU?, switch/gmac/gpon init, errors).

## Boot log analysis + iteration 22 fixes (2026-07-22)
Full boot log: /home/wrldmk2_/OpenWRT1500/Phoebus bootm 0x83000000.txt
WORKS: 4 CPUs SMP (interAptiv MT, VPE {2,2}=4), 256MB RAM, L2 256k, GIC clocksource,
ttyS0 console handover, rtk GPIO (3 banks, SDK HAL), USB PHY revC detect (un-stubbed
switch_version_get working), squashfs, switch CORE dev init OK, FleetConntrack mgr
init (4 cpus), reaches busybox userspace.
ROOT CAUSE of peripheral IRQ failures: vendor code uses HARDCODED legacy Linux IRQ
numbers (APOLLO_IRQ=BSP_SWCORE_IRQ->38, USB platform-dev resources 40/74) that assumed
old MIPS GIC static virq numbering. 6.18 GIC allocates virqs dynamically -> request_irq
fails. DT-mapped IRQs (serial irq20, timer) work fine.
FAILURES seen:
 - rtk_switch_irq_init irq=38 FAIL (switch link-change IRQ)
 - intr_bcaster_init: register link change interrupt failed
 - rtk_fc_rtl9607c_API_init func_return=0xf -> "Register hwnat module failed" (WARNING,
   non-fatal; HW-NAT offload; may depend on switch IRQ)
 - ehci/ohci-platform request interrupt 40/74 failed (USB host; hardcoded IRQ resources)
Iteration 22 fixes (all Kconfig/flag-preserving; NO xPON/GPON code removed):
 1. irq.c rtk_switch_irq_init: resolve switch virq via of_find_compatible_node("rtk,switch")
    + irq_of_parse_and_map(), fallback APOLLO_IRQ. (+#include of.h/of_irq.h)
 2. luna_watchdog.c: debug_mask 1->0 (silences tv_sec/"kick watchdog" console spam).
 3. rootfs inittab: /bin/sh -> /bin/cttyhack /bin/sh (fixes "can't access tty; job control off").
Deferred to next: USB host IRQ (rework programmatic ehci/ohci-platform device IRQ
resources in arch/mips/rtl9607c/usb.c to DT/dynamic); HW-NAT func_return=0xf (recheck
after switch IRQ works); SDK gpio_dev/gpio2_dev IRQs (same hardcoded-virq pattern).

## Iteration 23 built OK (md5 1c542c0b743c3a0e86cf2ec2c3af0d32, 5896002 B)
- Gotcha: irq.c's <linux/interrupt.h> sits inside `#if defined(CONFIG_KERNEL_4_14_x)`
  (never defined here); first attempt put of.h/of_irq.h there too -> compiled out ->
  implicit-decl errors. Fixed by adding OF includes UNCONDITIONALLY before <bspchip.h>.
- Watch on next boot: watchdog spam gone; shell job-control ok; rtk_switch_irq_init
  irq= should not FAIL; intr_bcaster link-change registers; recheck HW-NAT func_return.
