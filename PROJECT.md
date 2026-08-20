# Phoebus-OS — Linux 6.18 on the RTL9607C

A from-scratch board support package running **Linux 6.18.39** on a **TP-Link
Archer AX10 v3 / AX1500**, a router whose SoC (Realtek RTL9607C) has never been
supported by any mainline or OpenWrt tree.

**This is not OpenWrt.** It shares no code, no build system and no package
format with it. OpenWrt's `realtek` target covers the RTL838x/839x/930x *switch*
SoCs; the 9607C is a GPON/router part and is absent from it. The name only comes
up here because "is this OpenWrt?" is the first question everyone asks.

It is also **not a product**. It boots from RAM over TFTP, nothing has ever been
written to the router's flash, and it is reflashed several times an hour. Design
decisions throughout favour "tells you when it is broken" over "survives
unattended."

---

## 1. Hardware

| | |
|---|---|
| SoC | Realtek RTL9607C, MIPS32r2 interAptiv, 4 cores, big-endian |
| RAM | 256 MB DDR |
| Flash | ESMT **F50L1G41LB** SPI-NAND, 1 Gbit (128 MB), on-die ECC |
| Switch | Integrated, 11 ports (0-10); 4 usable GPHYs |
| WAN PHY | External RTL8211F/FS on a bit-banged MDIO bus |
| 5 GHz | RTL8832BR, driver `rtk_wifi6` (vendor "g6" driver) |
| 2.4 GHz | driver `rtl8192cd`, 802.11n only |
| Console | 115200 8N1 |

The two radios are **different drivers with different capabilities and different
bugs**. Nothing learned about one transfers to the other; assuming otherwise has
cost this project real time. Check with
`readlink /sys/class/net/wlanN/device/driver`.

### Port map (measured, not from the vendor table — which is wrong here)

```
LAN 1 -> eth0.2 -> Port0        LAN 3 -> eth0.4 -> Port2
LAN 2 -> eth0.3 -> Port1        LAN 4 -> eth0.5 -> Port3
WAN   -> eth0.8 -> Port6        (SGMII0 / SDS0)
```

### NAND layout

Confirmed two independent ways — the U-Boot `mtdparts` string and the `fl_*_bs`
offset variables agree, and the eight sizes total exactly 128 MB.

```
0  boot          0x0000000  1 MB      4  userconfig    0x6800000  8 MB
1  env           0x0100000  1 MB      5  tp_data       0x7000000  8 MB
2  ubi_device    0x0200000  51 MB     6  paniclog      0x7800000  4 MB
3  ubi_device_1  0x3500000  51 MB     7  defaults      0x7C00000  4 MB
```

`ubi_device` and `ubi_device_1` are A/B firmware images (different builds, not
copies). `tp_data` and `userconfig` are UBI volumes whose contents are opaque —
entropy 8.00, no UBIFS superblock. `paniclog` and `defaults` are empty; stock
has never panicked on this unit.

---

## 2. Architecture

```
U-Boot (stock, untouched)
  └── TFTP → RAM → uImage.lzma
        └── Linux 6.18.39 + initramfs
              └── /init  (s6 stage-1)
                    └── s6-rc → ok-all bundle
```

Userspace is **s6**, not procd/busybox-init. Services in the `ok-all` bundle:

```
network  syslogd  klogd  s6-hpd  hostapd  hostapd-2g  udhcpd
wan  nat  dropbear  dnsmasq  cake  wifi-tune  wifi-acs
```

`s6-hpd` is a purpose-written hotplug daemon filling the udev/procd role s6
lacks. `network`, `nat`, `cake` and `wifi-tune` are oneshots; `wifi-acs` is a
longrun.

### Repositories

| repo | contents |
|---|---|
| **PhoebusBSP-6** (this) | kernel config, `overlay/` (113 modified kernel sources), build script |
| **Phoebus-SDK** (submodule at `sdk/`) | rootfs, s6 service tree, s6-hpd, tooling |

`overlay/` mirrors paths under `linux-6.18.x/`. Keep it in sync with the working
tree or a clean clone builds something different from what you tested.

---

## 3. What works

- Boots 6.18.39, all 4 cores, 256 MB
- **4 LAN ports** at gigabit
- **WAN** — DHCP lease, NAT, routing. Measured **93/94 Mbps at 2 ms** on a
  100 Mbit line (stock managed 300–400 ms under load)
