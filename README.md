# FR24 Feeder Monitor

A self-recovering health monitor for [Flightradar24](https://www.flightradar24.com/) feeder stations running `fr24feed` on a Raspberry Pi with an RTL-SDR dongle.

It runs from cron, watches the receiver, and applies the **least-disruptive recovery action** that fixes the problem — restarting the service, re-authorizing the USB dongle, or as a last resort rebooting the Pi.

---

## Why

`fr24feed` can fail silently in several ways: a wedged libusb transfer, a kernel module that grabs the dongle out from under it, a transient USB hiccup, or just no aircraft in range during a quiet period. The default behaviour is to do nothing — the station goes dark and nobody notices for hours. Some setups paper over this with a "reboot if down" cron, which is heavy-handed and burns SD-card writes for problems a service restart would have fixed.

This script is a graduated recovery ladder.

| Level | Action                                | Triggered after                                |
|-------|---------------------------------------|------------------------------------------------|
| 0     | (no action)                           | receiver healthy                               |
| 1     | `systemctl restart fr24feed`          | 2 consecutive `Receiver: down` ticks (debounce)|
| 2     | USB re-authorize the RTL-SDR dongle   | one tick later, still down                     |
| 3     | `shutdown -r now`                     | one tick later, still down                     |

State persists across cron invocations in `/var/lib/fr24-monitor/state`. A real failure walks the whole ladder in ~15 minutes; a momentary blip never escalates past level 0.

### What counts as "down"

Only `Receiver: down` from `fr24feed-status`. A receiver that's connected but reporting zero messages this minute is **not** a failure — that's the normal state during quiet-traffic windows (pre-dawn, low-traffic airspace) and any monitor that treats it as a fault will pointlessly restart `fr24feed` at 5 a.m. every day. Real wedges (DVB module conflict, dongle freeze, dump1090 stuck on a USB read) eventually surface as `Receiver: down` because `fr24feed`'s own internal reader watchdog gives up after enough timeout cycles, so we still catch them — we just don't act on the noisy intermediate signal.

## What this isn't

- A monitoring system. There are no metrics, no alerts, no dashboards — just self-healing.
- A replacement for FR24's status page.
- Suitable for non-RTL-SDR receivers without modification (level 2 targets Realtek vendor `0bda`).

---

## Installation

```sh
git clone https://github.com/<you>/FR24-Feed-monitor.git
cd FR24-Feed-monitor

sudo install -m 0755 -o root -g root monitor_fr24feed.sh /usr/local/bin/
mkdir -p /home/pi/logs

# Add to the pi user's crontab (5-minute cadence)
( crontab -l 2>/dev/null; echo '*/5 * * * * /usr/local/bin/monitor_fr24feed.sh' ) | crontab -
```

**Requires:**
- Raspberry Pi OS (Debian-based) with `fr24feed` installed
- The `fr24feed-status` command working
- The `pi` user with passwordless sudo (default on Pi OS)

## Configuration

Edit the constants at the top of the script:

```sh
MIN_UPTIME_MIN=15            # don't act for the first N minutes after boot
ESCALATE_AFTER_SEC=240       # min seconds between escalation steps
CONSECUTIVE_FAILS_THRESHOLD=2 # consecutive unhealthy ticks before action
RTL_VENDOR_ID="0bda"         # USB vendor ID — Realtek by default
```

## Operation

Logs go to `/home/pi/logs/fr24feed_monitor.log`, rotated at 10 MB.

```sh
tail -f /home/pi/logs/fr24feed_monitor.log
```

State (current escalation level, last-action timestamp, consecutive failure counter) is in `/var/lib/fr24-monitor/state`. To force-reset the ladder:

```sh
sudo rm /var/lib/fr24-monitor/state
```

Typical log entries during normal operation:

```
[2026-05-03 09:45:01] status: ... Receiver: connected (3056 MSGS/0 SYNC).
[2026-05-03 09:50:01] unhealthy 1/2 consecutive — waiting for confirmation before acting
[2026-05-03 09:55:01] transient unhealthy resolved (had 1 consecutive fail(s), no action taken)
```

Or during a real failure:

```
[2026-05-03 06:30:01] level 1: restarting fr24feed.service
[2026-05-03 06:35:02] level 2: USB reauth on RTL-SDR (vendor 0bda)
[2026-05-03 06:40:01] level 3: rebooting Pi (receiver still down after service restart + USB reauth)
```

---

## Lessons learned (real production gotchas)

These bit a real station running on a Pi 4 with an RTL2838 dongle. The script alone will not fix them — they need additional one-time setup. **Read these before deploying.**

### 1. Persistent journal (so you can diagnose freezes)

Many Pi feeder images mount `/var/log` as a `tmpfs` (RAM disk) to reduce SD-card wear. The trade-off is that a hard reboot or freeze wipes the kernel journal — **you lose every clue about what just happened**.

If you want to be able to figure out the cause of a future hang:

```sh
# /etc/fstab — comment out (or delete) the line that looks like:
# tmpfs   /var/log    tmpfs    defaults,noatime,nosuid,mode=0755,size=50m

# /etc/systemd/journald.conf — set:
Storage=persistent
SystemMaxUse=200M
```

Reboot. After the next freeze you can run `sudo journalctl -b -1 -e` and actually see the last seconds before the hang.

### 2. Hardware watchdog (so a freeze auto-recovers)

The Pi has a BCM2835 hardware watchdog at `/dev/watchdog0`. systemd can use it to auto-reboot if the kernel stops responding. Add to `/etc/systemd/system.conf`:

```
RuntimeWatchdogSec=30s
RebootWatchdogSec=2min
```

After reboot, verify with `journalctl -b | grep -i watchdog` — you should see `Using hardware watchdog 'Broadcom BCM2835 Watchdog timer'`. From now on, a kernel hang of more than 30 s auto-resets the Pi instead of needing a manual power cycle.

### 3. Kernel DVB modules silently break dump1090 (the worst one)

This is the most insidious failure mode and it cost us a full day. The kernel auto-loads several modules when an RTL-SDR dongle is plugged in, because the chip identifies as a DVB-T receiver:

```
dvb_usb_rtl28xxu  rtl2832  rtl2832_sdr  dvb_usb_v2  dvb_core
```

The FR24 install ships an `unregister_kernel_modules.sh` that's supposed to unload them on each `fr24feed` start. **It misses `rtl2832_sdr`.** That single module being resident is enough to silently corrupt dump1090's libusb access — even though `lsusb` shows the device, `rtl_test` works, and `fr24feed-status` reports `Receiver: connected`.

The signature:
- `dump1090-mutability` is alive but at ~0.1 % CPU (should be 3–10 %)
- `cat /run/dump1090-mutability/stats.json | jq .latest.local.samples_processed` returns `0`
- `Tracked AC` is `0` indefinitely
- `fr24feed` logs `[reader][w]Global timeout exceeded, 0 msgs, 0 resyncs, reconnecting` every ~10 minutes

The fix is a one-time blacklist. Create `/etc/modprobe.d/no-rtl-sdr.conf`:

```
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist dvb_usb_v2
blacklist dvb_core
```

Reboot. The DVB modules will never load again, dump1090 owns the dongle cleanly, and the symptom disappears for good.

### 4. USB extension cables fail in subtle ways

`dmesg` floods like this on enumeration:
```
usb 1-1.4: device descriptor read/64, error -71
usb 1-1-port4: attempt power cycle
usb 1-1.4: unable to enumerate USB device
usb 1-1: USB disconnect
```

`error -71` (`EPROTO`) gets the dongle blamed nine times out of ten. Try removing the USB extension and plugging the dongle directly into the Pi *before* declaring the dongle dead. In our case the cable was the only fault — a $2 part masquerading as a $30 hardware problem.

### 5. dump1090 wedges in D-state on USB transfers

If the dongle's RF tuner gets into a stuck state (heat / RF glitch / unknown), `dump1090-mutability` stays alive but stops getting samples. `kill -9` may not free it because it's parked in an uninterruptible kernel USB call. The level-2 USB re-authorize action in this script handles many cases by cancelling pending bulk transfers; for genuine hardware-state corruption only a reboot fixes it (level 3).

### 6. Tuner choice matters more than people say

The cheap dongles often ship a Fitipower **FC0013** tuner. Its max gain is ~20 dB and its frequency response rolls off at the upper end of its range — and 1090 MHz sits right at that upper edge. It works, but you're operating outside its sweet spot.

Switching to an **R820T2**-based dongle (FlightAware Pro Stick Plus, RTL-SDR Blog v3) typically multiplies the message rate 3–5× with the same antenna and same Pi. Max gain 49.6 dB, noise figure ~3.5 dB at 1090 MHz, frequency range 24–1766 MHz.

Check what tuner you have:

```sh
sudo systemctl stop fr24feed
rtl_test -t
sudo systemctl start fr24feed
```

Look for `Found Rafael Micro R820T tuner` (good) vs `Found Fitipower FC0013 tuner` (limited).

---

## Uninstall

```sh
crontab -l | grep -v '/usr/local/bin/monitor_fr24feed.sh' | crontab -
sudo rm /usr/local/bin/monitor_fr24feed.sh
sudo rm -rf /var/lib/fr24-monitor
rm -rf /home/pi/logs/fr24feed_monitor.log*
```

The blacklist file at `/etc/modprobe.d/no-rtl-sdr.conf` and the systemd / fstab tweaks above are *not* installed by this repo — leave them in place if you applied them.

## License

MIT — see [LICENSE](LICENSE).
