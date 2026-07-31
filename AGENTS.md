# AGENTS.md

## Project Overview

Tofu Stack is a self-hosted media automation stack (*Arr stack) on a macOS M2 Mac Mini. Docker Compose orchestrates 18 services; a Home Assistant TCP bridge runs natively via a macOS LaunchAgent. Secrets live in `tofu-stack-secrets/` (git submodule) and must never be committed to the main repo.

**Tautulli was removed 2026-07-30** (nothing depended on it — homepage had no widget, Seerr's
`"tautulli": {}` entry was an unconfigured stub). Config backed up to
`/Users/tanjiro/containers/backups/tautulli-config-*.tar.gz`; `mounts/tautulli` kept on disk as a
snapshot. Port 8181 is now free.

## Repository Layout

- `docker-compose.yml` — Service definitions, Traefik routing labels, health checks
- `tofu-stack-secrets/` — Git submodule: credentials, Traefik configs, VPN auth
- `mounts/` — Persistent bind-mounted container volumes/config dirs; Sonarr and Huntarr are exceptions and now use Docker named volumes for `/config`
- `tdarr_node/` — (deprecated) Native macOS transcoding node configs, no longer in use
- `diskmon.py` — Real-time read/write MB/s and disk usage monitor for both volumes (run with `./diskmon.py`)
- `homeassistant-bridge.py` — Native Python TCP bridge from `:8124` to the Home Assistant VM on `192.168.1.5:8123`
- `plex-watchdog.sh` — Watchdog script that relaunches Plex if port 32400 stops listening; wired to a user LaunchAgent (see Architecture → Plex)
- `boot-gate.sh` — Ordered, condition-gated host startup (volumes → Docker → compose → HA VM → verify). Run at login by `~/Library/LaunchAgents/com.tofu-stack.boot-gate.plist`. See Host Boot & Startup Ordering.
- `apply-zigbee-passthrough.sh` — One-time vmx edit pinning the Zigbee dongle to the HA VM. Refuses to run while the VM is powered on.

Note: `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md` directly; writing through the symlink is refused.

## Commands

```bash
# Validate & Deploy
docker compose config                              # Validate YAML syntax
docker compose up -d <service> [<service>...]      # PREFER THIS - scoped, limits blast radius
docker compose up -d                               # DANGER: recreates ~26 containers (see below)
docker compose up -d --force-recreate <service>    # Recreate a single service
docker compose down                                # Stop all services

# Health & Debugging
docker compose ps                                  # Check running containers
docker compose logs -f <service>                   # Tail service logs
docker compose exec gluetun ping 8.8.8.8           # Test VPN connectivity
docker run --rm -v tofu-stack_sonarr-config:/config alpine \
  sh -lc 'apk add --no-cache sqlite >/dev/null && sqlite3 /config/sonarr.db "pragma integrity_check;"'

```

No build system, linter, or test suite. Per-service Docker health checks and log inspection serve as validation.

**CRITICAL — bare `docker compose up -d` is destructive here (2026-07-30):**
Containers on this host were created by a mix of Compose versions (many by `2.40.3`, some by `5.1.2`).
The config-hash algorithm changed between majors, so Compose considers ~26 containers "changed" even
when nothing about their config differs. A bare `docker compose up -d` therefore recreates almost the
entire stack, including stopping qBittorrent mid-seed and interrupting in-flight *Arr imports.

- Always scope to the services you mean: `docker compose up -d sonarr radarr`
- Check first with `docker compose up -d --dry-run [services]` — it lists exactly what would recreate
- Check what created a container: `docker inspect -f '{{index .Config.Labels "com.docker.compose.version"}}' <name>`
- `boot-gate.sh` refuses `up -d` when containers are already running; use `--force` to override deliberately

**Before recreating any *Arr container,** confirm it is idle. Restarting mid-import leaves partial
imports and stuck queue rows:
```bash
# expect 0 rows in state importing/downloading
curl -s "http://localhost:7878/api/v3/queue?pageSize=100" -H "X-Api-Key: $RK"   # radarr
curl -s "http://localhost:8989/api/v3/queue?pageSize=100" -H "X-Api-Key: $SK"   # sonarr
```

## Routine Health Check

Always include both Docker services and native macOS services. Do not stop at `docker compose ps`.

- Compose: `docker compose config` and `docker compose ps`
- Sonarr: API health should be `[]`; queue should be empty or explainable
- qBittorrent: container health plus local Web UI on `http://127.0.0.1:8080/`
- Huntarr: local UI should answer on `http://127.0.0.1:9705/`; check logs for SQLite errors
- Plex: `curl http://127.0.0.1:32400/identity` should return `200`
- Home Assistant bridge: `curl http://127.0.0.1:8124/` should return `200`
- Traefik: dashboard/API on `http://127.0.0.1:8888/` should answer
- Recent logs: check Sonarr, qBittorrent, Gluetun, and Unpackerr for fresh errors

## Architecture

**Access path:** Internet → Cloudflare Edge → Cloudflare Tunnel (cloudflared) → Traefik → Service. TLS terminates at Cloudflare; internal traffic is plain HTTP.

**Exposing a service on `majordoob.com` takes THREE things — all are required:**

1. **Traefik router labels** on the service. TLS terminates at Cloudflare, so the entrypoint is `web`
   (plain HTTP), *not* `websecure`, and the `.service=` binding must be explicit:
   ```yaml
   - "traefik.http.routers.<svc>-cf.rule=Host(`<svc>.majordoob.com`)"
   - "traefik.http.routers.<svc>-cf.entrypoints=web"
   - "traefik.http.routers.<svc>-cf.service=<svc>"
   ```
   For qBittorrent these live on **gluetun**, not qbittorrent (`network_mode: service:gluetun`).
