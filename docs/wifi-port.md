# Wi-Fi port — RTL8832BR (5 GHz) + RTL8192F (2.4 GHz)

Two unrelated Realtek vendor drivers, both linked into one `vmlinux`:

| Driver | Chip | Band | PCIe | Interface |
|---|---|---|---|---|
| `g6_wifi_driver` (PHL/HALMAC) | RTL8832BR | 5 GHz, 802.11ax | port 0, `10ec:b832` | `wlan0` |
| `rtl8192cd` | RTL8192F | 2.4 GHz, 802.11n | port 1, `10ec:818c` | `wlan1` |

Both are AP-mode drivers driven by upstream **hostapd 2.11** over nl80211.

> **Radio reference:** use the **AX10v3_GPL** drop for anything radio-related on
> this board (RF tables, RFE type, efuse). The Cudy GP3000 drop is a different
> board and its radio data does not apply.

RF calibration tables are loaded from the rootfs at runtime, not compiled in:

```
/etc/conf/rtl8832bre/RFE50/{PHY_REG,PHY_REG_GAIN,RadioA,RadioB,TXPWR_*}.txt
/etc/conf/rtl8832bre/RFE50/PON_5G/...
```

Missing tables are **not fatal** — the PHY initialises blind and the radio comes
up weak and misbehaving. `Fail, ret:-2` in the log means the file was not found.

## Porting to 6.x cfg80211

The vendor drivers target ~4.4/5.10. The bulk of the work was the MLO
restructuring in modern `cfg80211_ops`: many callbacks gained `link_id` or
`radio_idx` parameters, and `struct cfg80211_ap_settings` grew `links[]`.

Rather than edit vendor function bodies, the port inserts thin adapter shims
immediately before the ops table and points the table at those:

- `g6_wifi_driver/os_dep/linux/ioctl_cfg80211.c` — 14 `ph_*` shims
- `rtl8192cd/8192cd_cfg80211.c` — 15 `rtk_shim_*` shims

```c
static int ph_get_antenna(struct wiphy *w, int radio_idx, u32 *tx_ant, u32 *rx_ant)
{ return cfg80211_rtw_get_antenna(w, tx_ant, rx_ant); }
```

### Never suppress incompatible-pointer-types

An early version of this port built with
`-Wno-error=incompatible-pointer-types` to get past the ops-table churn. That
compiles and then **panics at runtime**: `get_antenna` had gained a leading
`int radio_idx`, so the driver read `-1` as the `tx_ant` pointer. The warning was
the only thing standing between us and a null-deref on boot.

That flag is permanently out of this port. If the ops table does not compile
cleanly, write a shim.

## Vendor bugs found and fixed

These are bugs in the vendor code (or in the RTL8198D SDK snapshot we staged
from), not porting artifacts. All were hit on real hardware.

### 1. `mgmt_tx` rejects `chan == NULL` — no probe responses

`cfg80211_rtw_mgmt_tx()` bailed with `-EINVAL` whenever `params->chan` was NULL.
But cfg80211 passes NULL to mean *"transmit on the current operating channel"*,
which is exactly what hostapd does for probe/auth/assoc responses on the
operating channel.

Result: **every** management frame hostapd tried to send failed with `-22`.
Clients saw beacons and nothing else — the AP appeared in scans (often rendered
as "WEP", because the client had only a beacon and no probe response) and no
client could ever associate.

Fix: fall back to `pmlmeext->cur_channel` when `chan` is NULL, which is what
`rtl8192cd` and mac80211 both already do.

Symptom in the log:
```
nl80211: Frame command failed: ret=-22 (Invalid argument) (freq=0 wait=0)
handle_probe_req: send failed
```
Confirmation the fix is live — this line appears only when `mgmt_tx` runs:
```
RTW: cfg80211_rtw_mgmt_tx(wlan0) TX MGNT @5180MHz CH36 216B W0 A1
```

### 2. `CONFIG_BR_EXT` runs client-mode MAC rewriting on the AP datapath

`CONFIG_BR_EXT = y` is hardcoded in `g6_wifi_driver/Makefile` (not a Kconfig
option). It enables Realtek's NAT-2.5 "bridge extension" — MAC translation for
when the chip is a **station** bridging downstream devices.

Three things make it harmful here:

1. It arms itself in `netdev_br_init()` as soon as a bridge whose name matches
   `CONFIG_BR_EXT_BRNAME` (`"br0"`) exists.
