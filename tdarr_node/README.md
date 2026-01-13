# Running a Tdarr node

## Downloading
Use the python script to download the tdarr_node

```bash
python3 download-tdarr-node.py
```

That will download the node to `./tdarr_node/`

## Running the Node

The Tdarr_Node binary automatically daemonizes (runs in background) when started. You have two options for managing it:

### Option 1: Manual Start/Stop

**Start the node:**
```bash
cd ~/containers/tofu-stack/tdarr_node
./tdarr_node/Tdarr_Node
```

**Check if running:**
```bash
ps aux | grep "[T]darr_Node"
```

**Stop the node:**
```bash
pkill -f "Tdarr_Node"
```

**View logs:**
```bash
tail -f ~/containers/tofu-stack/tdarr_node/logs/Tdarr_Node_Log.txt
```

**Note:** Ctrl+C will NOT stop the node because it detaches from the terminal. You must use `pkill` to stop it.

### Option 2: Auto-Start with launchd (Recommended)

For automatic startup at login and auto-restart on crashes, use the launchd service.

**Install the service:**
```bash
# Copy plist to LaunchAgents directory
cp ~/containers/tofu-stack/tdarr_node/com.tofu-stack.tdarr-node.plist ~/Library/LaunchAgents/

# Load and start the service
launchctl load ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
```

**Check service status:**
```bash
launchctl list | grep tdarr
```

**Stop the service:**
```bash
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
```

**Restart the service:**
```bash
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
launchctl load ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
```

**View logs:**
```bash
# Tdarr's own logs
tail -f ~/containers/tofu-stack/tdarr_node/logs/Tdarr_Node_Log.txt

# launchd stdout/stderr
tail -f ~/containers/tofu-stack/tdarr_node/logs/tdarr_node.log
tail -f ~/containers/tofu-stack/tdarr_node/logs/tdarr_node_error.log
```

**Uninstall the service:**
```bash
launchctl unload ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
rm ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.plist
```

## Configuration

The node configuration is in `./configs/Tdarr_Node_Config.json`. Key settings:

- **nodeName**: Identifies this node in the Tdarr server UI
- **serverURL**: Points to the Tdarr server (Docker container on port 8266)
- **pathTranslators**: Maps Docker container paths to native macOS paths
  - `/media` → `/Volumes/Plex-Storage/media` (media library)
  - `/temp` → `/Volumes/Working-Storage/tdarr_cache` (transcode cache on SSD)

## VideoToolbox Hardware Encoding

This node runs natively on macOS to access VideoToolbox for hardware-accelerated H.265/HEVC encoding.

**Verify VideoToolbox is working:**
```bash
# Start the node and check logs
tail -f ~/containers/tofu-stack/tdarr_node/logs/Tdarr_Node_Log.txt | grep -i videotoolbox
```

You should see:
```
h264_videotoolbox-true-true,hevc_videotoolbox-true-true
```

## Troubleshooting

**Multiple nodes showing in Tdarr UI:**
- You likely started the node multiple times. Kill all instances and restart:
  ```bash
  pkill -f "Tdarr_Node"
  sleep 5
  ./tdarr_node/Tdarr_Node
  ```

**FFprobe errors:**
- Make sure ffprobe is executable:
  ```bash
  chmod +x ./tdarr_node/assets/app/ffmpeg/darwin_arm64/ffprobe
  ```

**Node not connecting to server:**
- Verify server is running: `docker compose ps tdarr`
- Check serverURL in config: `cat ./configs/Tdarr_Node_Config.json | grep serverURL`
- Check logs: `tail -50 ./logs/Tdarr_Node_Log.txt`
