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
As of 2026-07-31, `qbittorrent`, `sabnzbd`, `bazarr` and `prowlarr` have working Traefik routers but
**no tunnel hostname**, so all four return `000` externally while radarr/sonarr return 302/200.

**Better test than hitting the public URL — send the Host header straight at Traefik.** This isolates
steps 1+3 from step 2: if this returns the same code as a known-working service, the internal path is
complete and the *only* thing missing is the Cloudflare Public Hostname.
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: <svc>.majordoob.com" http://127.0.0.1/
```
Verified 2026-07-31: `bazarr` → 200, `prowlarr` → 302 (identical to `radarr` → 302). Neither needs an
app-level host/exposure setting — the *Arr apps and Bazarr do not validate the Host header, unlike
SABnzbd/homepage/qBittorrent.

**You cannot add a Public Hostname from this host.** `cloudflared` runs
`tunnel run --token-file`, and a *tunnel token* only authenticates the connector — it is not an API
token and cannot manage ingress. Adding hostnames requires either the Zero Trust dashboard or a
separate Cloudflare API token with `Cloudflare Tunnel: Edit` + DNS edit scope (not currently stored in
`tofu-stack-secrets/`).

**Security note:** qBittorrent currently runs with `CSRFProtection=false`,
`HostHeaderValidation=false`, `ServerDomains=*`, and an `AuthSubnetWhitelist` that only covers
192.168.0.0/16. Its WebUI can set arbitrary paths and run programs on completion, so public exposure
without a gate in front is effectively remote code execution for anyone who guesses the password.
Put **Cloudflare Access** in front of qBittorrent/SABnzbd (Zero Trust → Access → Applications) rather
than exposing them bare, and change the WebUI password from the default.

**WHERE TO USE CLOUDFLARE ACCESS — AND WHERE NOT TO (decided 2026-08-01):**

| Service | Access? | Why |
|---|---|---|
| qBittorrent, SABnzbd | **Yes** | No auth worth exposing; qBit can run programs on completion (= RCE) |
| Prowlarr | **Yes** | Holds every indexer credential and API key |
| **Home Assistant** | **NO — removed** | Has strong native auth + 2FA; Access actively breaks the companion app |
| Radarr, Sonarr, Bazarr | Optional | Own login; lower blast radius |
| Seerr (`overseerr.majordoob.com`) | **Under review 2026-10-24** | Currently behind Access. See note below before removing |

**Seerr without Access — preconditions (checked 2026-10-24, Seerr 3.4.1):** login allows Plex
sign-in *and* local email/password (`main.localLogin: true`, `newPlexLogin: true`). Users: id 1 =
owner (Plex-linked, no local password, ADMIN); **id 2 "Ito" = LOCAL account with a password and
permissions 34 = ADMIN + REQUEST** (169 of 332 requests). Exposed without Access, that local admin
login is brute-forceable and an admin can read every Radarr/Sonarr/Plex API key in Settings. Before
removing Access: drop Ito to Request + Auto-Approve (or move Ito to Plex sign-in and set
`localLogin: false`). **Done 2026-10-24:** Ito (the owner's dad) set 34 → **160 = REQUEST (32) +
AUTO_APPROVE (128)**, then **176** (+ MANAGE_REQUESTS 16, needed for the "Remove from Sonarr/Radarr"
buttons — the owner wants family to delete watched media; no settings/API-key access) via `POST /api/v1/user/2/settings/permissions` (API key from
`mounts/overseerr/settings.json` → `main.apiKey`; Seerr on `127.0.0.1:5055`). 169 requests intact.
Next (owner is arranging): move Ito to Plex sign-in, confirm requests stay on his user, then set
`localLogin: false`. Permission bits: `server/lib/permissions.ts` in seerr-team/seerr. Also keep Seerr updated — CVE-2026-27707 (unauthenticated account creation via
`/api/v1/auth/jellyfin` on Plex instances) and CVE-2026-27792 were fixed in 3.1.0; Access is what
would have blocked the first one. Access cannot be changed from this host (tunnel token only).

**Do not put Access in front of Home Assistant.** It stacks two independent auth systems that fight
each other, and the breakage is intermittent rather than obvious:
- The **companion app** holds a persistent WebSocket and makes background API calls that cannot
  perform a browser-based Access redirect → sensor updates, location tracking and notifications fail
  silently and sporadically.
- **Webhooks** from outside hit the Access wall with no way through.
- HA already has accounts, TOTP 2FA and failed-login banning — it is designed to be internet-facing
  in a way qBittorrent is not.

**Diagnosing Access "Invalid login session" (seen 2026-08-01 on HA):** the infra is usually fine —
check the edge directly before touching Traefik or the bridge:
```bash
curl -s -I --max-time 20 https://<svc>.majordoob.com/ | grep -iE '^HTTP|^location|^set-cookie'
```
A `302` to `https://<team>.cloudflareaccess.com/cdn-cgi/access/login/...` plus a `CF_AppSession`
cookie means Access is working correctly and the failure is in the *login round trip*.
**The handoff JWT in that redirect URL is valid for exactly 300 seconds** (`exp - nbf` in the base64
`meta=` param). "Invalid login session" almost always means that window closed — a stale tab/bookmark,
an email one-time-PIN that took too long to retrieve, or an in-app webview that does not share
Safari's cookie jar so `CF_AppSession` is orphaned mid-redirect. Fix: open the app URL fresh in a real
browser and complete login within 5 minutes.

Team domain is `doobster.cloudflareaccess.com`. Access policies **cannot** be managed from this host —
`cloudflare_tunnel_key.txt` is a *tunnel* token (connector auth only), not an API token.

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

- **⚠️ ADDING A USB CONTROLLER IN FUSION'S GUI REVERTS THIS FIX (learned 2026-07-31).**
  Because this fix works by *removing* the legacy controllers, the VM legitimately shows as having
  no USB controller in Fusion's "USB & Bluetooth" pane — so the natural reaction is to add one back.
  Doing that (or otherwise editing that pane) makes Fusion rewrite the vmx and restore the legacy
  controllers:
  `usb.present` → `TRUE`, `ehci.present` → `TRUE`, `usb.pciSlotNumber` → `32`,
  `ehci.pciSlotNumber` → `34`. The `autoConnect` lines survive, but the dongle immediately goes back
  to `virtPath:usb:0` on the next power-on and ZHA fails again with the same `ENOENT`.
  **After ANY visit to that pane: power the VM off and re-run `apply-zigbee-passthrough.sh`.**
  This happened while legitimately changing the drives' Plug In Action — the drive fix stuck, the
  Zigbee fix did not, and it had to be re-applied.

  **Re-confirmed 2026-10-22 (HA-project session):** the owner opened that pane to set the new
  Camera-Storage T7's Plug In Action, saw "no USB controller", and stopped without adding one.
  Verified intact afterwards: vmx unmodified since 2026-09-29, ZBT-1 on `virtPath:usb_xhci:5`, only
  xHCI initialized. So Camera-Storage's Plug In Action is **not** set. Set it only in a maintenance
  window: VM off → set it → re-run `apply-zigbee-passthrough.sh` → verify the virtPath.

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

**Third drive, Camera-Storage (Samsung T7 500 GB), added 2026-10-22:** its Plug In Action is unset
(see the re-confirmation note above). No vmx autoconnect rule matches Samsung (`04e8`), and it isn't
mounted into any container, so a lost race would only affect the planned Fregata app.

**Plex:** Runs natively as a macOS app (not in Docker — needs hardware-accelerated transcoding), listening on `:32400`. Not managed by compose. Check with `lsof -iTCP:32400 -sTCP:LISTEN`. A LaunchAgent watchdog (`~/Library/LaunchAgents/com.plex.watchdog.plist` → `plex-watchdog.sh`) polls port 32400 every 60s and runs `open -a "Plex Media Server"` if nothing's listening. This self-heals the known failure mode where a Plex auto-update tears down PMS but fails to restart it, leaving orphaned plugin helpers and no listener. Watchdog logs: `/tmp/plex_watchdog.{out,err}` (only written on restart action).

