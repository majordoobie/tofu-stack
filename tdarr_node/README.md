# Running Tdarr Nodes

This directory contains configurations for different Tdarr nodes.

- `tdarr_tanjiro/`: Configuration for the node running on this Mac Mini.
- `tdarr_nezuko/`: Configuration for the node running on the laptop.

## Downloading the Node Binary

Use the shared python script to download and extract the Tdarr Node binary into a specific directory:

### For this server (Tanjiro):
```bash
python3 download-tdarr-node.py tdarr_tanjiro
```

### For the laptop (Nezuko):
Copy the `tdarr_nezuko` folder to your laptop and run:
```bash
python3 download-tdarr-node.py tdarr_nezuko
```

## Running the Node (Tanjiro)

### Option 1: Auto-Start with launchd (Recommended)

1. Copy the plist to your user LaunchAgents:
```bash
cp tdarr_node/tdarr_tanjiro/com.tofu-stack.tdarr-node.tanjiro.plist ~/Library/LaunchAgents/
```

2. Load and start the service:
```bash
launchctl load ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist
```

### Option 2: Manual Start

```bash
cd tdarr_node/tdarr_tanjiro
./tdarr_node/Tdarr_Node
```

## Configuration

Each node has its own config in `configs/Tdarr_Node_Config.json` within its respective directory.

Key settings for network nodes (Laptop):
- **serverIP**: Should be set to the Mac Mini's local IP (e.g., `192.168.1.XX`).
- **pathTranslators**: Ensure these match the SMB mount points on your laptop.