#!/usr/bin/env python3

"""
Script to download the latest Tdarr Node for macOS ARM (M series)
Usage: python3 download-tdarr-node.py <destination_directory>
"""

import json
import os
import sys
import urllib.request
import zipfile
from pathlib import Path


# Colors for output
class Colors:
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED = "\033[0;31m"
    NC = "\033[0m"


def print_color(color, message):
    print(f"{color}{message}{Colors.NC}")


def parse_version(version_str):
    """Convert version string like '2.58.02' to tuple of ints (2, 58, 2) for comparison"""
    return tuple(int(part) for part in version_str.split("."))


def main():
    # Destination directory from argument or default
    if len(sys.argv) > 1:
        dest_dir = sys.argv[1]
    else:
        print_color(Colors.YELLOW, "Usage: python3 download-tdarr-node.py <destination_directory>")
        print_color(Colors.YELLOW, "Defaulting to './tdarr_node'")
        dest_dir = "./tdarr_node"
        
    dest_path = Path(dest_dir).resolve()

    print_color(Colors.GREEN, "Tdarr Node Downloader for macOS ARM")
    print("=" * 48)

    # Fetch versions.json
    print_color(Colors.YELLOW, "Fetching latest version information...")
    try:
        with urllib.request.urlopen("https://storage.tdarr.io/versions.json") as response:
            versions_data = json.loads(response.read().decode())
    except Exception as e:
        print_color(Colors.RED, f"Error fetching versions.json: {e}")
        sys.exit(1)

    # Get latest version by sorting version numbers
    version_list = list(versions_data.keys())
    version_list.sort(key=parse_version, reverse=True)
    latest_version = version_list[0]

    print_color(Colors.GREEN, f"Latest version: {latest_version}")

    # Get download URL for macOS ARM (darwin_arm64)
    platform = "darwin_arm64"
    try:
        download_url = versions_data[latest_version][platform]["Tdarr_Node"]
    except KeyError:
        print_color(Colors.RED, f"Error: Could not find download URL for {platform}")
        sys.exit(1)

    print_color(Colors.YELLOW, f"Download URL: {download_url}")

    # Create destination directory
    dest_path.mkdir(parents=True, exist_ok=True)

    # Download the file
    zip_path = Path("/tmp/Tdarr_Node.zip")
    print_color(Colors.YELLOW, f"Downloading Tdarr Node {latest_version} for {platform}...")

    try:
        urllib.request.urlretrieve(download_url, zip_path)
    except Exception as e:
        print_color(Colors.RED, f"Error downloading file: {e}")
        sys.exit(1)

    print_color(Colors.GREEN, "Download complete!")

    # Extract the archive
    print_color(Colors.YELLOW, f"Extracting to {dest_path}...")
    try:
        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            zip_ref.extractall(dest_path)
    except Exception as e:
        print_color(Colors.RED, f"Error extracting archive: {e}")
        sys.exit(1)

    # Make the binary executable
    # The zip usually contains a folder named Tdarr_Node or places files directly
    executable_found = False
    for binary_path in [dest_path / "Tdarr_Node", dest_path / "Tdarr_Node" / "Tdarr_Node"]:
        if binary_path.is_file():
            os.chmod(binary_path, 0o755)
            print_color(Colors.GREEN, f"Made {binary_path} executable")
            executable_found = True
            break
            
    if not executable_found:
        print_color(Colors.YELLOW, "Warning: Tdarr_Node binary not found in expected locations.")

    # Clean up
    zip_path.unlink()

    print()
    print_color(Colors.GREEN, f"✓ Tdarr Node {latest_version} installed successfully!")
    print()
    print(f"Installation location: {dest_path}")
    print()
    print("To start the node:")
    print(f"  cd {dest_path}")
    print("  ./Tdarr_Node (if located here)")
    print()
    print("First-time setup:")
    print("  1. The node will create configs/Tdarr_Node_Config.json on first run")
    print("  2. Edit the config to set serverURL: http://localhost:8266")
    print("  3. Configure path translators for /media/ and /temp/")
    print("  4. Restart the node")


if __name__ == "__main__":
    main()