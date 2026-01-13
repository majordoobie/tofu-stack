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

Downloads and transcoding happen on the SSD (`/Volumes/Working-Storage`) to avoid I/O contention with Plex playback from the HDD (`/Volumes/Plex-Storage`).

### Service File Flow

| Service | Reads From | Writes To | Notes |
|---------|------------|-----------|-------|
| **qBittorrent** | - | `/working/qbittorrent/completed/` (SSD) | Downloads land here |
| **NZBGet** | - | `/working/nzbget/completed/` (SSD) | Downloads land here |
| **Radarr** | `/working/.../completed/` (SSD) | `/data/movies/` (HDD) | Imports & moves to library |
| **Sonarr** | `/working/.../completed/` (SSD) | `/data/shows/` (HDD) | Imports & moves to library |
| **Tdarr** | `/media/` (HDD) | `/media/` (HDD) | Transcodes in-place, cache on SSD (`/temp`) |
| **Plex** (host) | `/Volumes/Plex-Storage/media/` (HDD) | - | Read-only media serving (native macOS) |

### Container Mount Summary

| Container | `/working` | `/data` | `/media` | `/temp` |
|-----------|------------|---------|----------|---------|
| qBittorrent | SSD | HDD | - | - |
| NZBGet | SSD | HDD | - | - |
| Radarr | SSD | HDD | - | - |
| Sonarr | SSD | HDD | - | - |
| Tdarr | - | - | HDD | SSD |
| Plex | - | - | - | - |

*Plex runs on the host (not in Docker) and accesses media directly from `/Volumes/Plex-Storage/media/`*

### Data Flow
```
Download → SSD → Radarr/Sonarr import → HDD → Plex serves
                                      ↓
                               Tdarr transcodes (cache on SSD)
```

---

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

### Troubleshooting

#### Check Service Status
```bash
# Check if service is loaded and running
launchctl list | grep com.homeassistant.bridge
# Output: PID (if running) or "-" (if stopped), exit code, service name
```

#### Check Logs
```bash
# View error logs
cat /tmp/ha_bridge.err

# View stdout (usually empty for socat)
cat /tmp/ha_bridge.out
```

#### Common Issues

**"No route to host" errors:**
- **Cause**: macOS network permissions not granted
- **Solution**: Check System Settings > Privacy & Security > Network
- Look for socat or the LaunchAgent in the network permissions list
- Grant permission if denied

**Port already in use:**
```bash
# Find what's using port 8124
lsof -nP -iTCP:8124

# Kill the process if needed
kill <PID>
```

**Service won't start after reboot:**
- Ensure the plist file is in the correct location: `~/Library/LaunchAgents/`
- Check file permissions: `ls -la ~/Library/LaunchAgents/com.homeassistant.bridge.plist`
- Should be readable by your user

**Connection works manually but not via LaunchAgent:**
- This is usually a permissions issue
- Unload and reload the agent to trigger the permissions prompt again
- Check logs in `/tmp/ha_bridge.err` for specific errors

### Testing the Connection

```bash
# Test from localhost
curl -I http://localhost:8124

# Test from LAN IP
curl -I http://192.168.1.2:8124

# Should return HTTP 405 (HEAD not allowed) or 200 OK
```

### Architecture

```
Browser → http://192.168.1.2:8124 (Traefik)
    ↓
socat (LaunchAgent)
    ↓
Home Assistant → http://192.168.1.5:8123
```

---

## Gluetun Monitor (LaunchAgent)

This LaunchAgent monitors the gluetun VPN container and automatically restarts the VPN stack when issues are detected. It uses `docker compose` instead of the Docker API to properly trigger the dependency chain and restart all dependent containers.

### Why This Exists

When gluetun restarts, containers using `network_mode: service:gluetun` (qbittorrent, prowlarr, flaresolverr) lose their network and exit. The `autoheal` container only monitors "unhealthy" containers, not "exited" ones, so these containers would stay dead until manually restarted.

This monitor solves that by:
1. Detecting when gluetun becomes unhealthy
2. Detecting when dependent containers have exited
3. Using `docker compose up -d --force-recreate` to restart everything properly

### Setup

The LaunchAgent plist is at `~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist` and runs the script at `scripts/gluetun-monitor.sh`.

**Load the service:**
```bash
launchctl load ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist
```

### Management Commands

```bash
# Check if service is running
launchctl list | grep gluetun-monitor

# View logs
tail -f ~/containers/tofu-stack/logs/gluetun-monitor.log

# Stop the service
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist

# Start the service
launchctl load ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist

# Restart the service
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist && \
launchctl load ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist
```

### How It Works

1. **Health Check Loop** (every 60 seconds):
   - Checks if any dependent containers (qbittorrent, prowlarr, flaresolverr) are exited
   - Checks if gluetun is unhealthy

2. **Exited Containers** (gluetun healthy):
   - Runs `docker compose up -d qbittorrent prowlarr flaresolverr` to restart them

3. **Gluetun Unhealthy** (3 consecutive failures):
   - Runs `docker compose up -d gluetun --force-recreate`
   - Waits for gluetun to become healthy
   - Runs `docker compose up -d qbittorrent prowlarr flaresolverr --force-recreate`

### Log Output Example

```
2026-01-03 17:15:20 - WARNING: flaresolverr is exited
2026-01-03 17:15:20 - Restarting exited dependent containers...
2026-01-03 17:15:28 - Dependent containers restarted
2026-01-03 17:15:28 - Gluetun recovered (was unhealthy for 1 checks)
```

### Troubleshooting

**Service not running after reboot:**
- Verify plist exists: `ls -la ~/Library/LaunchAgents/com.tofu-stack.gluetun-monitor.plist`
- Check for errors: `cat ~/containers/tofu-stack/logs/gluetun-monitor-stderr.log`

**Containers still not restarting:**
- Check the monitor log: `tail -20 ~/containers/tofu-stack/logs/gluetun-monitor.log`
- Verify docker compose works: `cd ~/containers/tofu-stack && docker compose ps`

---

