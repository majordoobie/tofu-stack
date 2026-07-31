#!/bin/bash
#
# boot-gate.sh - Ordered, condition-gated startup for the tofu-stack host.
#
# Problem this solves: on reboot, macOS autologins and fires login items in
# parallel. OrbStack becomes ready and starts 19 containers with
# `restart: unless-stopped` before the external USB volumes have mounted, and
# VMware starts the Home Assistant VM before its USB Zigbee dongle is attached.
#
# This script replaces that race with an explicit sequence, gated on conditions
# rather than fixed sleeps (a fixed delay is still a race you can lose):
#
#   1. Mount both external volumes by UUID, retrying until they appear
#   2. Verify each is the REAL drive via a sentinel file, not a stub directory
#   3. Wait for the Docker engine to answer
#   4. Bring up the compose stack
#   5. Start the Home Assistant VM
#   6. Verify the stack and the HA bridge actually answer
#
# Usage:
#   boot-gate.sh            # normal boot sequence (run by LaunchAgent at login)
#   boot-gate.sh --check    # READ-ONLY. Verifies state, changes nothing. Safe anytime.
#   boot-gate.sh --force    # run the sequence even if the stack is already up
#
# NOTE: `set -e` is deliberately omitted. This script retries by design, and a
# non-zero result from a probe must not abort the run.
set -uo pipefail

# launchd starts agents with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin). `docker`
# lives in /usr/local/bin, so without this the engine probe silently fails under
# launchd and the stack never starts - a bug that only shows up on a real reboot.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- configuration -------------------------------------------------------------------
readonly STACK_DIR="/Users/tanjiro/containers/tofu-stack"
readonly LOG="/tmp/tofu_boot_gate.log"
readonly SENTINEL=".tofu-volume-ok"

readonly PLEX_MNT="/Volumes/Plex-Storage"
readonly PLEX_UUID="626594D1-CFA1-4EA5-95E8-00B02F9956A1"
readonly WORK_MNT="/Volumes/Working-Storage"
readonly WORK_UUID="B2E258B8-6B69-4D0D-A821-F58C44131502"

readonly VMRUN="/Applications/VMware Fusion.app/Contents/Library/vmrun"
readonly VMX="/Users/tanjiro/Virtual Machines.localized/Homeassistant-OS.vmwarevm/Homeassistant-OS.vmx"

readonly HA_BRIDGE_URL="http://127.0.0.1:8124/"
readonly HA_VM_URL="http://192.168.1.5:8123/"

# Timeouts in seconds. Generous on purpose: a slow USB enumeration should delay
# startup, never skip it.
readonly VOLUME_TIMEOUT=240
readonly DOCKER_TIMEOUT=240
readonly VM_TIMEOUT=180
readonly HA_TIMEOUT=240
readonly POLL_INTERVAL=5

MODE="boot"
[ "${1:-}" = "--check" ] && MODE="check"
[ "${1:-}" = "--force" ] && MODE="force"
readonly MODE

FAILURES=0

