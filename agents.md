# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Tofu Stack is a media server automation stack (*Arr stack) running on an M2 Mac Mini with dual storage: a 2TB SSD for active downloads/transcoding and a 16TB HDD for media storage. The stack runs in Docker containers orchestrated via docker-compose, with external access secured through Cloudflare Tunnel.

## Common Commands

### Docker Compose Operations

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs for a specific service
docker compose logs -f <service_name>

# Restart a specific service
docker compose restart <service_name>

# Rebuild and restart a service
docker compose up -d --force-recreate <service_name>

# Check service status
docker compose ps
```

### Managing Tdarr Nodes (macOS)

Tdarr nodes run natively on macOS via launchd (not in Docker):

```bash
# Download Tdarr Node binary for this server (Tanjiro)
cd tdarr_node
python3 download-tdarr-node.py tdarr_tanjiro

# Install the LaunchAgent
cp tdarr_node/tdarr_tanjiro/com.tofu-stack.tdarr-node.tanjiro.plist ~/Library/LaunchAgents/

# Start/stop/restart the node
launchctl load ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist

# Check if running
launchctl list | grep tdarr-node

# Manual start (for testing)
cd tdarr_node/tdarr_tanjiro
./tdarr_node/Tdarr_Node
```

### Managing Home Assistant Bridge (socat)

The Home Assistant bridge routes traffic from Traefik (in OrbStack) to Home Assistant VM (VMware):

```bash
# Start/stop/restart the bridge
launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist
launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist

# Check status
launchctl list | grep com.homeassistant.bridge

# View logs
tail -f /tmp/ha_bridge.err
tail -f /tmp/ha_bridge.out
```

## Architecture

### Network Flow

External traffic follows this path:
```
Cloudflare Edge → Cloudflare Tunnel → cloudflared Container → Traefik → Service
```

- TLS terminates at Cloudflare Edge
- Internal traffic uses HTTP (port 80) between cloudflared and Traefik
- Traefik routes based on hostname to appropriate services
- Cloudflare Tunnel routes are configured in Cloudflare Zero Trust Dashboard (not locally)

### VPN Configuration (Gluetun)

Several services route through Gluetun VPN (ProtonVPN with OpenVPN):
- `prowlarr` - uses `network_mode: service:gluetun`
- `qbittorrent` - uses `network_mode: service:gluetun`
- `flaresolverr` - uses `network_mode: service:gluetun`

Services using `network_mode: service:gluetun` have their Traefik routing labels on the gluetun service itself, not on their own service definition.

### Storage Layout

**SSD (Working-Storage)** - Active operations:
```
/Volumes/Working-Storage/
├── downloads/
│   ├── incomplete/
│   ├── nzbget/
│   ├── qbittorrent/
│   └── torrents/
└── tdarr_cache/  # Transcoding workspace
```

**HDD (Plex-Storage)** - Final storage:
```
/Volumes/Plex-Storage/media/
├── downloads/
├── movies/
└── shows/
```

Download workflow:
1. Download client (SABnzbd/qBittorrent) downloads to SSD
2. *Arr service (Radarr/Sonarr) moves completed files to HDD
3. Tdarr picks up from HDD, transcodes on SSD, replaces on HDD

### Service Stack

**Core Infrastructure:**
- `traefik` - Reverse proxy with SSL (ports 80, 443, 8888)
- `cloudflared` - Cloudflare Tunnel client
- `gluetun` - VPN tunnel (ProtonVPN)
- `autoheal` - Monitors and restarts unhealthy containers

**Media Management (*Arr):**
- `prowlarr` - Indexer manager (port 9696, via Gluetun)
- `radarr` - Movie management (port 7878)
- `sonarr` - TV show management (port 8989)
- `overseerr` - Media request UI (port 5055)

**Download Clients:**
- `qbittorrent` - Torrent client (port 8080, via Gluetun)
- `sabnzbd` - Usenet client (port 8085)

**Transcoding:**
- `tdarr` - Media transcoding server (ports 8265, 8266)
- Tdarr nodes run natively via launchd (see tdarr_node/ directory)

**Monitoring:**
- `tautulli` - Plex statistics (port 8181)
- `homepage` - Dashboard (port 3000)
- `flaresolverr` - Cloudflare protection bypass (port 8191, via Gluetun)

### Tdarr Transcoding Workflow

Tdarr flow is defined in `tdarr_node/flow.json`:

1. Clean audio tracks (keep only eng, spa, und)
2. Clean subtitles (keep only eng, spa)
3. Ensure AAC 6-channel 384k audio streams exist for English and Spanish
4. Check video codec:
   - If already HEVC: remux only
   - If H.264:
     - 10-bit source → encode with `-c:v hevc_videotoolbox -q:v 65 -pix_fmt p010le -tag:v hvc1`
     - 8-bit source → encode with `-c:v hevc_videotoolbox -q:v 65 -tag:v hvc1`
5. Replace original file

Important: Maintains source bit depth (8-bit or 10-bit) as forcing 10-bit on 8-bit source provides no quality benefit.

**Current Tdarr flow (2026-01-27):**
- Flow trimmed to remux-only for cleanup, not video transcode.
- Order: `denix_remuxer` → `denix_subtitle_cleaner` → `Keep Eng + Spa Audio` → `denix_reorder` → `replaceOriginalFile`.
- `denix_remuxer` has `reorder_streams=false` (ordering handled by `denix_reorder`).
- `denix_reorder` default audio order: `eng 6,eng 2,spa 6,spa 2`.
- Chapters are removed (`remove_chapters=true`).

## Important Configurations

### Secrets Management

Secrets are stored in `tofu-stack-secrets/` (git submodule):
- `openvpn_user.txt`, `openvpn_pass.txt` - VPN credentials
- `cloudflare_tunnel_key.txt` - Cloudflare tunnel token
- `nzbget_user.txt`, `nzbget_pass.txt` - NZBGet credentials (deprecated)
- `gluten_auth_config.toml` - Gluetun auth config
- Traefik configs and certificates

Never commit secrets to the main repository.

### Container Health Monitoring

Containers marked with `autoheal=true` label are monitored:
- `gluetun` - Tests VPN connectivity with ping
- `qbittorrent`, `prowlarr`, `flaresolverr` - Depend on Gluetun health

Note: `autoheal` uses `docker restart` (not `docker compose restart`), so it doesn't respect `depends_on` restart conditions.

### Home Assistant Bridge Configuration

Traefik (in OrbStack VM) cannot directly route to Home Assistant (VMware VM, 192.168.1.5:8123) even though both share the Mac's NIC. Solution: socat shim on macOS host forwards port 8124 → 192.168.1.5:8123.

**Critical Configuration:**
- Traefik service config in `tofu-stack-secrets/traefik-dynamic.yml` MUST use `http://host.docker.internal:8124`
- Do NOT configure Traefik to connect directly to `http://192.168.1.5:8123` (will fail with "No route to host")
- The socat bridge runs via launchd at `~/Library/LaunchAgents/com.homeassistant.bridge.plist`

