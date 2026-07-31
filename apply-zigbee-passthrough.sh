#!/bin/bash
#
# apply-zigbee-passthrough.sh - Pin the Home Assistant Connect ZBT-1 Zigbee dongle
# to the HA VM so VMware reattaches it on every power-on, ON A CONTROLLER THE ARM
# GUEST CAN ACTUALLY SEE.
#
# Two separate problems, both handled here:
#
#   1. No binding at all. Homeassistant-OS.vmx originally contained NO entry for
#      the dongle (only two hubs and an HID). VMware only writes USB bindings to
#      the vmx on power-off, so a manual "connect" in the Fusion UI is runtime-only
#      state, lost on the next boot.
#
#   2. Bound to the WRONG CONTROLLER (found 2026-07-31). Adding only
#      usb.autoConnect.device0 attaches the dongle to the legacy UHCI controller
#      (virtPath:usb:0) because the ZBT-1 is a `speed:full` device and VMware
#      routes full-speed devices to UHCI whenever it is present. This guest is
#      arm-other5xlinux-64 (HA OS aarch64) and does NOT enumerate the x86-era
#      UHCI/EHCI controllers, so the dongle attached at the VMware layer -
#      ownerdisplay got set, the log looked healthy - while the guest never saw a
#      USB device at all. ZHA failed with:
#        [Errno 2] No such file or directory: '/dev/serial/by-id/usb-Nabu_Casa_...'
#      Fix: disable UHCI+EHCI so full-speed devices have nowhere to land but xHCI,
#      and add an xHCI-scoped autoConnect entry.
#
# Device: "Home Assistant Connect ZBT-1" by Nabu Casa
#   idVendor  4292  = 0x10C4 (Silicon Labs)
#   idProduct 60000 = 0xEA60 (CP210x UART bridge)
#
# VMware requires the VM to be POWERED OFF before editing the vmx, otherwise the
# running VM overwrites the file on shutdown and the change is silently lost.
#
# Usage: apply-zigbee-passthrough.sh
set -uo pipefail

readonly VMRUN="/Applications/VMware Fusion.app/Contents/Library/vmrun"
readonly VMX="/Users/tanjiro/Virtual Machines.localized/Homeassistant-OS.vmwarevm/Homeassistant-OS.vmx"
readonly PATTERN='vid:10c4 pid:ea60'

if [ ! -f "$VMX" ]; then
  echo "ERROR: vmx not found at $VMX" >&2
  exit 1
fi

# Hard stop if the VM is running - editing now would be discarded on shutdown.
if "$VMRUN" -T fusion list 2>/dev/null | grep -qF "$VMX"; then
  echo "ERROR: the Home Assistant VM is RUNNING." >&2
  echo "       Shut it down first, then re-run this script:" >&2
  echo "         '$VMRUN' -T fusion stop '$VMX' soft" >&2
  exit 1
fi

readonly BACKUP="${VMX}.bak.$(date +%Y%m%d%H%M%S)"
cp "$VMX" "$BACKUP" || { echo "ERROR: backup failed" >&2; exit 1; }
echo "Backed up vmx -> $BACKUP"

# set_key <key> <value> - replace the line if the key exists, else append it.
set_key() {
  local key="$1" val="$2" line
  line="${key} = \"${val}\""
  if grep -q "^${key} = " "$VMX"; then
    # Match only the exact key; '.' is escaped so usb.present cannot match usbXpresent.
    local esc="${key//./\\.}"
    sed -i '' "s|^${esc} = .*|${line}|" "$VMX" || return 1
  else
    printf '%s\n' "$line" >>"$VMX" || return 1
  fi
}

# Force every USB device onto xHCI - the only controller this ARM guest enumerates.
set_key "usb.present" "FALSE" || { echo "ERROR: write failed" >&2; exit 1; }
set_key "ehci.present" "FALSE" || { echo "ERROR: write failed" >&2; exit 1; }
set_key "usb_xhci.present" "TRUE" || { echo "ERROR: write failed" >&2; exit 1; }

# Autoconnect the dongle. The xHCI-scoped key is the one that matters; the legacy
# key is kept as a harmless fallback for older Fusion builds.
set_key "usb_xhci.autoConnect.device0" "$PATTERN" || { echo "ERROR: write failed" >&2; exit 1; }
set_key "usb.autoConnect.device0" "$PATTERN" || { echo "ERROR: write failed" >&2; exit 1; }

echo
echo "USB config now:"
grep -nE '^(usb|ehci|usb_xhci)\.(present|autoConnect\.device0) = ' "$VMX"
echo
echo "Next: power the VM on, then confirm the dongle landed on xHCI - NOT usb:N:"
echo "  grep -i 'ZBT-1' '$(dirname "$VMX")/vmware.log' | tail -2 | grep -o 'virtPath:[a-z_0-9:]*'"
echo "  -> want virtPath:usb_xhci:N   (virtPath:usb:0 means the guest will NOT see it)"
echo
echo "Then check ZHA in Home Assistant. A bare 'device is connected' in vmware.log"
echo "is NOT sufficient - it reports attachment, not which controller."
