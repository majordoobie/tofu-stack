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


## *Arr Stack
The *Arr services that I am using at the time of writting are:

- Prowlarr -- Manage index's
- Radarr -- Manage M media
- Sonarr -- Manage T media
- JellySeer -- Easy Interface for requesting content
- JellyFin -- Backend to view data

### JellySeer
JellySeer is a fork off OverSeer, a friendly web app that makes it easy to view content based on genre and
other filters. All requests made on it will be forwarded to either *radarr* or *sonarr*. They will handle
finding the content through *prowlarr's* indexes.

### *Arr Stack
I have subscripted to NZBGeek and NZBNews for official access to NZB index's. This has been way faster and
consistent than using T.


## VPN GlueTun
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
using a launchd service to run my script at `scripts/gluetun-monitor.sh`. 

I am using a script beacuse using *autoheal* has proven to be unreliable for gluetun since autoheal 
restarts the unhealthy container. This makes the containers that depend on it like *prowlarr* to 
silently die by not having a network connection. They don't throw an unhealthy status 
so *autoheal* does not restart them. 



# TDARR
After using tdarr for a while I realized that I can use VideoToolBox on MacOS. But that means that I need to set the
node worker on the host machine and keep the TDARR server on docker.

```bash
Input File
    → Run Classic: Migz3CleanAudio (eng,spa,und)
    → Run Classic: Migz4CleanSubs (eng,spa)
    → Check Video Codec (hevc)
        → (has hevc) → Begin Command (just remux, no transcode)
                         → Ensure Audio Stream (en, AAC)
                         → Ensure Audio Stream (spa, AAC)
                         → Set Container (mkv)
                         → Execute
                         → Replace Original File
        → (no hevc) → Begin Command (full transcode)
                         → Set Video Encoder (VideoToolbox)
                         → Ensure Audio Stream (en, AAC)
                         → Ensure Audio Stream (spa, AAC)
                         → 10 Bit Video
                         → Set Container (mkv)
                         → Execute
                         → Replace Original File
```




## Storage Architecture (SSD + HDD)

# Configurations

## JellyFin Access

To access my resources remotely I am using Cloudflare tunnels via the [zero trust dashboard](https://one.dash.cloudflare.com/).
The setup integrates with the *cloudflared* tunnel. The container establishes a connection with cloudflare
and routes are added via the zero trust dashboard.

(*.majordoob.com) -> cloudflare.com -> tunnel -> cloudflared -> traefik


## Arr Stack
### Arr Stack Hardware
All the containers are running via [Orbstack](https://orbstack.dev/) on the M2 Mac Mini. There is two harddrives
that are utilized, a SSD and a HDD.

The SDD is used for active downloads (*qbittorrent*, *nzbget*) and transcoding cache (*tdarr*)

The HDD is used to store the finalized media (*jellyfin*)

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