- **Both radios up**, WPA3-SAE + WPA2 transition mode, PMF
- **802.11ax on 5 GHz** — 80 MHz, 2 streams, negotiates 1201 Mbit
- DHCP server, DNS (dnsmasq), stateful firewall (iptables), SSH (dropbear)
- **CAKE** on the WAN, both directions, 92 Mbit — the reason the project started
- Automatic channel selection with idle guards
- Read-only NAND dump + full extraction tooling

## 4. What does not

| | |
|---|---|
| **5 GHz downstream** | retry bursts of 100+, rate control thrashing 961→551→864. Upstream is flawless at MCS11/1201, 0 retries. **Open.** |
| **Flow accelerator** | offloaded flows die ~3 s in (`DEV_STACK_MAX[4]` overflow). Forwarding is software-only, ~350 Mbps router-terminated. |
| **Flash install** | no MTD driver for this SoC's SPI controller. RAM boot only. |
| **Reproducibility** | hostapd/dnsmasq/dropbear/iperf3/tcpdump/tc/iwpriv build from trees outside the repos. The build *reports* what is missing; it does not fetch it. |

---

## 5. Findings worth knowing

Things that cost days and are not written down anywhere else.

### The WAN SerDes is never configured

`rtk_port_serdesMode_set` and `rtk_port_serdesNWay_set` are public, wired into
the 9607c mapper, and **called by nothing** in the entire tree. Without them the
WAN looks perfect and passes zero frames: copper links, autoneg completes, MAC
speed matches, `in_octets` stays exactly 0.

The tell is the PHY's own SerDes-side status, page `0xdc0` register `0x11`:

```
0x6189   link down, autoneg never completing   (for days, under every condition)
0x61ad   link up, autoneg complete             (after configuring SDS0)
```

Port 6 `in_octets` went 0 → 741158 the moment SDS0 came up. Gated behind
kernel cmdline **`sds=0`**.

**Use SDS0, never SDS1.** SDS1 is port 7 and shares a lane with PCIe port 1
(`SGMII_SEL_PCIE`); enabling it kills the 5 GHz card.

**Never call `serdesMode_set` on a live system.** It stops the GLI clock and
every error path returns early *without restoring it* — the CPU wedges, the
watchdog fires, and the board falls back to stock in NAND. This happened.

### Three different sixes

`WAN_PHY_PORT_SET="1:6"`, `CONFIG_MDC_MDIO_EXT_PORT=6` and
`diag debug ext-mdio c22 init 0 0 6` are all a **PHY address**. The switch port
also being 6 is a coincidence. Conflating them cost several nights.

### `CONFIG_SWITCH_INIT_LINKDOWN` must be off

It powers every GPHY down at init and expects a vendor userspace daemon to
power them back up. Symptom chain: PHYs never link → no link-change interrupt →
status stays 0xFF → carrier never set → bridge excludes every port. One config
line, five symptoms.

### The skb recycle pool cannot work on mainline

`re_recycleskb.c` sizes a pool of 8000 skbs and has a working enqueue path, but
**nothing ever returns a buffer to it** — Realtek patches the skb free path to
do that and 6.18 has no such hook. Both settings of
`skb_dynamic_allocate_disable` are then wrong in opposite directions:

- `GMAC_ON`: empty pool, no buffers, 22688/26264 frames dropped with 116 MB free
- `GMAC_OFF`: allocation never fails, so `rx_pause_by_software` never fires,
  queues grow unbounded → OOM kill → panic

Pool exhaustion *was* the flow control. `CONFIG_RTL_ETH_RECYCLED_SKB` is now off.

### BMSR link status is latch-low

Read register 1 **twice**. The first read reports 0 if the link dropped at any
point since the last read. A single read reported `link=down` on a live link and
sent a whole session chasing faults that were not there.

### External PHY access

`001c:c916` (an F and an FS report the same ID; the chips are under soldered RF
cans). ext-MDIO **MDC=65, MDIO=10**, answers at address 0 and 6. The bus does
not exist until GPIOs are released — and releasing 65/10 alone is not enough;
the whole set must go **except 39 and 40, the WiFi PCIe resets, which reset the
board if freed**.

### Channel 36 was a bad default

A scan found six BSSes inside the 36/40/44/48 block including the two loudest
APs in the neighbourhood. Moving to 149 cut AP→client latency from 39 ms avg /
340 ms max to 13 ms / 46 ms. Stock picks 149 too. `wifi-acs` now re-evaluates
every 30 minutes.

### iwpriv is the only way to configure these radios