2. `rtw_br_client_tx()` then rewrites the **source MAC** of forwarded frames —
   and the `if (MLME_IS_STA(adapter))` guard that should confine it to station
   mode **is commented out upstream**, so it runs in AP mode too.
3. It can drop frames outright: `TX DROP: nat25_db_handle fail!`

It also expects `net/bridge/` support that neither this tree nor the vendor 5.10
tree actually carries.

This matches the observed history exactly: Wi-Fi data worked when the AP had a
direct IP on `wlan0` and no `br0` existed (log said
`netdev_br_init(wlan0) can't get bridge dev by name "br0"`), and broke as soon as
a bridge named `br0` was introduced.

**Fix: disarm by name, do not set `CONFIG_BR_EXT = n`.**

```make
BR_NAME = rtw-brext-off      # was br0
```

`=n` does not compile: ~64 uses of `br_mac` / `scdb_entry` / `br_ext_lock` sit
outside any `#ifdef CONFIG_BR_EXT`, so that configuration has evidently never
been built upstream. Pointing the lookup at a name no bridge will ever have
leaves `br_port` NULL, and `rtw_br_client_tx()` short-circuits on its
`br_port &&` test. One line, no compile risk.

Confirmation the fix is live:
```
RTW: netdev_br_init(wlan0) can't get bridge dev by name "rtw-brext-off"
```

### 3. Beacon IEs never reached mlmeext

There are **two** beacon buffers, and only one of them goes on air:

- `pmlmepriv->cur_network.network` — filled by `rtw_check_beacon_data()` from
  hostapd's head/tail
- `pmlmeinfo->network` — what `issue_beacon()` actually transmits from

The only copy between them sat inside `#ifdef CONFIG_RTW_SUPPORT_MBSSID_VAP`.
That symbol is undefined here: the Makefile says `= n`, and the platform preconf
headers that define it are themselves gated behind
`CONFIG_RTW_HAS_PLATFORM_PRE_CONFIG`, which is never set either. So mlmeext
beaconed whatever stale content its buffer happened to hold.

On air that looked like SSID and Supported Rates correct — those are set
field-by-field in `start_bss_network()` — followed by garbage.

Fix: make the copy unconditional, at the end of `rtw_check_beacon_data()`.

### 4. `update_BCNTIM()` assumed a DS Parameter Set IE — the "WEP" bug

`update_BCNTIM()` computes the TIM insertion point by measuring what precedes
it. It looks up SSID and Supported Rates properly, then added a hardcoded
`offset += 3` for a DS Parameter Set IE. DS Param is a DSSS/2.4 GHz element —
**hostapd omits it on 5 GHz**. So the TIM was written three bytes late, landing
inside the *payload* of the following element:

```
correct:  … 60 6c | 07 10 55 53 20 24 04 17 …            Country IE intact
broken:   … 60 6c | 07 10 55 [05 04 00 02 00 00] 53 20 24 04 17 …
                              └─ TIM, one byte into Country's payload
```

Every element boundary after that is wrong, so `30 1e` (the RSN IE) is never
recognised as an element header. The RSN bytes were on air the whole time —
just unparseable.

Everything below follows from that single misplacement:

- clients saw Privacy set with no RSN IE, i.e. **WEP**. wpa_supplicant refuses
  WEP outright; KDE/NetworkManager demand a WEP key.
- a STA that did associate dropped **immediately after
  `EAPOL-4WAY-HS-COMPLETED`**. The 4-way uses the RSN IE from the *association*
  exchange (correct), then wpa_supplicant validates the *beacon* (garbage),
  finds a security mismatch, and leaves.
- identical behaviour on WPA2 and WPA3, because the beacon was broken either way.

Fix: look the DS Param IE up like the other two, and only add its length when it
is actually present.

### 5. `__DATE__` / `__TIME__` vs `-Werror=date-time`

`g6_wifi_driver/core/rtw_debug.c` stamped the build time into a banner. The
kernel builds with `-Werror=date-time` for reproducibility. This was latent —
the object was cached — and only surfaced when a failed build invalidated
`autoconf.h` and forced a full driver recompile. Replaced with a static string.

### 6. Unrelated code depending on `br_ext`-only macros

`MACADDRLEN` is defined only by `rtw_br_ext.h`, yet `struct atm_stainfo`
(`drv_types.h`) and an AP DHCP path in `xmit_linux.c` both use it. Switched to
the canonical `MAC_ADDR_LEN` (both are 6).

