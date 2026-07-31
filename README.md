# Tofu Stack
Tofu Stack is a Arr stack that runs on a M2 Mac Mini with 2 extral drives. A 2TB SSD where active download
and transcoding take placed. And a 16TB HDD where media is stored.

## Cloudflare Tunnel (network layer)

> [!note]
> This section used to be titled "Cloudflare Access", which was misleading — everything below
> describes the **Tunnel**, which is network-level protection (no inbound ports). That is a
> different thing from **Cloudflare Access**, which is identity-level protection (who may log in).
> Access is documented in its own section further down.

I am using a Cloudflare domain and Cloudflare zero access tools to manage access to my resources. To begin,
my services can only be access via Cloudlfare edge therefore scanning my home network is impossible as no ports
are exposed.

```bash
Cloudflare Edge → Cloudflare Tunnel → cloudflared Container → Traefik → Service (i.e. JellyFin)
```


  1. Cloudflare Edge - External requests to *.majordoob.com hit Cloudflare's edge network (configured in Cloudflare DNS)
  2. Cloudflare Tunnel - The persistent encrypted tunnel connection maintained by the cloudflared container
  3. cloudflared Container - Receives tunnel traffic and forwards to Traefik
  4. Traefik - Routes based on hostname to the appropriate service. Notice all Cloudflare tunnel routes use the web entrypoint (port 80)
  5. Service - Final destination (Jellyfin, Sonarr, Radarr, etc.)

  Key detail: Traffic uses HTTP (port 80) between cloudflared and Traefik because:
  - TLS already terminated at Cloudflare Edge
  - Tunnel itself is encrypted
  - No need for double encryption inside your local network

  The routing from *.majordoob.com → traefik:80 is configured in the Cloudflare Zero Trust Dashboard (Networks → Tunnels), not locally.


## Cloudflare Access (identity layer)

The tunnel above stops anyone from *scanning* my network, but by itself it does **not** ask who you are.
Anything with a Public Hostname is reachable by the whole internet — the only thing standing in the way is
whatever login the app itself has. Cloudflare Access is the layer that puts an identity check in front,
before traffic ever reaches the server.

> [!IMPORTANT]
> **State as of 2026-07-30: there is NO Access application configured on any hostname.**
> Verified with the probe below — every hostname passed straight through to the origin.
> So right now each service is protected only by its own login, and a couple have none:
> `homepage` serves a bare 200, and `sonarr` serves its UI shell unauthenticated
> (its API still requires a key and does not leak it, so that one is inert).

### Verifying whether Access is actually on

