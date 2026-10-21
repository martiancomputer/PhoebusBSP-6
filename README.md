# PhoebusBSP-6

Linux **6.18 LTS** board support for Realtek Phoebus (RTL9607C / RTL9607Cv2 —
big-endian MIPS32r2 interAptiv, MIPS_CPS + MT SMP / 4 VPEs, GIC).

Built on the shared [Phoebus-SDK](https://github.com/martiancomputer/Phoebus-SDK)
(vendor SoC code + toolchain fetch + image tools + rootfs), wired in as the
`sdk/` submodule. The mainline/bleeding-edge line lives in
[PhoebusBSP-7](https://github.com/martiancomputer/PhoebusBSP-7).

## What's here (the *port*, not the kernel)

```
build.sh        one-shot: fetch kernel + toolchain, graft vendor, overlay port, build, package
configs/
  rtl9607c.config   working kernel .config (RTK_SOC_RTL9607C=y, CPS+MT SMP, GIC, 8250,
                    squashfs, initramfs, netfilter legacy backend for NAT)
overlay/        exact ported sources for the files we changed vs upstream 6.18.39
                (arch/mips platform + Kconfig/Makefile wiring, the rtl86900 SDK 6.18
                 API edits, header deltas, scripts/Makefile.lib). build.sh copies this
                over the pristine+vendor tree — reliable against the SDK's CRLF files.
docs/
  port-vs-upstream-6.18.39.diff   changelog of every edit vs pristine 6.18.39
  wifi-port.md                    the Wi-Fi port + the vendor driver bugs found
sdk/            Phoebus-SDK submodule
```

Nothing here duplicates upstream or the vendor SDK: `build.sh` reconstructs a full
buildable tree from three pinned ingredients (pristine kernel + `sdk/` vendor code +
`overlay/`).

## Build

Host prerequisites (build.sh preflights these):
- Arch/Artix: `sudo pacman -S base-devel bc uboot-tools xz`
- Debian/Ubuntu: `sudo apt install build-essential bc u-boot-tools xz-utils flex bison`

`mkimage` (uboot-tools) wraps the uImage; `bc` is needed by the kernel's
`timeconst.h` rule; the cross toolchain is fetched automatically.

The shared SDK also cross-builds btop for MIPS32r2, replacing BusyBox `top`.
Its CPU panel discovers all four logical VPEs; its network panel can select
each LAN/WAN netdev, including bridge members without individual IP addresses.
See the SDK's resource-monitor section for UTF-8 setup, runtime libraries and
hardware-offload counter limitations. Host GNU `localedef` is required.

The BSP also builds pinned hostapd, Dropbear, dnsmasq, OpenSSL, libnl and
dual-stack legacy iptables through `tools/build-userspace.sh`. Set `VENDOR_SDK`
to an unpacked vendor source tree containing `user/wireless_tools`, or place
that tree under `build/userspace/vendor-cache`. `SKIP_USERSPACE=1` is only for
kernel iteration, not a complete router image.

### Diagnostics and shared fixes

The shared SDK provides serialized firewall transactions, first-boot-safe
SSH rules restricted to connected LAN prefixes, login PATH defaults, the
16,384-entry Linux conntrack policy, and WPA3 RSN-IE preservation. BSP-6 keeps
the 6.18 callback signatures; it does not use the 7.3 cfg80211 ABI.

The default LAN is `10.1.0.0/24`, gateway `10.1.0.1`, DHCP `.100` through `.171`.
Collector addresses and credentials are private provisioning, not public defaults.
The optional `logging` s6-rc bundle relays kernel records and system/health logs
to the rotating collector in `tools/phoebus-log-receiver.py`. Configure
`/etc/phoebus-telemetry.conf`, restart `syslogd`, then enable it with:

```sh
s6-svc -r /run/service/syslogd
s6-rc -l /run/s6-rc/live -u change logging
```

Logs may contain sensitive data and must remain private. UDP logging is for a
trusted wired LAN and cannot guarantee the final record during a complete hang.
Netconsole stays opt-in until the vendor NIC netpoll path is validated.

The read-only SoC hwmon bridge uses a real parent device and the initialized
SDK thermal getter. btop is configured to show one package sensor rather than
inventing per-VPE readings. Actual sensor values require hardware validation.

> **`bc` really is required.** The kernel regenerates
> `include/generated/timeconst.h` on *every* build via a `filechk` rule with a
> `FORCE` prerequisite, so a cached header does not save you. Without `bc` the
> build dies early at `prepare0` with `Error 127`.

```sh
git clone --recurse-submodules https://github.com/martiancomputer/PhoebusBSP-6
cd PhoebusBSP-6
git submodule update --init          # pulls Phoebus-SDK
./build.sh                            # -> images/uImage  (load 0x80001000)
```

## Boot / test on hardware (no flash writes)

U-Boot is `Phoebus#`, NAND+UBI. RAM-boot the image over serial (no Ethernet needed):

```
U-Boot> setenv bootargs console=ttyS0,115200 loglevel=8 ethaddr=<your-mac>
U-Boot> loady 0x83000000        # send images/uImage via ymodem (picocom: sb)
U-Boot> bootm 0x83000000
```

Useful cmdline arguments beyond the above:

| Arg | Effect |
|---|---|
| `ethaddr=aa:bb:...` | real MAC, applied to the wired ports and bridge |
| `wan=<if>` | choose the WAN port (default `nas0`) |
| `lan=<if>[,<if>]` | choose bridge members (default `eth0.2`–`eth0.7`) |
| `phoebus_verbose` | keep the full kernel log on the console |

### Verify you are booting what you think you are

A ymodem cycle is ~15 minutes, so confirm before you spend one. U-Boot prints
`Data Size:` — check it against the file you sent:

```sh
md5sum images/uImage arch/mips/boot/uImage.lzma
```

Stale build artifacts are the single most expensive mistake here; two flash
cycles were lost to a leftover `images/uImage-initramfs` that was never
regenerated by `mk_images.sh`.

## Status

**Working on real hardware:**
- 4-CPU SMP, 256 MB RAM, GIC timer/clocksource, ttyS0 console, GPIO, watchdog
- Realtek switch core + FleetConntrack init; both PCIe ports link up
- s6 userspace (see the SDK's `docs/userspace.md`), SSH, DHCP server, WAN DHCP
  client, NAT + stateful firewall
- Both Wi-Fi drivers load, firmware + RF tables download, both radios beacon
- Client **association** completes on 5 GHz — open, WPA2-PSK and WPA3-SAE

The older notes in [`docs/wifi-port.md`](docs/wifi-port.md) describe historical
bring-up failures, not proof that current fixes were tested on every LTS build.
The mainline BSP has since completed WPA3 connections on both bands. Those
shared fixes and the LTS-specific Wi-Fi adaptations are carried here, but a
successful cross-build does not replace fresh BSP-6 board validation.

xPON/GPON/EPON retained and Kconfig-selectable. USB compiled in but gated off
(no port on this board).

Internal bring-up notes and raw boot captures remain local and untracked.