# --- helpers -------------------------------------------------------------------------
log() {
  printf '%s [boot-gate] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

fail() {
  log "FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

# True if $1 is an actual mount point (not just an existing directory).
is_mounted() {
  /sbin/mount | grep -q " on ${1} ("
}

# True if $1 is mounted AND carries the sentinel file. The sentinel is what
# distinguishes the real drive from an empty directory that something else
# (usually Docker) created at the mount path while the drive was absent.
volume_ready() {
  is_mounted "$1" && [ -f "${1}/${SENTINEL}" ]
}

# --- step 1+2: volumes ---------------------------------------------------------------
ensure_volume() {
  local mnt="$1" uuid="$2" name="$3"
  local deadline=$((SECONDS + VOLUME_TIMEOUT))

  if volume_ready "$mnt"; then
    log "$name: already mounted and verified"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    if is_mounted "$mnt"; then
      fail "$name: mounted but sentinel ${SENTINEL} missing"
    else
      fail "$name: NOT mounted"
    fi
    return 1
  fi

  while [ "$SECONDS" -lt "$deadline" ]; do
    # Clear a stub directory left at the mount point by something that ran too
    # early. Only ever remove it if it is empty and not a mount - rmdir refuses
    # anything else, so this cannot eat real data.
    if [ -d "$mnt" ] && ! is_mounted "$mnt"; then
      if rmdir "$mnt" 2>/dev/null; then
        log "$name: removed empty stub directory at $mnt"
      fi
    fi

    if ! is_mounted "$mnt"; then
      log "$name: attempting diskutil mount $uuid"
      diskutil mount "$uuid" >>"$LOG" 2>&1
    fi

    if volume_ready "$mnt"; then
      log "$name: mounted and verified at $mnt"
      return 0
    fi

    if is_mounted "$mnt"; then
      fail "$name: mounted at $mnt but sentinel missing - refusing to continue"
      return 1
    fi

    sleep "$POLL_INTERVAL"
  done

  fail "$name: not mounted after ${VOLUME_TIMEOUT}s"
  return 1
}

# --- step 3: docker engine -----------------------------------------------------------
ensure_docker() {
  if docker info >/dev/null 2>&1; then
    log "docker: engine already responding"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    fail "docker: engine not responding"
    return 1
  fi

  log "docker: starting OrbStack"
  open -ga OrbStack >>"$LOG" 2>&1

  local deadline=$((SECONDS + DOCKER_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker info >/dev/null 2>&1; then
      log "docker: engine ready"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done

  fail "docker: engine not ready after ${DOCKER_TIMEOUT}s"
  return 1
}

# --- step 4: compose stack -----------------------------------------------------------
start_stack() {
  cd "$STACK_DIR" || { fail "cannot cd to $STACK_DIR"; return 1; }

  if ! docker compose config >/dev/null 2>&1; then
    fail "docker-compose.yml is invalid - not starting the stack"
    return 1
  fi

  local running
  running=$(docker compose ps -q 2>/dev/null | grep -c . || true)

  if [ "$MODE" = "check" ]; then
    log "stack: $running container(s) currently running (check mode, not touching)"
    return 0
  fi

  # Guard against clobbering live work. `docker compose up -d` recreates any
  # container whose config hash differs, and this host currently has containers
  # built by an older Compose version, so a stray run would recreate ~26 of them
  # mid-flight. At boot that is correct; at any other time it is destructive.
  if [ "$running" -gt 0 ] && [ "$MODE" != "force" ]; then
    log "stack: $running container(s) already running - skipping 'up -d'"
    log "stack: re-run with --force if you intend to apply compose changes now"
    return 0
  fi

  log "stack: docker compose up -d"
  docker compose up -d >>"$LOG" 2>&1 || { fail "docker compose up -d failed"; return 1; }
  log "stack: up"
}

# --- step 5: home assistant VM -------------------------------------------------------
start_vm() {
  if [ ! -x "$VMRUN" ]; then
    fail "vmrun not found at $VMRUN"
    return 1
  fi

  if "$VMRUN" -T fusion list 2>/dev/null | grep -qF "$VMX"; then
    log "vm: Home Assistant already running"
    return 0
  fi

  if [ "$MODE" = "check" ]; then
    fail "vm: Home Assistant NOT running"
    return 1
  fi

  log "vm: starting Home Assistant"
  "$VMRUN" -T fusion start "$VMX" nogui >>"$LOG" 2>&1

  local deadline=$((SECONDS + VM_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$VMRUN" -T fusion list 2>/dev/null | grep -qF "$VMX"; then
      log "vm: Home Assistant started"
      return 0
    fi
    sleep "$POLL_INTERVAL"
  done

  fail "vm: did not start within ${VM_TIMEOUT}s"
  return 1
}

# --- step 6: verification ------------------------------------------------------------
http_ok() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null)" = "200" ]
}

verify() {
  local deadline=$((SECONDS + HA_TIMEOUT))

  if [ "$MODE" = "check" ]; then
    http_ok "$HA_VM_URL" && log "verify: HA VM 200" || fail "verify: HA VM not answering"
    http_ok "$HA_BRIDGE_URL" && log "verify: HA bridge 200" || fail "verify: HA bridge not answering"
  else
    while [ "$SECONDS" -lt "$deadline" ]; do
      http_ok "$HA_VM_URL" && break
      sleep "$POLL_INTERVAL"
    done
    http_ok "$HA_VM_URL" && log "verify: HA VM 200" || fail "verify: HA VM not answering"

    # The bridge is its own LaunchAgent; kick it if HA came up after it did.
    if ! http_ok "$HA_BRIDGE_URL"; then
      log "verify: bridge not answering, restarting com.homeassistant.bridge"
      launchctl kickstart -k "gui/$(id -u)/com.homeassistant.bridge" >>"$LOG" 2>&1
      sleep "$POLL_INTERVAL"
    fi
    http_ok "$HA_BRIDGE_URL" && log "verify: HA bridge 200" || fail "verify: HA bridge not answering"
  fi

  local unhealthy
  unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  [ -n "$unhealthy" ] && fail "verify: unhealthy containers: $unhealthy" || log "verify: no unhealthy containers"
}

# --- main ----------------------------------------------------------------------------
log "=== boot-gate start (mode=$MODE) ==="

ensure_volume "$PLEX_MNT" "$PLEX_UUID" "Plex-Storage"
plex_ok=$?
ensure_volume "$WORK_MNT" "$WORK_UUID" "Working-Storage"
work_ok=$?

# Containers bind-mount both volumes. Starting the stack without them is the
# exact failure this script exists to prevent, so this is a hard stop.
if [ "$plex_ok" -ne 0 ] || [ "$work_ok" -ne 0 ]; then
  fail "one or more volumes unavailable - NOT starting containers"
else
  ensure_docker && start_stack
fi

start_vm
verify

if [ "$FAILURES" -eq 0 ]; then
  log "=== boot-gate complete: OK ==="
  exit 0
fi

log "=== boot-gate complete: $FAILURES failure(s) ==="
exit 1