**Permissions Requirement:**
- macOS requires granting network permissions to socat binary at `/run/current-system/sw/bin/socat`
- Without permissions, socat fails with "No route to host" errors
- Grant permissions: System Settings → Privacy & Security → Full Disk Access → Add socat binary
- Restart bridge after granting: `launchctl unload ~/Library/LaunchAgents/com.homeassistant.bridge.plist && launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist`

**Troubleshooting:**
- Check bridge logs: `tail -f /tmp/ha_bridge.err`
- Test bridge locally: `curl -I http://localhost:8124`
- Verify bridge process: `launchctl list | grep homeassistant.bridge`
- Check if HA VM is reachable: `ping 192.168.1.5` (from macOS host, not Docker)
- If Traefik returns 502: restart Traefik after bridge is working

## Development Notes

### Making Changes to Services

When modifying `docker-compose.yml`:
1. Use `docker compose config` to validate syntax
2. Apply changes with `docker compose up -d` (recreates only changed services)
3. Check logs: `docker compose logs -f <service_name>`

### Accessing Services

**Local access** (`.home.arpa`):
- Traefik handles HTTPS with self-signed certs
- Services accessible via `<service>.home.arpa`

**External access** (`.majordoob.com`):
- Routes through Cloudflare Tunnel
- Configured in Cloudflare Zero Trust Dashboard
- Uses HTTP between cloudflared and Traefik (TLS already terminated)

### Working with Gluetun-routed Services

Services using `network_mode: service:gluetun`:
- Cannot have their own `ports` mapping
- Ports must be exposed on gluetun service
- Traefik labels must be on gluetun service
- Must wait for gluetun to be healthy: `depends_on: gluetun: condition: service_healthy`

### Debugging VPN Issues

If Gluetun becomes unhealthy:
1. Check VPN connection: `docker compose logs gluetun`
2. Test connectivity: `docker compose exec gluetun ping 8.8.8.8`
3. Autoheal will restart if failing health checks
4. Services dependent on Gluetun will restart when Gluetun recovers (due to `restart: true`)

### Tdarr Multi-Node Setup

- `tdarr` container runs the server
- Nodes run natively via launchd for better hardware access
- `tdarr_tanjiro/` - Mac Mini node config
- `tdarr_nezuko/` - Laptop node config (requires SMB mounts and path translation)
- Node binaries are downloaded via `download-tdarr-node.py`
- Each node has independent `configs/Tdarr_Node_Config.json`