2. **A Public Hostname in the Cloudflare Zero Trust dashboard.** The tunnel runs token-based
   (`tunnel run --token-file`), so ingress is managed *remotely* — there is no local ingress file to
   edit. Zero Trust → Networks → Tunnels → (tunnel) → Public Hostname → Add:
   subdomain `<svc>`, domain `majordoob.com`, service `HTTP` → `traefik:80`. DNS is auto-created.
3. **App-level host/exposure settings**, or the app rejects the new Host header:
   - SABnzbd: `host_whitelist` in `mounts/sabnzbd/sabnzbd.ini` **and** `inet_exposure`
     (`0` = local only; `5` = external with login required). Stop the container before editing the
     ini — SABnzbd rewrites it on shutdown and will clobber your changes.
   - homepage: `HOMEPAGE_ALLOWED_HOSTS` env in compose
   - qBittorrent: `WebUI\ServerDomains` in `tofu-stack-secrets/qBittorrent.conf`

**Diagnosing "I added the label but it doesn't work":** a Traefik router can be `enabled` while the
service is still unreachable — that means step 2 is missing. Check both sides:
```bash
curl -s http://127.0.0.1:8888/api/http/routers | grep majordoob   # traefik side
curl -s -o /dev/null -w '%{http_code}\n' https://<svc>.majordoob.com/   # 000 = no tunnel hostname
```
As of 2026-07-30, `qbittorrent` and `sabnzbd` have working Traefik routers but **no tunnel hostname**,
so both return `000` externally while radarr/sonarr return 302/200.

**Security note:** qBittorrent currently runs with `CSRFProtection=false`,
`HostHeaderValidation=false`, `ServerDomains=*`, and an `AuthSubnetWhitelist` that only covers
192.168.0.0/16. Its WebUI can set arbitrary paths and run programs on completion, so public exposure
without a gate in front is effectively remote code execution for anyone who guesses the password.
Put **Cloudflare Access** in front of qBittorrent/SABnzbd (Zero Trust → Access → Applications) rather
than exposing them bare, and change the WebUI password from the default.

**VPN routing:** Services needing privacy (qBittorrent) use `network_mode: service:gluetun`. Traefik labels go on `gluetun`, not the service itself.

**Media pipeline:** Download clients (qBittorrent, SABnzbd) → Unpackerr extracts archived torrent releases for Sonarr → Sonarr/Radarr organize → Plex storage.

**Unpackerr:** `unpackerr` is defined in `docker-compose.yml` and watches Sonarr's completed torrent queue for RAR/multipart archive releases under `/data/torrents/tv`. It extracts the real video file in place so Sonarr can import while qBittorrent continues seeding. It uses `tofu-stack-secrets/sonarr_api_key.txt` as a Docker secret; never print the key. Logs are written both to Docker logs and `/Volumes/Plex-Storage/downloads/torrents/unpackerr.log`.