nl80211 does not touch the Realtek private MIB. Stock's `rtk_wlan.sh` makes
**54 `iwpriv` calls** at bring-up; this project made zero until recently,
because `WT_SRC` was never set and the wireless_tools block silently did nothing
on every build.

---

## 6. Building

```sh
./scripts/fetch-toolchain.sh          # Bootlin MIPS32 BE, glibc, GCC 14
export PATH=$PWD/toolchain/mips32--glibc--stable-2025.08-1/bin:$PATH
sdk/rootfs/build-rootfs.sh            # busybox + s6 + services + secrets
make -j$(nproc) ARCH=mips CROSS_COMPILE=mips-buildroot-linux-gnu- uImage.lzma
```

The rootfs build ends with a manifest of third-party binaries and says which are
missing. **Read it.** Each absence fails as something else: no udhcpc script
reads as a dead WAN, no hostapd as a broken radio, no dnsmasq as no internet.

A `hostbin/bc` shim is required on `PATH` for kernel builds.

### Credentials

Never committed. `secrets/phoebus.env` is gitignored and supplies the Wi-Fi
passphrase, password hashes and SSH keys at build time; the tracked tree ships
locked accounts and a public dummy passphrase. Both repos are public.

---

## 7. Flashing

TFTP boot into RAM. Nothing is written to flash.

```
setenv serverip 192.168.7.2
setenv ipaddr 192.168.7.10
setenv bootargs 'console=ttyS0,115200 loglevel=8 ethaddr=98:BA:5F:96:1A:80 \
  rfe2g=23 wan=eth0.8 sds=0 wanmac=<PC-MAC>'
tftpboot 0x83000000 uImage-initramfs
bootm 0x83000000
```

| bootarg | effect |
|---|---|
| `sds=0` | configure SDS0. **Without this the WAN is dead.** `sds=1` breaks WiFi. |
| `wan=eth0.8` | WAN netdev (switch port 6) |
| `wanmac=` | clone a MAC on the WAN only — ISPs bind sessions to it |
| `ethaddr=` | sticker MAC; radios derive BSSIDs +1/+2 |
| `hwnat=N` | flow accelerator. Leave at the default 4. |

**Gotchas:** disconnect any VPN first — CloudflareWARP drops the board's TFTP
request via nftables, ProtonVPN captures the route. `ip route get <board-ip>`
must name a LAN interface. The AX88179 USB NIC needs USB configuration 1.

---

## 8. Debugging

`/proc/phy_recovery/extmdio` accepts: `up <mdc> <mdio> <addr>`, `force <port>`,
`mib <port>`, `diag`, `rd <page> <reg>`, `wr`, `sds <num> <mode>`,
`nway <num> <cfg>`, `phydump`, `gpiostate`, `sweep`, `miim`.

Radio state lives under `/proc/net/rtk_wifi6/wlan0/` — `all_sta_info` is the
most useful. **Its first block is the AP's own self-entry, not a client.**
Reading it as a client produced two wrong conclusions here.

NAND dumps: `sdk/tools/nand-dump.sh` (read-only) then
`sdk/tools/nand-extract.sh` — carves all eight partitions, parses UBI, unpacks
squashfs including volumes nested inside UBI.

### House rules, learned the hard way

- **Verify by artefact.** Check `vmlinux` symbols and strings, not exit codes.
  Every silent failure in this project passed its build.
- **Make "nothing found" prove it could have found something.** Include a
  control that must produce output.
- **Cumulative counters lie.** Sample deltas during load. Totals conflated with
  snapshots produced three wrong conclusions in one evening.
- **One variable per image.** Two WiFi changes shipped together once and the
  regression could not be attributed to either.

---

## 9. Open threads

1. **5 GHz downstream** — the live defect. Retry bursts and rate-control
   thrashing on transmit only, on a clean channel, with upstream perfect.
2. **Flow accelerator** — `DEV_STACK_MAX` is `(4)` in `rtk_fc_skb.h` and
   `fcIngressData` is a field the vendor added to `struct sk_buff`, so enlarging
   it grows every skb. Several call sites hardcode `[4]`.
3. **Flash install** — needs a `spi-mem` driver for the 9607C. `esmt.c` already
   has explicit F50L1G41LB support; `spi-realtek-rtl-snand.c` is for the
   *switch* family, not this SoC. **Gated** until WiFi is stable and LAN hits
   800 Mbps.
4. **`tp_data` / `userconfig`** — encrypted; `default-mac` and `radio` sub-
   partitions likely inside.
5. **Reproducibility** — vendor userspace still builds from outside the repos.
