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
