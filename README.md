# Tofu Stack
Tofu Stack is a Arr stack that runs on a M2 Mac Mini with 2 extral drives. A 2TB SSD where active download
and transcoding take placed. And a 16TB HDD where media is stored.

## Cloudflare Access
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

# Check if service is running
launchctl list | grep com.homeassistant.bridge

# View live logs
tail -f /tmp/ha_bridge.err
```


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