Do not judge this by "I visited the site and wasn't asked to log in" — if a policy bypasses your home
IP, a protected site looks identical to an unprotected one from inside the house. Use this instead:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://<svc>.majordoob.com/cdn-cgi/access/get-identity
```

Cloudflare's edge answers `/cdn-cgi/access/*` itself whenever Access is enabled on that hostname,
**even if a policy would let you bypass**. So:

| Result | Meaning |
|---|---|
| `401` / `403` | Access IS enabled (you just have no session) |
| `200` | Access IS enabled and you have a valid session |
| `404` (origin's 404 page) | **No Access app** — request fell through to Traefik |
| `000` | hostname not reachable at all (no tunnel Public Hostname) |

### Creating an application + policy

**Zero Trust → Access → Applications → Add an application → Self-hosted**

- **Application domain**: `majordoob.com` plus the subdomain, or leave the subdomain blank and use a
  wildcard to cover everything at once
- **Session duration**: 24h is a reasonable default

Then **Add a policy**. The rule groups mean different things and this is the part that is easy to get
wrong:

- **Include** — *who* is allowed (matches if ANY entry matches)
- **Require** — an extra condition that must ALSO hold
- **Exclude** — hard deny

The policy I want (family access, US only):

| Field | Value |
|---|---|
| Policy name | `family` |
| Action | **Allow** |
| Include | Emails → my address, my dad's address |
| Require | Country → United States |

That reads as "these specific emails, and only when they are physically in the US."

An identity provider is required. **One-time PIN** is on by default and just emails a login code —
least friction for a family member who does not want another account.

### Things that break behind Access

> [!WARN]
> **Do not put Plex or Jellyfin behind Access.** Their native apps (TV, phone, Roku) cannot complete
> a browser-based login flow and will simply fail to connect. Exclude those hostnames.

Same problem for anything hit programmatically — mobile *Arr apps, API scripts. If you need those,
add a second policy with **Action: Service Auth** and a **Service Token**, and send the
`CF-Access-Client-Id` / `CF-Access-Client-Secret` headers.

Good candidates to gate: `qbittorrent`, `sabnzbd`, `traefik`, `homepage`, `prowlarr`.
qBittorrent especially — see the security note in `AGENTS.md`; its WebUI can run programs on
download completion, so it should never sit on the public internet without a gate in front.

### Exposing a new service on majordoob.com

Takes three things, all required — see `AGENTS.md` for the full detail:

1. Traefik router labels on the service (entrypoint `web`, since TLS terminates at Cloudflare)
2. A **Public Hostname** in Zero Trust → Networks → Tunnels (this is the step that is easy to forget;
   a working Traefik router with no tunnel hostname returns `000`)
3. The app's own host whitelist (SABnzbd `host_whitelist` + `inet_exposure`,
   homepage `HOMEPAGE_ALLOWED_HOSTS`, qBittorrent `WebUI\ServerDomains`)


## Traefik + cloudflared
Traefik has been great for managing SSL. One thing I wanted to add was being able to access my homeassistant
via the same SSL tunnel provided by *Cloudflare Edge*. To do that I had to create a *socat* service on the
server to redirect traffic to the homeassitant VM. This is because both the container stack and homeassistant VM
are sharing the same NIC and there was no way to redirect traffic between the two without *socat* as the
middle man.


### Home Assistant Bridge (LaunchAgent)

This setup uses a macOS LaunchAgent to automatically forward traffic from port 8124 to Home Assistant
(192.168.1.5:8123) using socat.

The reason we need this is because Traefik is running on a container in orbstack. Orbstack runs containers
in a light weight linux VM which shares the nic with the mac hostmachine. I then have VMWare running
homeassistant OS with its own IP of 192.168.1.5, but again sharing the exact same nic as orbstack.
This creates a weird routing problem where the packets between the two cannot be routed. The fix is to
add a "socat shim" in between to route traffic properly.

#### Why LaunchAgent?

- **Auto-start on login**: Service starts automatically when you log in
- **Auto-restart**: If socat crashes, launchd will restart it automatically
- **Network-aware**: Waits for network to be ready before starting
- **Persistent**: Survives reboots and continues working

#### Setup Instructions

1. **Create the plist file** at `~/Library/LaunchAgents/com.homeassistant.bridge.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homeassistant.bridge</string>

    <key>ProgramArguments</key>
    <array>
        <string>/run/current-system/sw/bin/socat</string>
        <string>TCP-LISTEN:8124,fork,reuseaddr</string>
        <string>TCP:192.168.1.5:8123</string>
    </array>

    <key>KeepAlive</key>
    <dict>
        <key>NetworkState</key>
        <true/>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardErrorPath</key>
    <string>/tmp/ha_bridge.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/ha_bridge.out</string>
</dict>
</plist>
```

2. **Load the LaunchAgent**:

```bash
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist
```

3. **Grant Network Permissions**:
   - macOS will prompt you to allow network connections for socat
   - This is required for the LaunchAgent to work
   - The prompt may appear in System Settings or as a GUI dialog
   - **IMPORTANT**: Without granting this permission, socat will fail with "No route to host" errors

   > [!WARN]
   > READ THE IMPORTANT NOTE ABOVE! THIS TOOK ME HOURS TO DEBUG SINCE I USE THE SERVER VIA CLI

#### Management Commands

```bash
# Start the service
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Restart the service
launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist && \
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Check if service is running (PID shown = running, "-9" exit code = crashing)
launchctl list | grep com.homeassistant.bridge

# View live logs
tail -f /tmp/ha_bridge.err
```

> [!note]
> After a reboot, socat may crash with exit code `-9` due to macOS resetting network permissions.
> Fix: unload and reload the LaunchAgent (the restart triggers the permission re-grant).
> If it keeps happening, check **System Settings → Privacy & Security → Local Network** and
> ensure socat is allowed.


#### Architecture

```
Browser → http://192.168.1.2:8124 (Traefik)
    ↓
socat (LaunchAgent)
    ↓
Home Assistant → http://192.168.1.5:8123
```


## VPN Gluetun
Since I do still use T if NZB is missing content we still need to manage our VPN. To do that, I am using
ProtonVPN with *openVPN*. Using the modern *WireGuard* kept giving me dropped connections while *openVPN*
has been rock solid.

To route all traffic to my VPN, I am using the AMAZING *gluetun* service. It creates a network stack on
docker that I can subscribe other services to. For example, to point *prowlarr* to gluetun it is as easy
as:

```docker-compose.yml
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    network_mode: service:gluetun # Routes through gluetun
```


### Gluetun health check
Gluetun already has a network killer if the VPN drops. To monitor the health of Gluetun I am
using a `autoheal`. Contianers marked with
```bash
    labels:
      - "autoheal=true"

```
Will be monitored and restart when they are in an unhealthy state.


> [!Note]
> `autoheal` uses `docker restart <contianer>` instead of `docker compose restart <container>` meaning that the restart
> will not respect the *depends on restart condition*. Hopefully this gets added in the future.


## *Arr Stack
The *Arr services that I am using at the time of writting are:

- Prowlarr -- Manage index's
- Radarr -- Manage M media
- Sonarr -- Manage T media
- Overseerr -- Easy interface for requesting content
- Plex -- Backend to view data

### Overseerr
Overseerr is a friendly web app that makes it easy to view content based on genre and
other filters. All requests made on it will be forwarded to either *radarr* or *sonarr*. They will handle
finding the content through *prowlarr's* indexes.

### *Arr Stack
I have subscripted to NZBGeek and NZBNews for official access to NZB index's. This has been way faster and
consistent than using T.


### Download Hardware
I was getting some slow performance from the single HDD. To improve performance I added a SSD which handles
the active downloads and any transcoding done by *tdarr*. This has improve things significantly.

```bash
󰄛 ❯ tree /Volumes/Working-Storage/downloads/ -L 2
/Volumes/Working-Storage/downloads
├── incomplete
├── nzbget
│   ├── completed
│   ├── intermediate
│   ├── nzb
│   ├── nzbget-2026-01-11.log
│   ├── nzbget-2026-01-12.log
│   ├── nzbget-2026-01-13.log
│   ├── nzbget.log
│   ├── queue
│   └── tmp
├── qbittorrent
│   ├── completed
│   ├── incomplete
│   └── torrents
└── torrents
```

#### Recreate SSD Directory Structure

After reformatting, run the following to recreate all required directories:

```bash
mkdir -p /Volumes/Working-Storage/downloads/usenet/{completed,intermediate,nzb,queue,tmp}
mkdir -p /Volumes/Working-Storage/tdarr_cache
```

> [!note]
> The volume mount in `docker-compose.yml` uses `usenet/` (not `nzbget/`). The tree above is outdated.

When the *download client* finishes its download, *radarr* or *sonarr* will move it to the HDD

```bash
/Volumes/Plex-Storage/media
├── downloads
├── movies
└── shows
```


When *tdarr* performs its trancoding, it will do it on the SSD as well.

1. tdarr picks up new item in `/Volumes/Plex-Storage/media`
2. If matches transcode requirements then begins transcode to `/Volumes/Working-Storage/tdarr_cache/`
3. When finish, replace media on `/Volumes/Plex-Storage/media`



### tdarr
This has been my biggest time pit. *tdarr* is a sick service that can encode sounds and video to different
formats. I already have *sonarr* and *radarr* only download 4k. Those files are not always in h.265,
so the first step is transcoding all files **not** in h.265 into h.265 preserving its depth.

> [!note]
> Research has been done where forcing a 10-bit depth on a 8-bit source results in no increase resolution
> and just ends up making the file bigger. So, just re-endode with the source depth for best results.


The work flow should perform the following:
- [ ] Remove Subtitles not in Spanish or English
- [ ] Create English audio in AAC 384k from TrueHD source (Or highest audio available)
- [ ] Create Spanish audio in AAC 384K from TrueHD source (If Spanish source exists)
- [ ] Remove all audio except for TrueHD English, EAC3 English, EAC3 Spanish, AAC English, AAC Spanish
- [ ] If Video is in h.264, encode to h.265 (Maintain color depth)

The flow.json is found in `tdarr_node/flow.json`

```bash
Input File
    → Run Classic: Migz3CleanAudio (eng,spa,und)
    → Run Classic: Migz4CleanSubs (eng,spa)
    → Begin Command
         → Ensure Audio Stream (en, AAC 6channel 384k bitrate)
         → Ensure Audio Stream (spa, AAC6 channel 384k bitrate)
         → Set Container (mkv)
    → Check Video Codec (hevc)
        → (has hevc) → Execute (Just remux, preserve original video)
                         → Replace Original File
        → (no hevc)  → Check 10 Bit Video
                         → (is 10-bit) → Custom VT Args (-c:v hevc_videotoolbox -q:v 65 -pix_fmt p010le -tag:v hvc1)
                                            → Execute
                                            → Replace Original File
                         → (is 8-bit)  → Custom VT Args (-c:v hevc_videotoolbox -q:v 65 -tag:v hvc1)
                                            → Execute
                                            → Replace Original File
```


### Managing TDARR node
```bash
  # Check status:
  launchctl print gui/$(id -u)/com.tofu-stack.tdarr-node.tanjiro

  # Reload the service (if you made changes to the plist):
  # Unload first
  launchctl bootout gui/$(id -u)/com.tofu-stack.tdarr-node.tanjiro

  # Then load again
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist

  # Stop the service:
  launchctl bootout gui/$(id -u)/com.tofu-stack.tdarr-node.tanjiro

  # Start the service:
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist


```




## Home Assistant Bridge (LaunchAgent)

This setup uses a macOS LaunchAgent to automatically forward traffic from port 8124 to Home Assistant (192.168.1.5:8123) using socat.
The reason we need this is because Traeffik is running on a contianer in orbstack. Orbstack runs containers in a light weight linux VM which shares the
nic with the mac hostmachine. I then have VMWare running homeassistant OS with its own IP of 192.168.1.5, but again sharing the exact same nic as
orbstack. This creates a weird routing problem where the packets between the two cannot be routed. The fix is to add a "socat shim" in between to
route traffic properly.

### Why LaunchAgent?

- **Auto-start on login**: Service starts automatically when you log in
- **Auto-restart**: If socat crashes, launchd will restart it automatically
- **Network-aware**: Waits for network to be ready before starting
- **Persistent**: Survives reboots and continues working

### Setup Instructions

1. **Create the plist file** at `~/Library/LaunchAgents/com.homeassistant.bridge.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homeassistant.bridge</string>

    <key>ProgramArguments</key>
    <array>
        <string>/run/current-system/sw/bin/socat</string>
        <string>TCP-LISTEN:8124,fork,reuseaddr</string>
        <string>TCP:192.168.1.5:8123</string>
    </array>

    <key>KeepAlive</key>
    <dict>
        <key>NetworkState</key>
        <true/>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardErrorPath</key>
    <string>/tmp/ha_bridge.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/ha_bridge.out</string>
</dict>
</plist>
```

2. **Load the LaunchAgent**:

```bash
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist
```

3. **Grant Network Permissions**:
   - macOS will prompt you to allow network connections for socat
   - This is required for the LaunchAgent to work
   - The prompt may appear in System Settings or as a GUI dialog
   - **IMPORTANT**: Without granting this permission, socat will fail with "No route to host" errors

### Management Commands

```bash
# Start the service
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Restart the service
launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist && \
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Check if service is running
launchctl list | grep com.homeassistant.bridge

# View live logs
tail -f /tmp/ha_bridge.err
```


### Architecture

```
Browser → http://192.168.1.2:8124 (Traefik)
    ↓
socat (LaunchAgent)
    ↓
Home Assistant → http://192.168.1.5:8123
```