### 7. `LED_ON` / `LED_OFF` collide with the kernel — and are inverted

The kernel's `enum led_brightness` has `LED_OFF = 0, LED_ON = 1`. `rtl8192cd`
defines them **the other way round**. A plain `#undef` would have silently
inverted every LED on the board. Renamed the driver's to `RTL_LED_*`.

### 8. Duplicate symbols between the two drivers

Both trees are vendor forks carrying copies of the same shared Realtek code
(`halrf_*`, sha256, cfg80211 helpers) — ~50 duplicate symbols when linked
together. Resolved by namespacing `rtl8192cd`'s copies via
`-D<sym>=rtl8192cd_<sym>` in its Makefile.

### 9. 2.4 GHz was configured for the wrong crystal — the radio tuned nowhere

The 8192F came up looking perfect and heard nothing. Beacons transmitted
(`beacon_ok` climbing), every register read back correct, the RF die's thermal
sensor reported ~36, the baseband ran — and `rx_packets`, `rx_mgnt_pkts` and
hostapd's `olbc` sat at exactly zero across every configuration. The SSID was
never visible to any client, so it was not receiving *or* transmitting.

The cause is one Kconfig default:

```
config PHY_EAT_40MHZ
	bool "HOST Clock Source, Select is 40MHz, otherwise 25MHz"
	default y
```

It feeds `ClkSel` into `InitPONHandler()` — the RF power-on and PLL setup — in
`rtl8192cd_init_hw_PCI()`. The AX10v3 vendor config sets
`# CPTCFG_PHY_EAT_40MHZ is not set`; we inherited the `default y` and told the
radio it had a 40 MHz crystal when the board has 25 MHz. A 1.6x error in the
PLL reference puts the synthesiser nowhere near 2.437 GHz, which is why nothing
was heard in either direction while every register looked right.

`# CONFIG_PHY_EAT_40MHZ is not set` in `configs/rtl9607c.config`. Confirm with
`clock 25MHz` in dmesg at wlan1 open — the stock firmware prints the same line.

### 10. RFE type 23 exists on this board and not in the 8198D SDK snapshot

`CPTCFG_SLOT_1_RFE_TYPE_23=y` in the AX10v3 product config. Our rtl8192cd came
from the RTL8198D SDK, whose tables and code stop at type 22:

| | rfe_type branches |
|---|---|
| 8198D SDK (ours, before) | ... 20 21 22 |
| AX10v3 GPL (vendor) | ... 20 21 22 **23** |

Missing in three places, all ported from the vendor driver:

- `phydm/rtl8192f/phydm_hal_api8192f.c` — `phydm_init_hw_info_by_rfe_type_8192f()`
  had no branch for 23 and **no default**, so the external front end was never
  configured. Verified by register readback: `BB_0x944` `0x3f3f0000` -> `0x3f3f081c`
  and `BB_0x940` `0x000007ff` -> `0x00400100`.
- `phydm/rtl8192f/halhwimg8192f_bb.c` and `phydm/halrf/rtl8192f/halhwimg8192f_rf.c` —
  the in-table `0x91000017` conditionals (0x17 = 23) were absent, so the AGC gain
  map and RadioA/B init had no type-23 block. Vendor phydm is v67 (2022-09-15);
  the 8198D snapshot is v64 (2021-10-15). Both files are strict supersets, so they
  drop in whole.
- `phydm/halrf/rtl8192f/halrf_dpk_8192f.c` — 23 was missing from the DPK gate, so
  pre-distortion calibration bailed out entirely.

Set `rfe2g=23` on the kernel cmdline (see the `rfe2g=` override in
`8192cd_osdep.c`); the Kconfig only offers 3/12/16/17/18 for slots, so 23 cannot
be expressed there.

### 11. `is_WRT_scan_iface()` sits outside its `#ifdef` in the 8198D snapshot

In `is_iface_ready_nl80211()` the vendor has this check inside the
`CONFIG_OPENWRT_SDK` block; our copy has the `#endif` five lines earlier, so it
runs unconditionally. Harmless in practice — `is_WRT_scan_iface()` only matches
`tmp.phy0`/`tmp.phy1` and returns 0 otherwise — but it shows the SDK snapshot
carries hand-edits that diverge structurally from the vendor tree. Worth
checking the surrounding preprocessor when anything in that path misbehaves.

### 12. The driver's default beacon interval is 400 TU