**Updating Plex (procedure established 2026-09-03).** Plex is a **Homebrew cask**
(`plex-media-server`) that is *also* flagged `auto_updates`, so it patches itself in place and
**brew's Caskroom metadata drifts** — before this update brew believed `1.42.2` was installed while
`1.43.2` was actually running. Consequences:
- `brew outdated --cask` is silent about it; you need **`--greedy`** to see or upgrade it.
- Upgrading via brew resyncs the drift, which is why it is preferred over letting Plex self-update.
- Do **not** trust brew's version as the running version. The truth is
  `curl -s http://127.0.0.1:32400/identity` (or the bundle's `CFBundleShortVersionString`).

**The watchdog MUST be booted out during the upgrade.** It polls every 60 s and runs
`open -a "Plex Media Server"` whenever :32400 is not listening — during an upgrade that races the
installer swapping the `.app` bundle and can relaunch a half-installed server. Sequence that works:
```bash
launchctl bootout gui/$(id -u)/com.plex.watchdog          # 1. disarm the watchdog FIRST
osascript -e 'quit app "Plex Media Server"'                # 2. graceful quit (port closes in ~2 s)
#    3. back up (below), 4. brew upgrade --cask --greedy plex-media-server
open -a "Plex Media Server"                                # 5. relaunch
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.plex.watchdog.plist   # 6. re-arm
```
Confirm re-armed with `launchctl list | grep com.plex.watchdog` — forgetting step 6 silently removes
the self-healing that covers Plex's own failed auto-restarts.

**macOS layout gotchas when backing Plex up:**
- There is **no `Preferences.xml`** on macOS (that is the Linux/Windows layout). Settings live in
  `~/Library/Preferences/com.plexapp.plexmediaserver.plist` — that is also where the token is.
- The system `/usr/bin/sqlite3` **cannot open Plex's DB** — it fails with
  `unknown tokenizer: collating`. That is *not* corruption. Use Plex's own bundled binary:
  `"/Applications/Plex Media Server.app/Contents/MacOS/Plex SQLite" <db> "pragma integrity_check;"`
- Data dir is 3.5 GB; the part worth keeping is
  `Plug-in Support/Databases` (545 MB, compresses to ~295 MB). Back up with Plex **stopped** so the
  DB is quiesced and the backup is consistent.

**`brew upgrade` may autoremove unrelated formulae.** This run autoremoved `ripgrep`. Harmless here
because `rg` is supplied declaratively by Nix (`/run/current-system/sw/bin/rg`) and the brew copy was
a duplicate — but check what autoremove took before assuming it was junk.

**2026-09-03 — SECURITY update `1.43.2.10687` → `1.43.3.10896`.** Plex emailed users on 2026-09-01
(a step it reserves for serious advisories); 1.43.3 patches issues affecting **1.43.2 and earlier**.
CVEs were requested but not yet published at the time. The two fixes named in the release notes:
- `(Security) Address potential vulnerability in the CompanionProxy. (PM-5763)`
- `(Security) TranscoderH264Options / TranscoderH264OptionsOverride can no longer be modified over
  the network. (PM-5766)`

PM-5766 matters here because this server **is internet-facing** (`customConnections =
https://plex.majordoob.com:443`, routed by the `plex-cf@file` Traefik router). Those prefs feed the
transcoder's command line, so network-writable was a code-execution shape.

**Verify the PM-5766 fix directly rather than trusting the version string** — attempt the write and
require a 403 (the pref is empty by default, so this is non-destructive):
```bash
curl -s -o /dev/null -w '%{http_code}
' -X PUT \
  "http://127.0.0.1:32400/:/prefs?TranscoderH264Options=-preset%20ultrafast&X-Plex-Token=$TOKEN"
```
Confirmed **403**, value still `''` after the attempt. (Note: the `advanced` attribute in
`/:/prefs` is *not* a network-writability flag — do not read it as one.)

Verified after: libraries and counts identical (Movies 173, TV Shows 35, Kids Youtube Shows 2), same
`machineIdentifier` so clients see the same server, hardware transcoding intact
(`HardwareAcceleratedCodecs=1`), updater reports 0 pending, all 3 Traefik plex routers enabled,
external URL unchanged at 401. Backups:
`backups/plex-db-pre-1.43.3-20260903190732.tar.gz` and `backups/plex-prefs-pre-1.43.3-*.plist`.

**2026-10-21 — update `1.43.4.10903` → `1.43.5.11029` (Plex2Shell context).** Plex had
self-updated to 1.43.4 while brew still recorded `1.43.3.10896` (drift again). News and Reddit
reports of "Plex2Shell" (PoC 2026-10-16, exploited from 10-17; an unauthenticated RCE chain that
drops an XMRig miner, payload `x12345`, plus a Linux proxy backdoor `myawesomeproxy`) prompted it.
That chain was fixed in 1.43.3.10861, so this server (1.43.3+ since 2026-09-03) was already patched.
1.43.5 adds PM-6201 (requests arriving through a proxy), PM-6183 (request locality), PM-5958
(library scoping in search), and PM-5538 (DVR post-processing validation), all relevant because
Plex is internet-facing via Traefik.
- **Compromise check first, all clean:** no miner-like processes or mining-pool connections;
  `TranscoderH264Options*` and `DvrPostProcessingScript` prefs empty; no `Scripts/` in the data dir;
  no unexpected LaunchAgents/Daemons or crontab; no `x12345`/`myawesomeproxy` files or log hits.
- **Same procedure as above**, with 0 active streams, plus `HOMEBREW_NO_AUTOREMOVE=1
  HOMEBREW_NO_INSTALL_CLEANUP=1` to avoid brew side effects. DB `pragma quick_check` = ok. Backups:
  `backups/plex-db-pre-1.43.5-20261021110109.tar.gz` (289 MB) and `backups/plex-prefs-pre-1.43.5-*.plist`.
- **Verified:** same `ProcessedMachineIdentifier`; section counts identical to the pre-update DB
  (Movies 169, TV Shows 35, Kids Youtube Shows 1, lower than on 2026-09-03 because of deletions since,
  not the update); `HardwareAcceleratedCodecs` on; 0 pending updates; 0 ERROR lines in the new log;
  Traefik clean; external URL still 401; watchdog re-armed.

**Pre-existing log noise — not caused by updates.** `WARN - Error replying to broadcast packet:
send_to: Can't assign requested address` appears constantly (10,800 hits in the previous rotated log,
16,222 in the one before). It is GDM/discovery broadcast on an interface with no assigned address.
Ignore it; grep for `ERROR`, not `WARN`, when judging a restart.

**A STALE CLIENT TOKEN LOOKS EXACTLY LIKE "THE SERVER IS BROKEN FOR ONE DEVICE" (2026-09-08).**
Symptom: one Apple TV could browse the whole library in Infuse but every play attempt died instantly
with *"An error occurred loading this content. HTTP 0 (server error)"*. Every other client — Infuse on
another TV, laptop, phone, and the Plex app on the *same* Apple TV — worked fine.

Server-side signature, in this order:
```
ERROR - downloadContainer: expected MediaContainer element, found html
ERROR - TranscodeUniversalRequest: unable to get container: /library/metadata/<id>?...
WARN  - Failed to obtain a streaming resource for direct play of part <n>
   -> client gets 503
```
The "found html" is a red herring worth understanding: the internal fetch returned
`<html>...401 Unauthorized</html>`, and the XML parser reports the *shape* of the error page, not the
auth failure underneath. **Chase the 401, not the html.**

**Why it hits exactly one device — there are TWO auth checkpoints, and only one of them is real:**
1. **Edge** (client → Plex). Passes because the LAN is in `allowedNetworks` (`192.168.1.0/24`); Plex
   logs it literally as `(Allowed Network (Subnet))`. **The network exemption satisfies this check, so
   a broken token is not caught here.** This is why browsing looks perfectly healthy.
2. **Internal** (Plex → itself on `127.0.0.1` to build the playback session). Loopback is *not* in
   `allowedNetworks`, so here the token must stand on its own — and a stale one fails.

Diagnose by comparing the token annotation on the internal loopback line between a working and a
failing client. This one line is the whole diagnosis:
```bash
L="/Users/tanjiro/Library/Logs/Plex Media Server/Plex Media Server.log"
grep 'Request: \[127\.0\.0\.1.*library/metadata' "$L" | tail -5
```
- `Signed-in Token (doobie.dev)` → token propagated, playback works
- `Signed-in Token ()` → **empty account, the bug** — 401 follows

**Fix: sign out of Plex inside the client app on that device and sign back in.** Nothing to change on
the server. Verified 2026-09-08: last 401 at 13:02:33, successful 206s on the same previously-failing
part at 13:12 — including a 4K DV file.

**Two false leads, both disproved by evidence — do not repeat them:**
- *"`allowedNetworks` is misconfigured, exempt loopback."* Wrong: Infuse on the healthy TV makes the
  identical internal call and it succeeds. See the danger note below.
- *"4K Dolby Vision content is broken."* Wrong: part `19074` (1080p h264) served **206 to `.52` and
  503 to `.219`** — same file, same second, different device. The failing TV also 503'd on a small
  YouTube `.mp4`. Correlate **client → status per part**, never content alone.

**⚠️ NEVER ADD `127.0.0.1` TO PLEX'S `allowedNetworks` ON THIS HOST.** Every guide online recommends
exactly this for the "found html" error. **It would publish the entire library to the internet with no
authentication.** Traefik reaches Plex via `http://host.docker.internal:32400`, and OrbStack NATs that
through loopback — verified with a tagged probe, container traffic arrives as `127.0.0.1 (Loopback)`,
indistinguishable from Plex's own internal calls. Exempting loopback therefore also exempts everything
arriving via `plex.majordoob.com`. There is no Cloudflare Access in front of Plex (it returns Plex's
own `401`, not an Access `302`), so that exemption is the only thing standing between the public
internet and the library.
```bash
# prove what source IP a container appears as before trusting any loopback rule
docker compose exec -T traefik sh -lc 'wget -qO- "http://host.docker.internal:32400/identity?zz=probe1"'
grep 'probe1' "$L"     # -> Request: [127.0.0.1:NNNNN (Loopback)]
```
That the internal 401 fails *closed* is a load-bearing security property here, not a bug to fix.

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

### 2026-09-24 outage — "nothing was connecting out", fixed by reboot

Host was rebooted at 17:53 local after outbound connectivity degraded. **Root cause was not captured**
— macOS unified log retains nothing across the reboot (`log show` for the pre-reboot window returns
0 lines) and OrbStack's `vmgr.1.log` logged no errors before shutdown. What the evidence does and does
not support:

**Confirmed — the failure was in NEW connection establishment, not the link:**

| Time (local) | Evidence |
|---|---|
| 16:00, 16:45 | Prowlarr: NZBgeek + IPTorrents `Http request timed out` |
| 17:07–17:08 | Seerr → GitHub `connect ETIMEDOUT 140.82.114.6:443` |
| 17:10–17:50 | Seerr `Plex Scan interrupted`, every 5 min without fail |
| 17:47 | Prowlarr: NZBgeek + IPTorrents time out again |
| 17:50 | Prowlarr `ApplicationUpdateCheck` times out (a third, unrelated destination) |

Meanwhile **long-lived connections never dropped**: gluetun's OpenVPN tunnel stayed up continuously
from 2026-09-23T15:12Z to shutdown with zero reconnects, and cloudflared kept all 4 QUIC connections
registered. Inbound tunnel requests still *arrived* — they failed as
`Incoming request ended abruptly: context canceled`, i.e. clients giving up on the origin.

Established connections surviving while new ones time out, across several containers reaching
several unrelated destinations, is the signature of the **NAT/connection-tracking layer**, not of the
ISP or the VPN. The OrbStack VM had **55 days of uptime** (kernel timestamp 4783996s ≈ 55.4d).
This is consistent with — but does not prove — OrbStack's network stack degrading over long uptime
under a 308-torrent qBittorrent workload (DHT/PEX/LSD all enabled, `max_connec` 500).

**Do not over-read two pieces of evidence:**
- Radarr's `http://prowlarr:9696/... Http request timed out` looks like internal-network failure but
  is **not** independent evidence — Radarr proxies searches *through* Prowlarr, so Prowlarr holding
  the request open while waiting on a dead indexer produces exactly this. It is a downstream artifact.
- Prowlarr's `Proxy validation failed` is **cosmetic**: `proxyEnabled = False`. It also fired
  2026-09-20 and 2026-09-24T17:57 (post-reboot, while healthy). Not related.

**If it recurs, capture evidence before rebooting** — the reboot is what destroyed the diagnosis:
```bash
docker compose exec -T prowlarr sh -lc 'wget -qO- --timeout=10 https://ipinfo.io/ip'  # container egress
curl -s --max-time 10 https://1.1.1.1/ -o /dev/null -w '%{http_code}\n'              # host egress
ssh/console into the OrbStack VM and dump: conntrack -C, dmesg | tail -50
log show --last 30m --predicate 'process == "configd"' --style compact | tail -50
```
If host egress is fine while container egress times out, the fault is OrbStack and
`orb restart` (or restarting just the VM) is the minimal fix — a full host reboot is not needed.

**2026-10-23 22:04:57 — OrbStack VM stopped cleanly (NOT a crash).** vmgr logged
`"stop requested" reason=1` → `[VM] stopped`, daemon `status 0`; the OrbStack GUI process kept
running, so `/var/run/docker.sock` dangled and every container was down while Plex/HA bridge (native)
stayed up. "update available" had been logged daily since 10-21, so a quit/update prompt is the
likely trigger — the log does not say. Recovery: `orb start`; engine ready in ~5 s and all 18
containers returned via `restart: unless-stopped` (no `up -d` needed), 300 torrents 0 errored.
Diagnose with `grep '🌲 vmgr' ~/.orbstack/log/vmgr.log | tail` — look for `stop requested`.

**Post-reboot state was otherwise clean.** Boot gate passed (`complete: OK`), both volumes mounted
with sentinels, no phantom `Plex-Storage 1` stub, all nested/top-level binds materialized in
`/proc/mounts`, Zigbee still on `virtPath:usb_xhci:5` with xHCI the only controller, 308 torrents
intact. NZBgeek and IPTorrents both test OK again; only `TorrentGalaxyClone` still fails, and that one
is broken at the source (redirects to `torrentgalaxy.info/get-posts`), unrelated to this outage.

### homepage had NO restart policy — fixed 2026-09-24

`homepage` was the only one of 18 services whose compose block omitted `restart:`, so its container
was created with `RestartPolicy=no`. It took a clean `SIGTERM` (exit 143) at shutdown and **never came
back** — the one container missing after the reboot. Every other service had `unless-stopped`.

Added `restart: unless-stopped` to the `homepage:` block. Verified the dry-run touched homepage only
before applying, then confirmed 200 locally, all three routers re-registered, and 200 through Traefik.

**Traefik registration lags a container recreate by a few seconds** — the Host-header probe returned
404 immediately after `up -d` and 200 on the next poll. Poll before concluding a router is broken.

**Worth auditing after adding any service:** a missing `restart:` key is invisible until a reboot,
and `docker compose ps` on a healthy day gives no hint. Check with:
```bash
for c in $(docker compose ps -a --format '{{.Name}}'); do
  printf '%-16s %s\n' "$c" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $c)"
done
```

## Storage & Hardlinks

| Volume | Device | Used For |
|--------|--------|----------|
| `/Volumes/Working-Storage/` | Samsung PSSD T7 (SSD, USB 3.0) | SABnzbd/usenet downloads |
| `/Volumes/Plex-Storage/` | WD Elements (HDD, USB 3.1) | Final media library, torrent downloads |
| `/Volumes/Camera-Storage/` | Samsung PSSD T7 500 GB (SSD, USB) | Planned Fregata snapshots and event clips (not this stack) |

**Camera-Storage (added 2026-10-22, HA project):** APFS/GUID, owner `tanjiro`, serial
`S5TFNS0R528236X` (`disk8`). Don't confuse it with Working-Storage, the 2 TB T7 `S7MVNS0Y806696W`.
No container mounts it. Fregata (planned, see *Home Assistant project* below) writes there.

**Hardlink rules (INTENT — not currently achieved, see Radarr Notes):** Torrent downloads and media
library are both on Plex-Storage so that Radarr/Sonarr can hardlink during seeding. **Measured
2026-07-30: hardlinking does NOT work here.** Same-volume is necessary but not sufficient — the two
paths are separate *bind mounts* inside the container and OrbStack refuses `link()` across them, so
Radarr silently copies. 1.88 TB is currently duplicated. See **Radarr Notes → HARDLINKS ARE BROKEN**.
Usenet has no seeding requirement so cross-volume copy+delete is fine there by design.
qBittorrent share limits are **disabled**, so nothing auto-removes finished torrents (intentional —
the user is fine seeding indefinitely).

**Key volume mounts:**
- qBittorrent: `/Volumes/Plex-Storage/downloads/torrents:/data/torrents`
- Radarr/Sonarr/Bazarr/Unpackerr: `/Volumes/Plex-Storage:/data` (single parent — enables hardlinks)
- SABnzbd: `/Volumes/Working-Storage/downloads/usenet:/data/usenet`
- **Radarr/Sonarr: `/Volumes/Working-Storage/downloads/usenet:/usenet`** — top-level, see below
- Radarr/Sonarr: `/Volumes/Plex-Storage/media:/media_files` (legacy, still mounted)

**NESTED BIND MOUNTS SILENTLY FAIL AT BOOT — found and fixed 2026-07-31.** After the 2026-07-30
hardlink migration added the `/Volumes/Plex-Storage:/data` parent, the two binds nested *inside* it
(`/data/torrents`, `/data/usenet`) stopped materializing when containers start at boot. Docker's
config still lists them and `docker inspect` shows them; they just are not in the container's mount
table. No error is logged anywhere.

Symptom: Radarr and Sonarr both raised the health error
*"download client SABnzbd places downloads in `/data/usenet/complete/tv` but this directory does not
appear to exist inside the container."* Sonarr was reading an empty directory that fell through to
`/Volumes/Plex-Storage/usenet` (created as a bare mountpoint), while the real content sat on
Working-Storage. **Usenet imports were broken for ~1 day.** Nothing real was lost — the only content
in `complete/` was a 0-byte `_FAILED_` release and the `test_download_*` benchmark files.

Only usenet actually broke. `/data/torrents` failing is harmless because the remote path mapping
`gluetun: /data/torrents/ → /data/downloads/torrents/` already redirects to a path reachable through
the `/data` parent (torrents live on Plex-Storage). Usenet is on **Working-Storage**, so *no* path
under `/data` can reach it — the nested mount was the only route.

**It is a race, not a hard limitation.** On a manual `docker compose up -d sonarr radarr` the nested
`/data/torrents` mount *does* materialize; it only fails when containers start at boot, right after
the external volumes mount. Do not rely on nesting either way.

**Fix applied:** move usenet to a **top-level** `/usenet` target on Radarr and Sonarr, and make the
remote path mapping do real work:
```
sabnzbd : /data/usenet/  ->  /usenet/      # was an identity no-op: /data/usenet/ -> /data/usenet/
```
SABnzbd itself is unchanged — it has no `/data` parent bind, so its `/data/usenet` is effectively
top-level and always worked. Bazarr and Unpackerr have no usenet mount at all.

**Verify after any boot or recreate — `docker inspect` is NOT sufficient, it shows the intent:**
```bash
docker compose exec -T sonarr sh -lc 'grep -E " /data| /usenet| /media_files" /proc/mounts'
docker compose exec -T sonarr sh -lc 'ls /usenet/complete/'   # expect: movies  tv
```
If a mount is in `docker inspect` but absent from `/proc/mounts`, it silently did not apply.

**RESOLVED / STALE — the "T7 is slow" issue does NOT reproduce (re-measured 2026-07-31).**
The old note claimed Working-Storage benchmarked at ~24 MB/s write and blamed a USB-A port or a
USB 2.0 cable. **That diagnosis was wrong and the symptom is gone.** Measured now:

| Volume | Device | Negotiated link | 1 GB write |
|---|---|---|---|
| Working-Storage | Samsung PSSD T7 | **SuperSpeed+ 10 Gb/s** | **918 MB/s** |
| Plex-Storage | WD Elements 25A3 | SuperSpeed 5 Gb/s | **162 MB/s** |

Both are at or near expected performance (918 MB/s is essentially the T7's rated ceiling; 162 MB/s is
normal for a 3.5" USB HDD). Crucially the **T7 negotiates 10 Gb/s** — a USB 2.0 cable would cap the
link at 480 Mb/s (~60 MB/s) and report `Device Speed = 2`, so a bad cable was never the cause.

Check negotiated link speed with `ioreg` (`system_profiler SPUSBDataType` returns empty under some
sandboxes):
```bash
ioreg -rc IOUSBHostDevice -l | grep -E '"USB Product Name"|"Device Speed"'
```
`Device Speed`: `1`=Full 12 Mb/s · `2`=High/USB2 480 Mb/s · `3`=SuperSpeed 5 Gb/s · `4`=SuperSpeed+ 10 Gb/s.
(The ZBT-1 dongle correctly reports `1` — it is a full-speed CP210x, which is exactly why VMware
routes it to UHCI by default. See the Zigbee section.)

**Still open — the USB *stability* problem is real and unexplained.** Plex-Storage has dropped off the
USB bus mid-operation under sustained I/O (see below). Better cables remain worth fitting for
**stability**, not speed — do not expect a throughput change, there is nothing left to gain.
Both 1 GB benchmarks above completed with both volumes still mounted and sentinels intact.

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

## Queue cleanup 2026-09-24 — 18 Radarr orphans + 3 Sonarr redundants removed

Cleared 21 stuck items (20 torrents + 1 usenet, ~0.56 TB). Radarr queue 18 -> 0, Sonarr 4 -> 1.

**The 18 Radarr rows were all orphans, and the diagnosis is a one-liner:** compare
`includeUnknownMovieItems=true` (18) against `=false` (**0**). Zero on the second means every row is
unlinked. Corroborate with two more facts before deleting: **0 of 18 had any grab history**
(`GET /api/v3/history?downloadId=<hash>` empty) and none matched a library movie. They had
accumulated Feb–Aug 2026, i.e. *after* the 2026-07-30 cleanup — this recurs with every bulk delete.

**The 4 Sonarr rows were NOT orphans — all 4 episodes already had files in the library.** Three
distinct causes, and two of them were Sonarr working correctly:
| Item | Message | Reality |
|---|---|---|
| Reacher S04E02 | Not a Custom Format upgrade | `[Scene]` **0** vs existing **1700** — correctly refused |
| Lioness S03E04 | Not a Custom Format upgrade | `[Scene]` **0** vs existing **1700** — correctly refused |
| Your Friends & Neighbors S01E05 | matched to series by ID | redundant; **usenet**, not a torrent |
| Lioness S03E06 | Unable to determine if file is a sample | **file is corrupt** (see below) |

Do not assume a stuck Sonarr row is a fault. Check `hasFile` on the episode and compare the CF scores
first — "Not a Custom Format upgrade" means the system is protecting a better file.

**Not every queue row is a torrent.** Your Friends & Neighbors S01E05 had `protocol: usenet` /
`downloadClient: SABnzbd` and therefore **no hash** — it will silently drop out of any hash-based
join against qBittorrent. Check `protocol` before building a delete list, or you will under-count.
Also: SABnzbd's `mode=history&name=delete&del_files=1` **removed the history row but left the 10 GB
of files on disk** — verify the path afterwards and `rmtree` it yourself.

**⚠️ AUTOHEAL RESTARTED QBITTORRENT MID-CLEANUP — the documented risk is real.** Deleting ~0.55 TB
blocked qBittorrent's event loop; its healthcheck (`curl -f localhost:8080`, 10s timeout, 3 retries)
failed and autoheal restarted it at 00:04:53 and 00:06:18. Recovery was clean **only because the
deletes had already finished** — all 20 were confirmed removed (308 -> 288) before the restart. It
reloaded all 288 torrents with **0 errored / 0 missingFiles**.

Mitigations that worked, and should be reused:
- **Pace 4 s between deletes** and re-assert mount + sentinel before every single item.
- **Probe qBittorrent's liveness before each delete and ABORT if it stops answering.** This fired at
  item 20/20 and stopped the run; without it the remaining deletes would have raced the autoheal
  restart, which is exactly how torrents get removed from the session while their files survive.
  Resume the remainder after it recovers.
- Consider `docker compose stop autoheal` for very large cleanups, then start it after.

**Expect a SECOND, cosmetic wave of failures after the restart.** Radarr/Sonarr put qBittorrent in
`DownloadClientStatus` backoff (same mechanism as `IndexerStatus`, same `ProviderId` column) at
escalation level 2 = **5 minutes**. While it is active **the queue reads 0 — the queue is a live view
of the download client, so a broken connection looks identical to an empty queue.** Do not interpret
that as success. It self-cleared in 3–5 min; no DB surgery needed (unlike the 3-hour indexer backoff).

Verified after: Radarr queue 0, Sonarr queue 1 (the corrupt file, deliberately kept), libraries
unchanged (181 movies/165 with files; 37 series/1398 episode files), 288 torrents 0 errored,
0 health errors, all 18 containers running.

### A torrent can be 100% complete and still be a corrupt file

`Lioness 2023 S03E06 ...-NTb.mkv` (11.2 GB) fails Sonarr's own ffprobe with
`EBML header parsing failed`. Its first 32 MB+ are zeros and its tail is zeros, with data only in the
middle — yet **qBittorrent reports it 100% complete and keeps seeding it**. Sonarr surfaces this only
as the vague *"Unable to determine if file is a sample"*.

This is the fingerprint of a Plex-Storage USB dropout during write (see Storage & Hardlinks). Check a
suspect file directly rather than trusting the client's progress figure:
```bash
# a valid .mkv starts 1A 45 DF A3; all-zero means the header was never written
xxd -l 16 "<file>.mkv"
docker compose exec -T sonarr sh -lc '/app/sonarr/bin/ffprobe -v error -show_entries format=duration -of default=nw=1 "<path>"'
```
Sonarr ships its own ffprobe at `/app/sonarr/bin/ffprobe` (there is no `/usr/bin/ffprobe`).
A full header sweep of all 427 files under `downloads/torrents` found **exactly one** bad file, so
this was isolated, not systemic — worth re-running that sweep after any future USB dropout.

**Second occurrence 2026-10-23 — it is NOT isolated.** `VisionQuest S01E04 Malware 2160p DSNP ...-RAWR.mkv`
(4.2 GB, written 2026-10-20 22:25) has the identical fingerprint: all-zero header, all-zero last 4 KB,
`EBML header parsing failed`, qBittorrent `progress=1`, Sonarr *"Unable to determine if file is a
sample"*. Treat that Sonarr message as a corruption signal and check the header first. Two hits in
~6 weeks means the header sweep should be rerun periodically, not only after an observed dropout.
Removed the same day via `DELETE /api/v3/queue/<id>?removeFromClient=true&blocklist=false` (episode
already had a good library file). Sweep afterwards: 419 video files checked, only Lioness S03E06 still
bad. **Incomplete torrents false-positive in this sweep** — qBittorrent preallocates, so an in-progress
download (e.g. Killing Faith at 11%) shows the same zero header/tail. Filter on `progress == 1` first.
Sweep script pattern: head magic (`1A45DFA3` mkv, `ftyp` at offset 4 for mp4) + all-zero last 4 KB,
re-asserting mount + sentinel every 25 files.
Lioness S03E06 (NTb) was then removed the same way at user request — library already holds a valid
`-CAKES` 9.6 GB copy (header `1A45DFA3`). Result: qBittorrent 298 torrents / 0 errored, Sonarr queue
**0** after `RefreshMonitoredDownloads`, 0 known-corrupt files left under `downloads/torrents`.

## IPTorrents hit-and-runs — READ BEFORE DELETING ANY TORRENT (2026-10-23)

IPTorrents issued a warning: **140 active H&Rs vs an allowed 40** (5-day grace). Site showed
"133 torrents require seeding" while the *account* ratio was healthy (2.66, 2.83 TB up / 1.06 TB down).
**H&R is judged per torrent, not per account** — each torrent must reach 1:1 on its own, or be zapped
with bonus points / upload credit (the torrent must be STOPPED in the client before zapping).

- ~280 of ~298 torrents are IPT (announce hosts `*.empirehost.me`, `*.bgp.technology`,
  `*.stackoverflow.tech`). **All 280 were below 1:1** (88 under 0.1, 134 under 0.5); 29 had uploaded
  0 bytes. Swarms are seedbox-saturated (median 37 seeds / 0 leechers), so old torrents essentially
  never reach 1:1 by passive seeding.
- **Every past "orphan cleanup" (2026-07-30, 2026-09-24) and both corrupt-file removals on
  2026-10-23 (VisionQuest S01E04 RAWR, Lioness S03E06 NTb — both IPT, both <1:1) deleted IPT torrents
  below 1:1 → each one is an H&R.** Any delete/seed-limit plan must exclude IPT torrents below 1:1
  unless they are being zapped.
- 21 IPT torrents sat in `stoppedUP` since 2026-02 (Monster High, The Pitt S02E07, ...) — stopped
  torrents are not seeding.
- qBittorrent reported `connection_status: firewalled`; forwarded port matched gluetun
  (ProtonVPN NAT-PMP) and gluetun's iptables accepted it on tun0, yet a TCP connect from outside to
  the VPN exit IP:port failed. Not connectable = far less upload.

### IPT's H&R page — the actual rules and costs (read 2026-10-24)

The site's H&R list (red "N torrents require seeding" link) states an entry clears by ANY of:
**seed it 336 hours (14 days)**, reach 1:1, zap with bonus points, or zap with surplus upload credit.
So **a torrent seeded ≥14 days never becomes an H&R** — that is the safe seeding floor for any
future removal/seed-limit policy. Only torrents *no longer seeding* with ratio < 1 appear.

Snapshot 2026-10-24: **131 H&Rs**, bonus 14,414 pts, surplus upload credit 1.77 TB.
- **124 of 131 show `Downloaded 16 kB`, `Uploaded 0`, zap = 1 point** — mostly FraMeSToR/HYBRID
  remuxes (Harry Potter set, Deadpool, Drive, Shrek...). Probably freeleech grabs (download not
  counted) later removed by upgrades/cleanups — unverified.
- 7 real ones: Deadpool & Wolverine remux and Solo Mio remux (1,000 pts each — appears capped),
  Solo Mio 1080p 976, Ready or Not 2 710, VisionQuest S01E04 RAWR 349, The Prosecutor 84,
  Challengers 65. Points for all 131 = **4,307.5**; the same 7 via surplus credit ≈ 53 GB.
- **None of the 131 were still in qBittorrent.** Fuzzy name matches were different releases
  (other group/quality) or copies from a *public* tracker (Monster High Electrified, DO NOT ENTER —
  huge ratios there, never seeded on IPT). Match on exact release name before stopping anything.
- 2 torrents in qBit report `unregistered torrent` on IPT (Masters of the Universe 2026 FLUX-ish,
  Rick and Morty S09E05) — removed from the site, cannot be seeded there.

### Seeding policy (applied 2026-10-24): seed 15 days or ratio 1.05, then remove WITH files

Replaces "seed indefinitely". qBittorrent global: `max_seeding_time_enabled` + `max_seeding_time
21600` (15 d = IPT's 336 h + 1 d margin), `max_ratio_enabled` + `max_ratio 1.05`,
**`max_ratio_act 3` = remove torrent AND files** (enum: 0 stop, 1 remove-keep-files,
2 super-seed, 3 remove-with-content). Hardlinks mean the library copy survives. Deleting a movie in
Seerr/Radarr is now enough — the torrent ages out within 15 days, no orphans accumulate.

- **Per-torrent `ratio_limit = 1`** is already stamped on every torrent by Radarr/Sonarr (indexer
  seed-ratio setting) and overrides the global 1.05 — fine, 1:1 also satisfies IPT.
- **The old action was `1` (remove, KEEP files)** — torrents hitting their per-torrent 1.0 were
  silently dropped from qBit with data left on disk. Likely why 0 of 280 IPT torrents were ≥1:1 and
  why untracked folders piled up (82 entries / 1.32 TB found, 0.90 TB not hardlinked; none were the
  only copy of a wanted Radarr movie, 18 duplicated a library file).

**One-time cleanup run 2026-10-24:** 246 torrents meeting the rule removed with files, 5 s apart,
mount + sentinel + qBit liveness checked before each, queue items protected (Killing Faith, Beast,
Resident Dead, Disclosure Day), autoheal stopped for the duration. Free space 3.3 → 4.5 TB.
Library verified identical by count AND on disk: 175/175 movie files, 1365/1365 episode files.
**qBit's API stalls for 10–60 s while unlinking big non-hardlinked files** — the first run aborted
at item 16 on a 10 s liveness timeout although qBit was healthy. Use a grace period (3 min) before
aborting, and keep autoheal stopped, or its healthcheck restarts qBit mid-delete.

**Untracked-folder cleanup, same night:** 43 leftover folders removed (8 + 35, 5 s apart, mount +
sentinel per item, re-checking qBit ownership every 10, skipping anything modified < 2 h). 15
entries under `downloads/torrents/incomplete/` were deliberately excluded (qBit's in-progress area).
Several folders vanished mid-run on their own — RAR releases (ETHEL/GRACE) whose torrent had just
been removed; qBit deletes only its own files, leaving Unpackerr's extracted `.mkv`, which Unpackerr
then cleans up. A cleanup script must treat "already gone" as a skip, not an error (first run
crashed on it). End state: **Plex-Storage 3.3 TB → 5.3 TB free**, 52 torrents / 0 errored, library
re-verified on disk (175/175, 1365/1365).

### Why so many grabs come from IPTorrents (measured 2026-10-24, last 120 days)

"Prefer usenet" was ALREADY configured — both apps' delay profile has `preferredProtocol: usenet`,
NZBgeek is indexer priority 1 (IPT 5). It barely matters: the *Arr decision order is
**quality → custom-format score → protocol**, so protocol is only a tiebreaker.

| App | Grabs | IPT | NZBgeek | Why IPT wins |
|---|---|---|---|---|
| Radarr | 267 | **195 (73%)** | 61 | 86 Remux-2160p + 15 Remux-1080p — remuxes are rarely on usenet; 169/195 had CF score > 0 |
| Sonarr | 793 | 78 (10%) | 715 | already usenet-dominated; IPT mostly RSS races (52) |

132 of Radarr's IPT grabs were `UserInvokedSearch` (Seerr requests / manual searches). Delay profiles
also have `torrentDelay: 0` + `bypassIfHighestQuality: true`, so a remux bypasses any delay anyway.
**The real lever for Radarr is the quality profile (remux preference), not protocol settings** —
and remuxes (50–80 GB) are also the hardest torrents to seed to 1:1.

**Decision 2026-10-24: remuxes disabled** in Radarr `English + Spanish 4k` (207 movies). Done in
`mounts/recyclarr/recyclarr.yml` (`enabled: false` on Remux-2160p and Remux-1080p) — **not** in the
Radarr UI, because recyclarr manages this profile's qualities and its nightly sync would revert a
UI-only change. Previewed first: exactly 2 quality toggles, 0 deletes, 0 score changes. Allowed now:
WEB 1080p, Bluray-1080p, WEB 2160p, Bluray-2160p (cutoff Bluray-2160p / score 8000 unchanged).
The remux entries stay ranked at the top, so the 71 existing remux files still outrank everything
and are never replaced. Note `recyclarr.yml` is gitignored (under `mounts/`) — backups:
`backups/recyclarr.yml.bak-20261024002837`, `backups/radarr-qualityprofiles-pre-noremux-*.json`.

### Root cause of "firewalled": ProtonVPN forwards the port on a DIFFERENT IP than egress

ProtonVPN servers have several public IPs. The NAT-PMP mapping (what gluetun's port forwarding gets)
lives on one IP, while outbound traffic — including tracker announces — leaves from another. The
tracker records the *egress* IP, hands peers `egress:port`, and nothing is forwarded there. Port sync
is NOT the problem: `sync-qbittorrent-port.sh` (ofelia, every 5 min) keeps `listen_port` correct.
Proton changes the port on every reconnect (57456 → 58369 → 62461 → 64496 … in one week).

Measured 2026-10-23 across 5 servers — **mismatch is common, not a one-off:**

| Server | entry | NAT-PMP (forward) IP | egress IP | |
|---|---|---|---|---|
| node-us-260 | 72.14.148.2 | 72.14.148.6 | 72.14.148.22 | mismatch |
| node-us-378 | 95.173.217.158 | 95.173.217.170 | 95.173.217.184 | mismatch |
| node-us-365 | — | 79.127.136.219 | 79.127.136.195 | mismatch |
| **node-us-130** | — | **89.187.180.34** | **89.187.180.34** | **MATCH** |

On node-us-130: `connection_status` went firewalled → **connected**, 161 inbound TCP connections in
3 min (vs 0 for the whole evening before), upload 3–5 MB/s.

**Things that did NOT work:** qBittorrent `announce_ip` set to the NAT-PMP IP + reannounce → 0 inbound
in 4 min (IPT apparently ignores the `ip=` param). Reverted to `''`.

**Diagnose in 30 s** (query Proton's NAT-PMP gateway directly; read-only "public address" request):
```bash
docker run --rm --network container:gluetun python:3-alpine python3 -c 'import socket,struct;s=socket.socket(2,2);s.settimeout(5);s.sendto(struct.pack("!BB",0,0),("10.96.0.1",5351));print(socket.inet_ntoa(s.recv(64)[8:12]))'
docker compose exec -T gluetun sh -lc 'wget -qO- https://ipinfo.io/ip'   # must be EQUAL to the above
nc -z -G 5 <forward-ip> "$(docker compose exec -T gluetun cat /tmp/gluetun/forwarded_port)"  # from host
```
gluetun's iptables `ACCEPT ... dpt:<port>` packet counter staying at 0 is the tell. qBittorrent's
own "firewalled" flag is only advisory (it just means no inbound seen recently).
**Previously nothing monitored this** — the watchdog only restarts dead qBittorrent — which is why it
surfaced months later as a tracker H&R warning rather than an alert.

### Durable fix (2026-10-24): pinned servers + reachability watchdog

**A server's IPs are assigned PER CONNECTION — "good server" is a probability, not a property.**
`node-us-144` matched on one probe and mismatched on the next (.138 vs .142). Repeated probes in a
throwaway container (`gluetun-probe`, same secrets, never touches the live VPN):

| Server (Chicago unless noted) | forward IP == egress |
|---|---|
| node-us-130 | 5/5 |
| node-us-304 | 4/4 |
| node-us-300 | 3/3 (+1 run where port forwarding itself failed) |
| node-us-320 | 3/4 |
| node-us-364 | 1/4 — dropped |
| node-us-144 (New York) | 1/2 — dropped |
| Boston 317/318, Secaucus 230/256, Phoenix 260, Dallas 378, 365 | 0/1 each |

1. **`SERVER_HOSTNAMES`** on gluetun is pinned to 130, 304, 300, 320 (keeps `SERVER_COUNTRIES` too —
   filters AND together). Gluetun picks randomly among them on each connect. Must be a single line
   with no spaces — a YAML `>-` fold inserted a space after a comma.
2. **`qbit-watchdog.sh`** (repo root, mounted read-only into the `docker:cli` container; replaces
   the old inline `sh -c` loop, whose two original checks it keeps). Every 5 min it runs
   `nc -z <gluetun /tmp/gluetun/ip> <forwarded_port>` from OUTSIDE the VPN — the exact address
   trackers advertise. 3 consecutive failures (~15 min) → restart gluetun, wait healthy + port file,
   restart qbittorrent, run the port sync. 30-min cooldown between reconnects so a Proton-wide outage
   cannot cause a restart loop. Logs: `docker logs qbit-watchdog`.
   - Verified the check has a working negative control: a closed port on the same IP fails.
   - The check also fails if qBittorrent is on a stale port (only qBit listens), so it covers a
     lagging port sync too.
   - **Validated live 2026-10-24:** landed on a mismatched node-us-144 connection; watchdog logged
     failures at 04:07:48 / 04:12:58 / 04:18:09, reconnected at 04:18:37 (28 s) to node-us-304,
     port synced, reachable from outside, 298 torrents 0 errored, 8080 listener intact.

**Probing a server without touching the live VPN** — throwaway container, then query its netns:
```bash
docker run -d --name gluetun-probe --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$PWD/tofu-stack-secrets/openvpn_user.txt:/run/secrets/openvpn_user:ro" \
  -v "$PWD/tofu-stack-secrets/openvpn_pass.txt:/run/secrets/openvpn_pass:ro" \
  -e VPN_SERVICE_PROVIDER=protonvpn -e VPN_TYPE=openvpn \
  -e OPENVPN_USER_SECRETFILE=/run/secrets/openvpn_user -e OPENVPN_PASSWORD_SECRETFILE=/run/secrets/openvpn_pass \
  -e VPN_PORT_FORWARDING=on -e PORT_FORWARD_ONLY=on -e SERVER_HOSTNAMES=<host> \
  -e HTTP_CONTROL_SERVER_ADDRESS=:8001 qmcgaw/gluetun
# then the NAT-PMP one-liner above with --network container:gluetun-probe, and
docker exec gluetun-probe wget -qO- https://ipinfo.io/ip ; docker rm -f gluetun-probe
```
Server metadata (city, entry IPs, port_forward flag) is in `mounts/gluetun/servers/protonvpn.json`.

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
- 2026-09-24 — Sonarr `4.0.19.2979 → 4.0.20.3014`, Radarr `6.3.0.10514 → 6.4.4.10685`.
  Clean: migrations ran without error, both `pragma integrity_check` = `ok`, libraries identical
  (Radarr 181 movies/165 with files; Sonarr 37 series/1398 episode files/3.81 TB), queues preserved
  (18/4), remote path mappings intact, hardlink probe still passes, 0 health *errors* after.
  Rollback image ids if ever needed: radarr `sha256:29fc2a54cadb`, sonarr `sha256:efac4096b91d`.
  Backups: `backups/{sonarr,radarr}-config-pre-update-20260924183739.tar.gz` (both verified to
  contain the live `.db` and to pass `gzip -t`).
  **Sonarr 4.0.20 adds a NEW health check, `AllowedHostsCheck`** — it warns that Allowed Hosts is
  unset so Sonarr accepts any Host header. It appeared *because of* the update, not because anything
  broke; see the note below before acting on it.
- 2026-07-30 — Sonarr `4.0.17.2952 → 4.0.19.2979`, Radarr `6.1.1.10360 → 6.3.0.10514`
- 2026-07-30 — remaining 12: autoheal, bazarr, cloudflared, gluetun, homepage, prowlarr,
  qbit-watchdog, qbittorrent, sabnzbd, seerr, tautulli, traefik. All healthy afterwards; qBittorrent
  kept all 248 torrents and did not orphan its netns.
- Not updated (intentional): `pinchflat` (pinned `v2025.6.6`), `huntarr` (local-only image),
  `ofelia`, `recyclarr`, `unpackerr` (already current).

**`AllowedHostsCheck` on Sonarr (new in 4.0.20) — do not "fix" it by guessing a host list.**
Sonarr is reached under at least three different Host headers here: `sonarr.majordoob.com` via the
Cloudflare tunnel, `localhost:8989` for API/scripted calls, and `sonarr`/container-name from inside
`servarrnetwork` (Huntarr, Recyclarr, Bazarr, Prowlarr sync all talk to it). Setting Allowed Hosts to
an incomplete list silently breaks whichever caller was omitted — and the *Arr apps historically did
**not** validate Host, which is exactly why exposing them needed no app-level setting (unlike
SABnzbd/homepage/qBittorrent — see Architecture). Leave it as a warning unless you are deliberately
hardening, and if you do set it, include every name above and re-verify internal callers afterwards.

## Huntarr Notes

**Live config:** Huntarr's `/config` uses the external Docker volume `tofu-stack_huntarr-config` mounted as `huntarr-config` in Compose. The old `mounts/huntarr` directory is retained as a backup/source snapshot, not the live config.

**Why:** Huntarr hit `database disk image is malformed` while `/config` was bind-mounted on macOS. Moving `/config` to a Docker volume mirrors the Sonarr fix and gives Huntarr's SQLite DB normal Linux filesystem semantics.

**Prowlarr:** Huntarr's Prowlarr integration points at `http://prowlarr:9696` inside Docker. The API key is stored in Huntarr config; never print it. If the `#prowlarr` settings view fails, check Huntarr logs first for SQLite errors, then verify Prowlarr from inside Huntarr.

**Sonarr modes:** Huntarr's Sonarr missing mode is currently a single `Sonarr` instance in `seasons_packs` mode. Huntarr supports `seasons_packs`, `shows`, and `episodes`, but no single combined "packs plus individual episodes" mode. Do not add a second Sonarr instance unless explicitly requested.

## Indexer backoff outlives the outage that caused it

**After ANY network outage, expect indexers to look "unreachable" for up to 3 more hours even though
they work.** Seen 2026-09-24: NZBgeek reported unreachable while it was provably fine.

**Radarr/Sonarr track indexer health SEPARATELY from Prowlarr.** Prowlarr can show 0 disabled
indexers and pass `POST /api/v1/indexer/testall` while Radarr/Sonarr still refuse to query them. Each
*Arr keeps its own `IndexerStatus` table with an escalating `DisabledTill`; 6 consecutive failures =
escalation level 6 = a **3-hour** penalty box. An outage burns through those 6 failures quickly, so
the penalty long outlives the outage.

**Diagnose in this order — do not stop at the health warning:**
```bash
# 1. is the indexer actually reachable? (caps is UNAUTHENTICATED - proves reachability only)
docker compose exec -T prowlarr sh -lc 'wget -qO- --timeout=20 "https://api.nzbgeek.info/api?t=caps"' | head -c 200
# 2. is the API KEY / account still good? (authenticated - this is the one that matters)
curl -s "http://localhost:9696/api/v1/search?query=the&indexerIds=<id>&type=search&limit=5" -H "X-Api-Key: $PK"
# 3. whose backoff is it? prowlarr's or the *Arr's?
curl -s "http://localhost:9696/api/v1/indexerstatus" -H "X-Api-Key: $PK"     # prowlarr
```
`GET /api/v3/indexerstatus` is **Prowlarr-only and 404s on Radarr/Sonarr** — read their DB instead.
The column is `ProviderId`, *not* `IndexerId`:
```bash
docker run --rm -v /Users/tanjiro/containers/tofu-stack/mounts/radarr:/config:ro alpine sh -lc \
  'apk add --no-cache sqlite >/dev/null && sqlite3 -header -column "file:/config/radarr.db?mode=ro" \
   "select ProviderId, EscalationLevel, MostRecentFailure, DisabledTill from IndexerStatus;"'
```
**Never `select *`** — `LastRssSyncReleaseInfo` embeds a Prowlarr API key in download URLs.
**Compare `MostRecentFailure` against the outage window.** If the last failure predates the recovery,
the indexer is fine and only the timer is stale.

**Two "obvious" clears that DO NOT work** (both tried and verified failing, 2026-09-24):
- Re-saving the indexer (`PUT /api/v3/indexer/<id>`) — returns `202` but leaves the rows untouched.
- An interactive search (`GET /api/v3/release?movieId=`) — does **not** bypass the penalty box; it
  silently queries only the healthy indexers. A search returning results is therefore *not* proof the
  others recovered. **Always check which indexers actually answered**, by name and count.

**To force-clear** (only when the failures are provably stale — otherwise just wait it out): stop the
container first, since concurrent SQLite writes are what corrupted these DBs before.
```bash
docker compose stop radarr
docker run --rm -v /Users/tanjiro/containers/tofu-stack/mounts/radarr:/config alpine sh -lc \
  'apk add --no-cache sqlite >/dev/null && sqlite3 /config/radarr.db \
   "delete from IndexerStatus where ProviderId in (6,12); pragma wal_checkpoint(TRUNCATE);" \
   && sqlite3 /config/radarr.db "pragma integrity_check;"'
docker compose start radarr
```
The rows are pure transient state — recreated on the next failure, nothing is lost.
**Leave a genuinely-broken indexer's backoff alone** (here `TorrentGalaxyClone`): the penalty box is
doing useful work keeping it from hammering a dead host.

**Verify by indexer, not by total.** Same Radarr search before/after the 2026-09-24 clear:
16 releases (Pirate Bay only) → **75** (NZBgeek 22, IPTorrents 37, TPB 16). Sonarr: 151 with NZBgeek
contributing 93.

## Recyclarr Notes

**FIXED 2026-07-31.** Was failing silently every night since its last successful sync on
**2026-05-14** (~2.5 months). Resolution at the end of this section.

**The original break:**
```
Fatal error: Instance 'movies': Unable to find include template with name
'radarr-quality-definition-movie'
```
Root cause: upstream `recyclarr/config-templates` **removed the includes feature**. The local clone
(`mounts/recyclarr/resources/config-templates/git/official`, HEAD `bb642fe`, 2026-05-21) now ships
`includes.json` = `{"radarr": [], "sonarr": []}` and has no `includes/` directories — only
`templates/`, which are *complete starter configs* (`remux-web-2160p`, `sqp-1-2160p`,
`radarr-anime-remux-1080p`, …), not the granular fragments `include:` consumes. All 9 `- template:`
entries in `mounts/recyclarr/recyclarr.yml` are therefore invalid.

**Do NOT just delete the `include:` blocks — verified with `sync --preview` that this DELETES 90
custom formats** (24 movies / 66 series) and guts the profiles actually in use:

| Profile | In use by | Scored CFs | Would be deleted |
|---|---|---|---|
| radarr `English + Spanish 4k` | **220 movies** | 31 | 0 — safe |
| radarr `Remux-1080p - Anime` | 2 movies | 29 | **24** |
| sonarr `4k English + Spanish` | **all 34 series** | 7 | **5** |
| sonarr `WEB-2160p` | 0 series | — | — |
| sonarr `Remux-1080p - Anime` | 0 series | — | — |

The Sonarr losses are the dangerous ones — they are the `-10000` blockers
(`BR-DISK`, `LQ`, `x265 (HD)`, `Extras`) plus `WEB Tier 01` (+1700). Removing them means Sonarr starts
accepting junk releases for every series.

**Setting `delete_old_custom_formats: false` did NOT suppress the deletions in preview** — still 90.
There is also **no `mounts/recyclarr/cache/` directory**, i.e. recyclarr has never completed a
successful sync, so it has no record of which CFs it owns.

**Also note the config drift recyclarr itself reports:**
- `replace_existing_custom_formats` was **removed in recyclarr v8** and is ignored (2 instances still
  set it). See `https://recyclarr.dev/guide/upgrade-guide/v8.0/#replace-existing-removed`.
- Running version is **v8.3.2** (`ghcr.io/recyclarr/recyclarr:latest`).
- Sonarr's `api_key` is **inlined in plaintext** in `recyclarr.yml` while Radarr correctly uses
  `!secret radarr_api_key`. Not a repo leak — `mounts/` is gitignored — but worth normalizing.
- The profile carrying all 34 series (`4k English + Spanish`) is **not managed by recyclarr at all**;
  the config manages `WEB-2160p`, which has 0 series.

**Safe way to iterate — preview against a draft without touching the live config:**
```bash
docker run --rm --network tofu-stack_servarrnetwork --user 501:20 \
  -v "$PWD/mounts/recyclarr:/config" \
  -v "$PWD/tofu-stack-secrets/recyclarr-secrets.yml:/config/secrets.yml:ro" \
  -v "/path/to/draft.yml:/config/recyclarr.yml:ro" \
  ghcr.io/recyclarr/recyclarr:latest sync --preview
```
Always grep the output for `│ Delete │` and cross-check the hits against the scored CFs of the
profiles that actually have movies/series attached before applying anything.

### How it was fixed (2026-07-31)

**The deletions came from `mounts/recyclarr/state/`, not from a cache.** Recyclarr v8 renamed
cache → **state**; `state/<app>/<instance-hash>/custom-format-mappings.json` records every CF
recyclarr manages. It deletes anything in state that the config no longer declares. The math was
exact — sonarr state 74 = 66 delete + 7 unchanged + 1 update; radarr state 57 = 24 + 29 + 4. The dead
`include:` templates had been declaring exactly those 90.

**`delete_old_custom_formats` is a dead end — do not rely on it.** It is a valid property
(default `false`), but `sync --preview` reported the same 90 deletions whether it was `true` or
`false`. Preview appears to show the raw diff regardless of the flag.

**The fix was to declare all 90 explicitly, so nothing is "old" by construction** and the flag's
behavior stops mattering. All 131 tracked trash_ids were verified to still exist in the current guide
(`resources/trash-guides/git/official/docs/json/{radarr,sonarr}/cf/*.json`) — nothing had been removed
upstream — so each was recovered with its **live score read back from the running instance**.

Changes made to `mounts/recyclarr/recyclarr.yml`:
1. Radarr `include:` → inline `quality_definition: {type: movie}` (previewed *No changes*)
2. Sonarr `include:` → removed, **deliberately WITHOUT `quality_definition`** — adding `type: series`
   rewrites Sonarr's live episode size limits, so it was left out to keep the change a no-op
3. Removed `replace_existing_custom_formats` (removed in v8, was being ignored with a warning)
4. Added 24 Radarr + 66 Sonarr recovered CF declarations with live scores
5. `delete_old_custom_formats: false` on both (belt-and-braces; nothing is undeclared now)

Verified before applying: **0 deletes, 0 creates, 17 updates, 0 fatal, 0 deprecations**, Quality
Profiles *No changes* on both, and media naming byte-identical to live with `renameMovies` already
`true` (so **no mass rename** of the 220 movies). Confirmed after: Radarr 60 CFs / 31 scored on
`English + Spanish 4k`, Sonarr 76 CFs / 7 scored on `4k English + Spanish`, all four `-10000` blockers
(`BR-DISK`, `LQ`, `x265 (HD)`, `Extras`) intact in both, anime profile still 29 scored.

Backups: `backups/recyclarr.yml.bak-<ts>` and `backups/recyclarr-state-<ts>.tar.gz`.
A stale second Radarr state dir (`7de96ad84fa57af3`, 38 mappings, from an older `base_url`) was
removed — only `radarr/744c528902940030` and `sonarr/baa8de56199cb645` are live.

**Still unmanaged by design:** Sonarr's `4k English + Spanish` carries all 34 series but is not in the
config (recyclarr manages `WEB-2160p`, which has 0 series). Bringing it under management is a
deliberate future decision, not an oversight.

**Cadence reality check:** TRaSH Guides publishes weekly (3–5 changelog batches/month, steady for
15 months), but only ~12% of *these* CFs drifted over 2.5 months and **zero new CFs** were needed.
The drift is almost entirely new release groups being added to junk blocklists (`LQ`,
`Bad Dual Groups`) and tier lists. Nightly syncing is unnecessary; quarterly captures nearly all the
value. The existing ofelia 3am job is harmless now that the config is correct.

## Deprecated / removed services

**Tdarr — native node LaunchAgent removed 2026-07-31.** The Tdarr server has long been commented out
in `docker-compose.yml`, but `~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist` was
still `RunAtLoad`, so two orphaned `Tdarr_Node` processes started at every boot and connected to
nothing (found running 4h53m, writing a 7.4 MB `Tdarr_Node_Log.txt`). Booted out with
`launchctl bootout gui/$(id -u)/com.tofu-stack.tdarr-node.tanjiro`; plist archived to
`/Users/tanjiro/containers/backups/com.tofu-stack.tdarr-node.tanjiro.plist.disabled-20260731`.
`tdarr_node/` remains on disk. Legitimate LaunchAgents are now exactly: `com.homeassistant.bridge`,
`com.plex.watchdog`, `com.tofu-stack.boot-gate`.

**Disk cleanup 2026-10-21 (internal SSD 7.9 GB → 30 GB free), done from the HA-project session with
the owner's approval:**
- `docker rmi` by name, for images no service uses: `ghcr.io/haveagitgat/tdarr:latest`,
  `ghcr.io/flaresolverr/flaresolverr:latest`, `lscr.io/linuxserver/overseerr:latest` (seerr replaced
  it), `linuxserver/ffmpeg:latest`, `lscr.io/linuxserver/tautulli:latest`.
- 31 untagged rollback images removed **by ID** (never `prune -a`). Kept the newest rollback,
  `87b9931af38a` (2026-09-29), and the local-only `huntarr/huntarr:9.1.0-local` (`fb932cc9b60b`).
  Images went from 18.8 GB to 5.8 GB; OrbStack handed the space back to macOS within a minute.
- **Moved, not deleted**, to `/Volumes/Plex-Storage/tanjiro-cleanup-2026-10-21/` (8.3 GB):
  `mounts/tdarr` (untracked), `~/Library/Caches/Homebrew` (download cache only), the `~/Downloads`
  Ubuntu 24.04.2 ISO and HAOS 15.2 zip, and `backups/{radarr,sonarr}-config-pre-update-20260924183739.tar.gz`.
  The owner can delete that folder when happy.
- Still reclaimable later: the July radarr/sonarr config tarballs in `backups/` (about 1.7 GB).

**Like Nastya (YouTube) — removed 2026-08-20 at user request** (unsuitable kids' content). Removal
took **three** independent steps; doing fewer would have let it come back:

1. **Pinchflat source** (id=1, channel `UCJplp5SjeGSdVdwsfb9Q7lQ`) — deleted. This is the step that
   actually matters: the source was `enabled`, re-indexed every 1440 min, and had **1083 videos
   indexed but only 217 downloaded**, so it was ~20% through the channel and still pulling (~500 GB
   more to come). Deleting files alone would have been undone within 24 h.
2. **Files** — 874 files / **131.8 GiB** under `media/youtube/shows/Like Nastya`. Freed 3.4 → 3.5 TiB.
3. **Plex** — library 5 `Kids Youtube Shows`, ratingKey 9911. Removed via section refresh +
   `emptyTrash`; `allowMediaDeletion=0` on this server, so Plex will *not* delete files itself.

**Deleting a Pinchflat source: use the app's own RPC, not SQL.** `media_items → sources` and
`tasks → sources` are `ON DELETE RESTRICT`, so hand-written SQL must delete in FK order *and* keep the
`media_items_search_index` FTS table in sync. Pinchflat is an Elixir release, so call its real
business logic instead — this handled all 1083 media_items, the tasks, and the pending oban job:
```bash
docker compose exec -T pinchflat sh -lc \
  '/app/bin/pinchflat rpc "Pinchflat.Sources.delete_source(Pinchflat.Sources.get_source!(1))"'
```
`delete_source/1` leaves media files on disk (there is a `/2` that removes them). That separation is
desirable here — delete the DB row fast, then pace the file deletion yourself (see below).
The `/api/v1` REST endpoints return 500; the web UI is Phoenix LiveView and not curl-drivable.

**Pace large deletes on Plex-Storage and assert the mount as you go.** 874 files were unlinked with a
0.25 s gap, re-checking `ismount` + `.tofu-volume-ok` every 10 files and aborting on failure — the
drive has dropped off the USB bus under sustained I/O before, and a bare `exists()` check cannot tell
"deleted" from "volume vanished". Script kept at
`backups/purge-like-nastya-20260820.py` as the reusable pattern. DB backup:
`backups/pinchflat-db-pre-nastya-delete-20260820123607.tar.gz`.

Remaining Pinchflat sources are exactly `Bogo Cat` (id=2) and `One off Youtube` (id=3), both enabled;
748 media_items total.

## Home Assistant project — what it changed on or around this host (as of 2026-10-25)

The HA rollout is driven from the owner's laptop (`~/code/active_projects/homeassistant_connect`,
with its own AGENTS.md; the HA config is in git at `/homeassistant` on the VM). What a session here
should know:

- **Fregata (native macOS Frigate) is planned on this Mac, not yet installed.** It's a menu-bar app
  from fregata.app ($10, 30-day trial), with its web UI and API on **:8971** and the same
  `config.yaml` and MQTT topics as Frigate. Media goes to **`/Volumes/Camera-Storage`**; the default
  `~/Fregata/media/` would fill the internal SSD. **It stays LAN-only:** never add a Traefik router or
  Cloudflare hostname for it, and never create Frigate viewer accounts (go2rtc exposes the Protect
  RTSP tokens). It needs auto-login plus Launch at Login, which adds a login item, so update the
  LaunchAgents list in *Deprecated / removed services* when it lands. The pilot is Doorbell plus Back
  Yard Porch. Protect RTSPS is already on for every camera because Scrypted uses it; detect runs on
  the Medium streams (960x720 doorbell, 1280x720 G5). **Watch RAM:** the HA VM (6 GB) and OrbStack's
  10 GB limit already overcommit the 16 GB.
- **Protect RTSP URLs are credentials.** Never print or log them; fetch them on the server side when
  writing the Fregata config.
- **The Mosquitto add-on on the HA VM has been running again since 2026-10-22** (192.168.1.5:1883,
  TLS on 8883, auth via HA users, anonymous off). It had been crash-looping on a stale custom config
  in `/share/mosquitto`. Fregata will publish to it with its own login, which the owner creates.
- **Plex-Storage holds `tanjiro-cleanup-2026-10-21/`**; see *Deprecated / removed services*.
- **UniFi changes made from the HA side** (not this stack): the Garage U6 Lite's 5 GHz moved to
  ch 165 at 20 MHz, because DFS ch 52 kept getting radar-bumped. A new firewall policy, "Block Meross
  internet", sits **above "Allow IoT to Internet"**, and any new IoT block rule must sit above it too.

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
- ~~`Like Nastya` is inconsistent~~ — **source and media deleted 2026-08-20**, see
  *Deprecated / removed services*. It was the main failing example below, so the remaining
  `Like Nastya` references in this section are historical; re-verify against `Bogo Cat` /
  `One off Youtube` before acting on them.
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