**Home Assistant bridge:** `homeassistant-bridge.py` runs under LaunchAgent on port 8124 and forwards to the HA VM on port 8123 (Traefik in OrbStack can't route to the VMWare VM directly). Traefik must route to `http://host.docker.internal:8124`. Plist: `~/Library/LaunchAgents/com.homeassistant.bridge.plist`. Manage with `launchctl bootstrap|bootout gui/$(id -u) <plist>` and `launchctl kickstart -k gui/$(id -u)/com.homeassistant.bridge`. Bridge logs: `/tmp/ha_bridge.{out,err}`. Smoke test with `curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8124/`; expected result is `200`.

**Home Assistant macOS gotchas (macOS 26 Tahoe):**
- The bridge used to be `socat`. The Nix socat path (`/run/current-system/sw/bin/socat`) failed under launchd with `last exit reason = OS_REASON_CODESIGNING`.
- Homebrew socat (`/opt/homebrew/bin/socat`) could run and listen, but launchd-spawned socat hit macOS Local Network privacy and logged `No route to host` for `192.168.1.5:8123`; the same command worked from an interactive shell.
- Current fix is to run the bridge with `/usr/bin/python3`, which launchd can use to reach the HA VM. If the bridge regresses, first check that the plist still points at `/usr/bin/python3 /Users/tanjiro/containers/tofu-stack/homeassistant-bridge.py`.

**Zigbee dongle passthrough (fixed 2026-07-30):** The "Home Assistant Connect ZBT-1" (Nabu Casa,
`vid:10c4 pid:ea60` — Silicon Labs CP210x, EmberZNet Zigbee firmware) reaches HA via VMware USB
passthrough.

- **Root cause of "Zigbee doesn't work after a restart":** `Homeassistant-OS.vmx` had *no* USB binding
  for the dongle (only two hubs and an HID). VMware only writes USB bindings to the vmx on power-off,
  so connecting it manually in the Fusion UI is runtime-only state, lost on the next boot.
- **Fix:** `usb.autoConnect.device0 = "vid:10c4 pid:ea60"` in the vmx, applied by
  `apply-zigbee-passthrough.sh` (backs up the vmx first). **The VM must be powered off** or VMware
  overwrites the file on shutdown.
- **ZHA device path is stable** and needs no changes:
  `/dev/serial/by-id/usb-Nabu_Casa_Home_Assistant_Connect_ZBT-1_ae19043c49eced11ae850b1d62c613ac-if00-port0`
  It is a `by-id` path derived from the USB serial descriptor, so it is immune to enumeration order.
- **THE CONTROLLER MATTERS MORE THAN THE BINDING (root-caused 2026-07-31).** After the vmx entry was
  added, the host log looked perfect — device connected, `ownerdisplay:Homeassistant-OS` — and ZHA
  *still* failed with
  `[Errno 2] No such file or directory: '/dev/serial/by-id/usb-Nabu_Casa_..._ZBT-1_...-if00-port0'`.
  The dongle was attaching to `virtPath:usb:0`, the **legacy UHCI controller**.

  The ZBT-1 is a `speed:full` device, and VMware routes full-speed devices to UHCI whenever UHCI is
  present. This guest is `arm-other5xlinux-64` (HA OS 18.1 aarch64, kernel `6.18.37-haos`) and does
  **not** enumerate the x86-era UHCI/EHCI controllers. So the device attached at the VMware layer and
  the guest never saw a USB device at all → no `cp210x` bind → no `/dev/ttyUSB0` → no `by-id` symlink.
  The tell is in the log: `Autoconnecting ... prefer usb` — "usb" is the *vmx key prefix*, and it
  selects the controller. Every other device in this VM (HID, both hubs) was already on `usb_xhci:*`;
  the dongle was alone on the legacy bus.

  **Fix — disable the legacy controllers so full-speed devices have nowhere to land but xHCI:**
  ```
  usb.present  = "FALSE"
  ehci.present = "FALSE"
  usb_xhci.present = "TRUE"
  usb_xhci.autoConnect.device0 = "vid:10c4 pid:ea60"
  usb.autoConnect.device0      = "vid:10c4 pid:ea60"   # harmless fallback
  ```
  Applied by `apply-zigbee-passthrough.sh` (idempotent; backs up the vmx; refuses while powered on).
  VMware confirms it took by setting `usb.pciSlotNumber = "-1"` and `ehci.pciSlotNumber = "-1"`.
  Result: `virtPath:usb_xhci:8`, `connected to usb_xhci:6 port 0`.

- **Verify passthrough from the host** via the VM's own log. Checking only for "connected" is NOT
  sufficient — that was the mistake that hid this bug for a full reboot cycle. **Check the controller:**
  ```bash
  grep -i "ZBT-1" "/Users/tanjiro/Virtual Machines.localized/Homeassistant-OS.vmwarevm/vmware.log" \
    | tail -2 | grep -o 'virtPath:[a-z_0-9:]*'
  ```
  - `virtPath:usb_xhci:N` → **good**, the guest can see it
  - `virtPath:usb:N` → **broken**, guest will report ENOENT no matter what `ownerdisplay` says

  Also confirm only xHCI initialized: `grep -iE "Initializing '(UHCI|EHCI|xHCI)'" <vmware.log>`
  should show xHCI alone.
- `vmware-usbarbitrator` must be running for passthrough (including headless `vmrun` starts):
  `ps ax -o command | grep usbarb`
- Re-check the vmx entry survives after any clean VM shutdown.

**DANGER — VMware will try to steal Plex-Storage (found 2026-07-31).** In Fusion's *USB & Bluetooth*
dialog, `Plex-Storage (Western Digital Elements 25A3)` had **Plug In Action = "Connect to Linux"**.
VMware acted on it during the 2026-07-31 boot and only lost the race to macOS:
```
12:59:04.690 USBGA: DevID(10000002105825a3): Failed to connect device, failedStatus(9)
```
(`1058:25a3` = WD Elements.) There is no vmx autoconnect entry for it, so this is a UI-level plug-in
action — but the drive takes **84 s** to enumerate at boot, so this is a race the host can lose. If
VMware wins, the media drive is handed to the HA VM and the whole *Arr stack comes up storage-less.
**Set both external drives' Plug In Action to "Connect to Mac"** (Plex-Storage and the Samsung T7).
Re-check after any Fusion update.

**Plex:** Runs natively as a macOS app (not in Docker — needs hardware-accelerated transcoding), listening on `:32400`. Not managed by compose. Check with `lsof -iTCP:32400 -sTCP:LISTEN`. A LaunchAgent watchdog (`~/Library/LaunchAgents/com.plex.watchdog.plist` → `plex-watchdog.sh`) polls port 32400 every 60s and runs `open -a "Plex Media Server"` if nothing's listening. This self-heals the known failure mode where a Plex auto-update tears down PMS but fails to restart it, leaving orphaned plugin helpers and no listener. Watchdog logs: `/tmp/plex_watchdog.{out,err}` (only written on restart action).

## Host Boot & Startup Ordering

**The problem (2026-07-30):** macOS autologins (`tanjiro`, FileVault off) and fires login items in
parallel. OrbStack became ready and started 19 containers with `restart: unless-stopped` before the
external USB volumes had mounted, and VMware started the HA VM before the Zigbee dongle was attached.
Nothing sequenced drives → Docker → VM.

**Why this was dangerous, not just annoying:** every external mount used short-form bind syntax, and
Docker *creates missing host paths* for short-form binds. When containers won the race, Docker
silently created an empty `/Volumes/Plex-Storage/media` **on the boot SSD** and Sonarr/Radarr started
against an empty library. That also occupies the mount point, so the real drive then mounts as
`Plex-Storage 1` and nothing lines up.

**Fixes in place:**

1. **`create_host_path: false`** on all 11 external binds in `docker-compose.yml` (long-form syntax).
   Docker now refuses to start instead of fabricating a directory. Do not revert these to short form.
2. **Sentinel files** — `.tofu-volume-ok` at the root of both volumes. Presence proves the *real* drive
   is mounted; an empty stub directory will not have it. Do not delete these.
3. **`boot-gate.sh`** + `com.tofu-stack.boot-gate.plist` (RunAtLoad). Gates on *conditions with
   timeouts*, never fixed sleeps — a fixed delay is still a race you can lose.
   - `boot-gate.sh --check` — READ-ONLY verification, safe to run anytime
   - `boot-gate.sh --force` — apply compose changes even if containers are running
   - Logs: `/tmp/tofu_boot_gate.log`, `/tmp/tofu_boot_gate.{out,err}`
   - Volume UUIDs (stable, used for deterministic mounting):
     `Plex-Storage 626594D1-CFA1-4EA5-95E8-00B02F9956A1`,
     `Working-Storage B2E258B8-6B69-4D0D-A821-F58C44131502`
4. **OrbStack should be removed from login items** so the gate owns startup order
   (System Settings → General → Login Items & Extensions → **"Open at Login"**, *not* the
   "Allow in the Background" section). With `create_host_path: false` this is determinism, not safety.

**First real reboot validation — 2026-07-31, PASSED.** The gate worked end to end and the ordering
held. Timeline from `/tmp/tofu_boot_gate.log`:

| Time | Event |
|------|-------|
| 08:57:56 | gate start (`mode=boot`) |
| 08:57:57 → 08:59:09 | Plex-Storage `diskutil mount` retried 3× — `Failed to find disk` |
| 08:59:20 | Plex-Storage mounted + sentinel verified (**84 s after gate start**) |
| 08:59:21 | gate starts OrbStack |
| 09:01:33 | Docker engine ready (**2 m 12 s cold start**) |
| 09:01:33 | 17 containers already running → `up -d` correctly skipped |
| 09:01:35 | HA VM 200, HA bridge 200, no unhealthy containers → **complete: OK** |

**This is the case a fixed `sleep` would have lost.** Plex-Storage did not exist as a disk for the
first ~80 s after login — `diskutil` reported `Failed to find disk <UUID>` three times before the
drive enumerated. Condition-gating with retries is what made this boot safe; any hardcoded delay
tuned to a faster boot would have handed containers an unmounted volume.

Observations worth keeping:
- **The gate never runs `up -d` on a normal boot, and that is correct.** `restart: unless-stopped`
  brings containers back the moment the engine is ready — which the gate delays until *after* the
  volumes are verified. The gate's job is to gate OrbStack, not to start the stack.
- **Verified no phantom directory:** `/Volumes` had exactly `Plex-Storage` and `Working-Storage`
  (no `Plex-Storage 1` stub), and Radarr resolved `/data/.tofu-volume-ok` through the merged mount.
- **The HA VM is NOT sequenced by the gate.** VMware auto-started it at 08:58:04 — 8 s after login,
  while the gate was still retrying the volume mount, and ~3 min before the gate reached step 5.
  `start_vm()` handled this gracefully (`vm: Home Assistant already running`). It is benign because
  the VM lives on the internal SSD and has no external-volume dependency; its only ordering
  requirement is the Zigbee dongle, and `usb.autoConnect` covers that (see below).
- **Transient boot-window health errors are expected.** Radarr logged
  `Unable to communicate with qBittorrent. Connection refused (gluetun:8080)` because qBittorrent
  binds 8080 inside the gluetun netns *after* Radarr's first health poll. It cleared immediately on
  `POST /api/v3/command {"name":"CheckHealth"}` — force a recheck before investigating this one.

**Zigbee passthrough — the vmx entry survived, but Zigbee was still broken.** `usb.autoConnect.device0`
persisted (line 106) and the dongle attached 0.3 s after power-on with `ownerdisplay:Homeassistant-OS`
— yet ZHA still could not open the device, because the binding landed on the **legacy UHCI controller
the ARM guest cannot enumerate**. Root-caused and fixed the same day; see
**Zigbee dongle passthrough → THE CONTROLLER MATTERS MORE THAN THE BINDING**. The lesson for boot
verification: *"the log says connected"* is not evidence Zigbee works — always check `virtPath:`.

Useful side observation: VMware **re-scans and autoconnects on device arrival**, not only at power-on
(the log keeps emitting `Found device ...` every ~60 s), so a dongle that enumerates *after* the VM
boots is still picked up. Slow USB enumeration therefore does not break Zigbee the way it would have
broken the volume mounts.

**launchd gotcha:** launchd starts agents with a bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`).
`docker` lives at `/usr/local/bin/docker`, so any launchd-run script must set `PATH` explicitly or the
Docker probe silently fails. `boot-gate.sh` exports PATH and the plist sets `EnvironmentVariables`.
Test launchd-run scripts with `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin <script>`.

## Storage & Hardlinks

| Volume | Device | Used For |
|--------|--------|----------|
| `/Volumes/Working-Storage/` | Samsung PSSD T7 (SSD, USB 3.0) | SABnzbd/usenet downloads |
| `/Volumes/Plex-Storage/` | WD Elements (HDD, USB 3.1) | Final media library, torrent downloads |

**Hardlink rules (INTENT — not currently achieved, see Radarr Notes):** Torrent downloads and media
library are both on Plex-Storage so that Radarr/Sonarr can hardlink during seeding. **Measured
2026-07-30: hardlinking does NOT work here.** Same-volume is necessary but not sufficient — the two
paths are separate *bind mounts* inside the container and OrbStack refuses `link()` across them, so
Radarr silently copies. 1.88 TB is currently duplicated. See **Radarr Notes → HARDLINKS ARE BROKEN**.
Usenet has no seeding requirement so cross-volume copy+delete is fine there by design.
qBittorrent share limits are **disabled**, so nothing auto-removes finished torrents (intentional —
the user is fine seeding indefinitely).

**Key volume mounts:**
- qBittorrent/Radarr/Sonarr: `/Volumes/Plex-Storage/downloads/torrents:/data/torrents`
- SABnzbd/Radarr/Sonarr: `/Volumes/Working-Storage/downloads/usenet:/data/usenet`
- Radarr/Sonarr: `/Volumes/Plex-Storage/media:/media_files`

**Known issue:** Working-Storage (Samsung T7) benchmarks at ~24 MB/s write — far below expected 500+ MB/s. Suspected cause: USB-A port or USB 2.0 cable. Try USB-C/Thunderbolt with original Samsung cable.

**Known issue — Plex-Storage drops off the USB bus under sustained I/O (observed 2026-07-30):**
While deleting ~0.9 TB, the WD Elements vanished from `diskutil list` and `df` (disk4/disk5 gone,
`/Volumes/Plex-Storage` left behind as a stub directory), while `ioreg` still showed
`Elements 25A3` on the USB bus — i.e. USB stayed enumerated but macOS dropped the block device.
It remounted on its own a short time later.

Implications:
- "Drives sometimes don't mount" is **not only a boot-timing problem**. A mid-operation dropout can
  strand containers at any time, and `boot-gate.sh` only runs at login.
- Both drives now show USB-layer faults, which points at ports/cables/bus power on the Mac Mini
  rather than the drives themselves. Try USB-C/Thunderbolt for both.
- Pace bulk deletes (insert a short sleep between items) rather than running flat out.

**Verification trap — never trust a bare `os.path.exists()` / `ls` check on these volumes.**
When a volume unmounts, every path under it reports "missing", which reads identically to
"successfully deleted". A cleanup was wrongly reported complete this way. Always assert the mount
and sentinel first:
```python
assert os.path.ismount('/Volumes/Plex-Storage')
assert os.path.isfile('/Volumes/Plex-Storage/.tofu-volume-ok')
```
Shell equivalent: `/sbin/mount | grep -q " on /Volumes/Plex-Storage ("` plus a sentinel test.

## Sonarr Notes

**Live config:** Sonarr's `/config` is no longer `./mounts/sonarr`; it uses the external Docker volume `tofu-stack_sonarr-config` mounted as `sonarr-config` in Compose. The old `mounts/sonarr` directory is retained as a backup/source snapshot, not the live config.

**Why:** Sonarr hit recurring SQLite `database disk image is malformed` and `disk I/O error` failures while `/config` was bind-mounted. Moving `/config` to a Docker volume fixed DB writes and integrity checks.

**DB checks:**
- Use `docker run --rm -v tofu-stack_sonarr-config:/config alpine sh -lc 'apk add --no-cache sqlite >/dev/null && sqlite3 /config/sonarr.db "pragma integrity_check;"'`
- Also check `/config/logs.db` if Sonarr logs show SQLite errors.
- A known clean pre-repair backup exists at `mounts/sonarr/sonarr.db.pre-qbit-status-clear-20260519125028`.

**Completed downloads stuck in Activity:**
- If the warning says the download is an archive or no importable file exists, check Unpackerr logs first.
- If the item is a duplicate or not an upgrade, move the qBittorrent torrent to category `tv-ignored` so it keeps seeding but Sonarr stops tracking it as an import candidate.
- The 2026-05-19 stuck queue was cleared by extracting/importing the missing RAR-packed episodes, then moving duplicate/non-upgrade torrents to `tv-ignored`.

**Season packs inflate the queue — count downloads, not rows (2026-07-30):** Sonarr creates one queue
row per episode, so two stuck season packs presented as 26 rows but were only 3 actual downloads.
Always group by `downloadId`/title before judging severity. Fetch with
`includeSeries=true&includeEpisode=true` or the series/episode fields come back empty.

**"Episode file on disk contains more episodes than this file contains":** the *existing library file*
claims to span more episodes than the incoming file. Seen when a bogus file named `S02E01-E10` (1.9 GB,
43 min actual runtime) had all 10 episodes pointing at its single `episodeFileId`, blocking import of a
real 10-episode season pack. Diagnose by comparing claimed span against actual duration/size:
```bash
docker run --rm --entrypoint ffprobe -v "<dir>:/m:ro" linuxserver/ffmpeg \
  -v error -show_entries format=duration -of default=nw=1 "/m/<file>.mkv"
```
Fix: `DELETE /api/v3/episodefile/<id>`, then `POST /api/v3/command {"name":"RefreshMonitoredDownloads"}`.

**"No files found are eligible for import":** the download folder no longer exists. These never
self-clear; remove the rows with `removeFromClient=true&blocklist=false` (blocklisting would prevent
re-grabbing). Verify the folder is really gone before assuming this.

**Unparseable filenames** (e.g. truncated release group, no S/E marker) fail with `Unknown Series`.
Fix with an explicit manual import mapping to a known episode id:
`POST /api/v3/command {"name":"ManualImport","importMode":"move","files":[{path, seriesId, episodeIds, quality, languages}]}`.
Note usenet → library crosses volumes, so `move` is a real copy+delete, not a hardlink.

## Radarr Notes

**Live config:** Radarr still bind-mounts `/config` from `./mounts/radarr` (unlike Sonarr/Huntarr,
which moved to Docker volumes). Watch for SQLite symptoms; if they appear, apply the same fix.

**Orphaned "unknown" queue items after deleting movies (2026-06-28 → cleaned 2026-07-30):**
Deleting a movie in Radarr **cascades away its history rows**, which are the only link between a
torrent in the download client and a movie. The torrents keep seeding in the `movies` category, so
Radarr keeps finding them, cannot identify them, and lists them as unknown/import-blocked forever with
*"Movie title mismatch, automatic import is not possible."*

- A bulk delete of 48 movies on 2026-06-28 left **43 orphaned torrents / 1.38 TB**.
- Diagnose: `GET /api/v3/queue?includeUnknownMovieItems=true` vs `=false`. If the second returns 0,
  every row is an orphan. Orphans have `movieId: null` and no matching history by `downloadId`.
- **The queue is a live view of the download client, not stored state.** Clearing rows in the UI does
  nothing — Radarr re-reads the `movies` category minutes later and they reappear. The torrents must
  leave that category (recategorize to keep seeding, or delete).
- **Whenever you bulk-delete from Radarr/Sonarr, remove the matching torrents too.** This is the habit
  that prevents recurrence — not share limits.

**Deleting via Overseerr/Seerr's "Delete from Radarr" is safe and does the right thing** (verified
2026-07-30 with `Obsession (2026)`). It calls Radarr's delete, which removes the movie, deletes the
folder permanently (no Recycle Bin is configured), and Seerr marks its own record `status=7`.
Seerr *retains* the media/request rows as history — that is expected, not a leak.

Seerr `media.status` codes, decoded empirically against the Radarr library:
`1` = never added · `3` = processing · `4` = partially available · `5` = available · `7` = deleted.
(`5` correlated 191/191 with being in Radarr; `7` correlated 174/174 with being absent.)
`media_request.status`: `2` = approved, `4` = failed, `5` = completed.
Seerr's DB is at `mounts/overseerr/db/db.sqlite3`; the image has no `sqlite3`, so query it from the
host read-only with `sqlite3.connect('file:...?mode=ro', uri=True)`.

**The orphan risk applies only when a torrent is still seeding for the deleted movie.** A deletion is
clean if the qBittorrent `movies` category count is unchanged and, after
`POST /api/v3/command {"name":"RefreshMonitoredDownloads"}`, the queue still reports 0 rows with
`includeUnknownMovieItems=true`. Always force that refresh before declaring a deletion clean — Radarr
only re-polls the download client every few minutes, so an immediate check gives a false all-clear.

**HARDLINKS — root-caused and FIXED 2026-07-30 (new imports hardlink; old duplicates not yet reclaimed).**
Historically 0 of 88 seeding movie torrents shared an inode with their library file, costing a full
second copy of everything.

- `copyUsingHardlinks: True` in **both** Radarr and Sonarr — the app setting is correct, not the fault.
- Inside the container both paths even report the same device (`dev=37`), but an actual `ln` across
  them fails **cross-device**. They are two *separate bind mounts*, and OrbStack's filesystem driver
  refuses `link()` across mount points. Radarr silently falls back to copying.
- Cost: **55 of 88 torrents are byte-identical duplicates of their library file = 1.88 TB wasted.**
  The other 33 (0.64 TB) are different/older releases than what the library holds.
- Disk split: `media` 8.7 TB, `downloads/torrents` 3.4 TB.

Reproduce the check in one line:
```bash
docker compose exec -T radarr sh -lc '
  echo x > /data/torrents/.probe
  ln /data/torrents/.probe /media_files/.probe 2>/dev/null && echo WORKS || echo FAILS
  rm -f /data/torrents/.probe /media_files/.probe'
```

**The fix was a mount-layout change, not a settings toggle.** Applied 2026-07-30 to **radarr, sonarr,
bazarr, unpackerr** only:

```yaml
- type: bind                      # single parent mount -> hardlinks work
  source: /Volumes/Plex-Storage
  target: /data
  bind: { create_host_path: false }
- type: bind                      # nested; usenet needs no hardlinks
  source: /Volumes/Working-Storage/downloads/usenet
  target: /data/usenet
```

Canonical container paths now: `/data/media/{movies,shows}`, `/data/downloads/torrents/...`,
`/data/usenet/...`. Root folders are `/data/media/movies` and `/data/media/shows`.

**qBittorrent and SABnzbd were deliberately NOT changed.** Touching qBittorrent's save paths would
make it think 248 torrents' data had moved. Instead Radarr/Sonarr bridge the difference with a
remote path mapping — `host=gluetun`, `/data/torrents/` → `/data/downloads/torrents/`. (The download
client host as the *Arr apps see it is `gluetun`, not `qbittorrent`, because of `network_mode`.)

**How the path rewrite was done safely** — the pattern to reuse for any future root-folder move:
1. Add the new `/data` mount **alongside** the legacy ones, so no window exists where paths are invalid
2. Recreate, confirm both old and new paths resolve and the hardlink probe passes
3. Add the new root folder, then bulk-reassign with the editor API and **`moveFiles: false`**
   (`PUT /api/v3/movie/editor` / `PUT /api/v3/series/editor`). `moveFiles: true` would try to
   physically relocate 8.7 TB — assert it is false before sending.
4. Verify counts match exactly, then delete the legacy root folder
5. **Also update Radarr COLLECTIONS — they carry their own `rootFolderPath`** and the movie editor
   does NOT touch them. Missing this surfaced as a health error after the 2026-07-30 migration:
   `Missing root folder for movie collection: /media_files/movies (...51 collections...)`.
   Fix in bulk, sending *only* the path so other settings are untouched:
   `PUT /api/v3/collection` with `{"collectionIds":[...],"rootFolderPath":"/data/media/movies"}`
6. Sweep every path-bearing surface before declaring done — `rootfolder`, `collection`, `importlist`
   on Radarr; `rootfolder`, `importlist` on Sonarr. Then re-run `POST /api/v3/command {"name":"CheckHealth"}`.
7. Legacy mounts can be dropped from compose afterwards

**Expect leftover `/media_files` strings in both DBs — they are inert.** After a clean migration:
`History.Data`, `History.SourceTitle`, `DownloadHistory.Data` and `{Movie,Episode}Files.MediaInfo`
still contain the old path (Radarr 829 rows, Sonarr 4751). These are historical records and embedded
mediainfo blobs, not used to locate files. The columns that actually matter must be zero:
`Movies.Path` / `Series.Path`, `{Movie,Episode}Files.RelativePath`, `RootFolders.Path`,
`Collections.RootFolderPath`. A raw `grep` of the .db file is therefore a misleading check — query the
specific columns instead.

Verified after migration: 219 movies/192 with files and 34 series/1253 episode files — identical to
the pre-migration snapshot.

**Pre-existing duplicates were reclaimed 2026-07-30: 52/52 pairs re-linked, 1.66 TB freed.**
Disk went 2.3 TB → 4.0 TB free (84% → 73%). Libraries verified unchanged afterwards (219/192 movies,
34/1253 episode files) and all 248 torrents still seeding with 0 errored/missing.

Method (reusable if duplication ever recurs):
1. Join qBittorrent torrents to Radarr movies on `downloadId` == torrent hash (exact; never match by
   name). Keep only pairs with **identical byte size and differing inodes**.
2. Verify content with a **sampled hash** — size + SHA-256 of the head/middle/tail 64 MB. Validated
   against a full SHA-256 on a trial pair: same verdict, **25× faster** (1.0s vs 25.6s). A full hash of
   every pair would mean reading ~3.3 TB on a drive that drops off the bus under sustained load.
3. Swap with **hardlink-to-temp then `os.replace`** — atomic, so the library path is never missing:
   `os.link(torrent, lib+'.hltmp')` → verify inode → `os.replace(lib+'.hltmp', lib)`.
   Do **not** delete-then-link; that leaves a window where the library file does not exist.
4. Re-assert mount + sentinel before every item and abort the run if it fails. Pace ~4s between items.

**Deleting a movie that still has a seeding torrent ALWAYS leaves an orphan** — and it does not matter
whether you delete from Overseerr or from Radarr's own UI. Neither delete dialog removes the download.
Confirmed 2026-07-30: deleting `Crime 101` produced **two** orphans (6.9 GB WEBRip + 76 GB remux =
82.8 GB), because an upgraded movie can have more than one torrent.

**Correct workflow:** delete the movie, then go to **Radarr → Activity → Queue**, select the orphan row
and click **Remove with "Remove from download client" checked** — that removes the torrent and its data.
Equivalently, delete the torrent in qBittorrent first, then the movie. Always force
`RefreshMonitoredDownloads` and re-check the queue before declaring it clean.

**qBittorrent share limits are disabled** (`max_ratio_enabled: false`, `max_seeding_time_enabled:
false`, both categories inherit global `-2`), so nothing auto-removes finished torrents despite the
"ratio 1.0 or 2 weeks" note above. This is intentional — the user is fine seeding indefinitely.

**Mass deletion can knock over qBittorrent.** Deleting 1.38 TB blocked its event loop, its health
check timed out, and `autoheal` restarted it mid-delete. Torrents already removed from the session are
*not* resumed, leaving orphaned files nothing tracks. Delete in batches and verify afterwards.

## Container Updates

Updates are fully manual — there is no Watchtower/Diun, and ofelia only runs the qBittorrent port sync
and `recyclarr sync`. Keep it that way for *Arr apps: unattended major bumps with one-way DB
migrations, applied mid-import, is how libraries get mangled.

```bash
docker compose pull sonarr radarr        # non-disruptive; downloads only
# ... take backups, confirm queues idle ...
docker compose up -d sonarr radarr       # scoped! ~10s restart
docker compose logs --tail=50 sonarr radarr
docker image prune                       # ONLY after verifying — this deletes rollback images
```

- **`/config` survives recreation** (Sonarr: `tofu-stack_sonarr-config` volume; Radarr: `./mounts/radarr`).
- **Back up first — DB migrations are one-way.** Both apps also keep internal backups in
  `/config/Backups/scheduled`, but those live *inside* `/config`; copy them out.
  Backups live outside the repo at `/Users/tanjiro/containers/backups/` (avoids git noise):
  ```bash
  docker run --rm -v tofu-stack_sonarr-config:/config:ro -v /Users/tanjiro/containers/backups:/backup \
    alpine tar czf /backup/sonarr-config-$(date +%Y%m%d).tar.gz -C /config .
  tar czf /Users/tanjiro/containers/backups/radarr-config-$(date +%Y%m%d).tar.gz -C mounts radarr
  ```
  Verify a backup is readable *and* contains the DB: `tar tzf <file> | grep -E 'sonarr\.db|radarr\.db'`.
- **Rollback:** the previous image stays on disk untagged until pruned. Record digests before updating
  (`docker inspect -f '{{.Image}}' <name>`) so you can pin back to them.
- **Check for updates without pulling:** `GET /api/v3/update` on either app lists releases with
  `installed`/`latest` flags.

**`docker compose pull` gotchas (learned 2026-07-30):**
- **One failing image aborts the whole pull.** `huntarr/huntarr:latest` returns `pull access denied`,
  which killed the entire run — every other image reported `Interrupted` and nothing was refreshed.
  Always use `docker compose pull --ignore-pull-failures`.
- **Do not pipe pull through `tail`/`head` when checking success** — you capture the pager's exit code,
  not docker's. Use `set -o pipefail` and `${PIPESTATUS[0]}`, or check the output text.
- After pulling, confirm what actually changed rather than assuming; compare the running container's
  image id against the local tag's id:
  ```bash
  docker inspect -f '{{.Image}}' <svc>            # what the container runs
  docker image inspect -f '{{.Id}}' <image:tag>   # what was pulled
  ```
  Equal = up to date. If the pull silently failed, both match and everything looks falsely current.

**Huntarr is a LOCAL-ONLY image — it cannot be re-pulled.** Local tags `huntarr/huntarr:latest` and
`huntarr/huntarr:9.1.0-local` point at the same id (`fb932cc9b60b`, built 2026-01-30); the
`-local` suffix indicates it was built/tagged on this host. `huntarr/huntarr` on Docker Hub returns
"repository does not exist or may require 'docker login'".
- **Never run `docker image prune -a`** — it would destroy an unrecoverable image.
- Back it up: `docker save huntarr/huntarr:latest | gzip > /Users/tanjiro/containers/backups/huntarr-image.tar.gz`
- Upstream appears to publish at `ghcr.io/plexguide/huntarr:latest` (PlexGuide project) — **unverified**;
  confirm it is the same project/build before switching the compose reference.

**Update order — do it in risk tiers, verifying between each:**
1. **Isolated:** `tautulli homepage bazarr autoheal qbit-watchdog`
2. **Brief service interruption:** `prowlarr sabnzbd seerr`
3. **Access path:** `traefik cloudflared`
4. **`gluetun qbittorrent` — ALWAYS TOGETHER.** qBittorrent uses `network_mode: service:gluetun`, so
   recreating gluetun alone leaves qBittorrent on an orphaned netns: its own healthcheck passes but
   published port 8080 lands on a dead listener. Verify afterwards:
   ```bash
   docker compose exec -T gluetun sh -lc 'netstat -tln | grep -c ":8080"'   # expect 1
   docker compose exec -T gluetun sh -lc 'wget -qO- https://ipinfo.io/ip'   # must be VPN, not home IP
   curl -s http://127.0.0.1:8080/api/v2/torrents/info | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'
   ```
   Record the torrent count *before* updating and confirm it matches after.

Preconditions before any *Arr/download-client update: Radarr + Sonarr queues at 0 rows, SABnzbd
`status: Idle`, qBittorrent showing no active transfers.

**Update history:**
- 2026-07-30 — Sonarr `4.0.17.2952 → 4.0.19.2979`, Radarr `6.1.1.10360 → 6.3.0.10514`
- 2026-07-30 — remaining 12: autoheal, bazarr, cloudflared, gluetun, homepage, prowlarr,
  qbit-watchdog, qbittorrent, sabnzbd, seerr, tautulli, traefik. All healthy afterwards; qBittorrent
  kept all 248 torrents and did not orphan its netns.
- Not updated (intentional): `pinchflat` (pinned `v2025.6.6`), `huntarr` (local-only image),
  `ofelia`, `recyclarr`, `unpackerr` (already current).

## Huntarr Notes

**Live config:** Huntarr's `/config` uses the external Docker volume `tofu-stack_huntarr-config` mounted as `huntarr-config` in Compose. The old `mounts/huntarr` directory is retained as a backup/source snapshot, not the live config.

**Why:** Huntarr hit `database disk image is malformed` while `/config` was bind-mounted on macOS. Moving `/config` to a Docker volume mirrors the Sonarr fix and gives Huntarr's SQLite DB normal Linux filesystem semantics.

**Prowlarr:** Huntarr's Prowlarr integration points at `http://prowlarr:9696` inside Docker. The API key is stored in Huntarr config; never print it. If the `#prowlarr` settings view fails, check Huntarr logs first for SQLite errors, then verify Prowlarr from inside Huntarr.

**Sonarr modes:** Huntarr's Sonarr missing mode is currently a single `Sonarr` instance in `seasons_packs` mode. Huntarr supports `seasons_packs`, `shows`, and `episodes`, but no single combined "packs plus individual episodes" mode. Do not add a second Sonarr instance unless explicitly requested.

## Code Style

- **YAML:** 2-space indent, keys aligned, service sections separated by comment banners. Traefik labels grouped per service.
- **Shell:** POSIX-compatible preferred. `set -euo pipefail` for new scripts. Quote all variables/paths.
- **Python:** 4-space indent, stdlib-only unless necessary. Imports: stdlib → third-party → local.
- **Naming:** Services lowercase (hyphens only when required). Files lowercase with hyphens/underscores. Variables `snake_case`, constants `SCREAMING_SNAKE_CASE`.
- Line length ~100 chars. No trailing whitespace. One newline at EOF.
- Never commit secrets. Don't inline credentials in `docker-compose.yml`. Avoid printing secrets in logs.

## Change Workflow

1. Edit `docker-compose.yml` or config files
2. Validate with `docker compose config`
3. Preview the blast radius with `docker compose up -d --dry-run <services>`
4. Confirm the affected *Arr services are idle (no `importing`/`downloading` queue rows)
5. Apply **scoped**: `docker compose up -d <service> [<service>...]` — see the warning under Commands;
   a bare `docker compose up -d` recreates ~26 containers on this host
6. Check logs for modified services after deploy

## Current Investigation

**YouTube → Plex metadata/artwork handoff (2026-04-23):**

- `pinchflat` is defined in `docker-compose.yml` and writes to `/Volumes/Plex-Storage/media/youtube`.
- Pinchflat is already generating Plex-style TV metadata for at least some sources under `/Volumes/Plex-Storage/media/youtube/shows/...`:
  - show-level files like `tvshow.nfo`, `poster.jpg`, `fanart.jpg`, `banner.jpg`
  - episode-level files like `*.nfo`
  - episode thumbnails named `*-thumb.jpg`
- Verified examples:
  - `Bogo Cat` has `tvshow.nfo`, `poster.jpg`, `fanart.jpg`, `banner.jpg`
  - `One off Youtube` has `tvshow.nfo` and `poster.jpg`
- `Like Nastya` is inconsistent:
  - episode files exist (`.mp4`, `.nfo`, `-thumb.jpg`)
  - but the show folder has no show-level `tvshow.nfo`, `poster.jpg`, `fanart.jpg`, or `banner.jpg`
- Pinchflat DB findings from `mounts/pinchflat/db/pinchflat.db`:
  - source `Bogo Cat` has populated `series_directory`, `nfo_filepath`, `poster_filepath`, `fanart_filepath`, `banner_filepath`
  - source `One off Youtube` has populated `series_directory`, `nfo_filepath`, `poster_filepath`
  - source `Like Nastya` has those show-level paths empty even though episode `.nfo` files are present
- Likely root causes:
  - Plex library settings may not be using the correct TV library/scanner/agent or may have local assets disabled
  - Pinchflat source configuration for `Like Nastya` is missing show-level metadata/art generation
  - Plex may not use `-thumb.jpg` as episode art without renaming/copying it to match the exact episode basename
- Most useful next checks:
  1. In Plex, confirm library type is `TV Shows`, folder path points at `/Volumes/Plex-Storage/media/youtube/shows`, and `Use local assets` is enabled
  2. Check Plex scanner/agent for that library
  3. Compare Pinchflat source settings for `Like Nastya` vs `Bogo Cat`
  4. If needed, inspect the running Pinchflat container to confirm whether `mounts/pinchflat/extras/user-scripts/lifecycle` can be used for a post-download metadata fix
- A Docker inspection command was prepared but not run because the user paused before granting access:
  - `docker compose exec -T pinchflat sh -lc 'grep -Rni "user-scripts\\|lifecycle" /app 2>/dev/null | sed -n "1,200p"'`