hostapd never sets `beacon_int`, so the driver's own default applies: 400 TU
(~410 ms). With `dtim_period 2` that is ~820 ms between DTIM beacons, and a
client in power save only wakes for DTIM. Measured 15% ICMP loss and 8 ms
latency spikes from a laptop at -34 dBm negotiating MCS15 — which reads as a bad
radio and is not. `beacon_int=100` is set explicitly in `hostapd-2g.conf`.

## hostapd

Built from `sdk/ap/` — hostapd 2.11, `CONFIG_DRIVER_NL80211`, `CONFIG_LIBNL32`,
OpenSSL backend, `CONFIG_SAE=y`, WPS deliberately omitted.

**Upstream hostapd Makefile bug:** the `CONFIG_SAE` block sets
`NEED_HMAC_SHA384_KDF` but not `NEED_SHA384`. With `CONFIG_TLS=openssl` that
means `sha384-kdf.o` is compiled while `crypto_openssl.c` is built *without*
`-DCONFIG_SHA384`, so `hmac_sha384_vector` is undefined at link. Add
`NEED_SHA384=y` to that block **and `make clean`** — make keys on source mtime,
so a CFLAGS change alone will not rebuild the object.

WPA3 needs OpenSSL: the internal libtommath backend cannot do the SAE ECP groups
(19/20, NIST P-256/P-384) that phones negotiate.

## Current status

**5 GHz works end to end**, validated on hardware: firmware download, RF table
load, beaconing with a correct RSN IE, probe responses, Open/WPA2/WPA3-SAE
authentication, association, 4-way handshake, and a DHCP lease.

```
wlan0: STA … WPA: pairwise key handshake completed (RSN)
wlan0: EAPOL-4WAY-HS-COMPLETED …
udhcpd: sending OFFER to 192.168.1.100
udhcpd: sending ACK   to 192.168.1.100
```

All four bugs above had to be fixed before any of it worked, and each masked the
next — which is why they were only findable in order:

1. no probe responses → clients had beacons only
2. no data path → associate, then nothing
3. stale beacon buffer → wrong bytes on air
4. TIM misplacement → no parseable RSN IE → "WEP", drop after the 4-way

**2.4 GHz (`wlan1`) works**, validated on hardware after fixes #9-#12: a laptop
associates to `Phoebus2.4` at -34 dBm and negotiates MCS 15 (2x2, 144 Mbit/s),
gets a DHCP lease, and SSH reaches authentication in ~100 ms on 6/6 attempts.

```
rx_packets:    728
rx_mgnt_pkts:  18216
beacon_ok:     713
```

The blocker was #9 (wrong crystal). #10-#12 are real defects found on the way and
worth keeping, but none of them alone brought the radio up.

Not related to Wi-Fi, but visible in the same logs: the WAN DHCP client keeps
broadcasting on `nas0`, so clients get a LAN address and no internet. The uplink
on this board is `eth0.9` — set `wan=eth0.9` on the kernel cmdline.

## Debugging recipes

**Run hostapd by hand with full debug** — the single most useful tool here.
Driver-level `RTW:` messages tell you what the driver did; only `hostapd -dd`
tells you what hostapd *asked for* and the errno it got back:

```sh
s6-rc -l /run/s6-rc/live -d change hostapd
hostapd -dd /etc/hostapd.conf 2>&1 | tee /tmp/hap.log
grep -nE "send_mlme|send_frame_cmd|Failed|EAPOL|assoc|deauth" /tmp/hap.log
```

**Verify the driver is actually linked in.** A successful link and "0 undefined
references" prove nothing if the code was never compiled in:

```sh
md5sum vmlinux                                   # must CHANGE between builds
mips-...-nm vmlinux | grep -c rtl8192cd_         # symbols present
mips-...-ar t drivers/.../built-in.a | grep -c   # objects in the archive
```

**The initramfs is gzip-compressed inside the kernel**, so `strings vmlinux`
will not show rootfs files. Extract the cpio instead:

```sh
mkdir /tmp/x && cd /tmp/x && cpio -idm < linux-6.18.x/usr/initramfs_data.cpio
```

**Watch out for `olddefconfig`** re-enabling vendor options you turned off —
`CONFIG_SLOT_1_92D` (an 8192D we do not have) and `CONFIG_RTL8190_PRIV_SKB`
(needs a Realtek `sk_buff` core patch) both come back and break the build.
Re-check after every `olddefconfig`.
