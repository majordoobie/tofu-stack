#!/bin/sh
# qbit-watchdog — keeps qBittorrent alive AND reachable through gluetun.
#
# Runs in the docker:cli container (busybox sh, docker socket mounted).
#   1. Starts qBittorrent if it has exited.
#   2. Restarts qBittorrent if its listener vanished from gluetun's netns (orphaned).
#   3. Every ~5 min, connects to <gluetun public IP>:<forwarded port> from OUTSIDE the
#      VPN — the exact address trackers hand to peers. ProtonVPN servers often forward
#      the port on a different IP than egress (see AGENTS.md), which leaves qBittorrent
#      unreachable and racks up IPTorrents hit-and-runs. After 3 consecutive failures
#      it reconnects the VPN (gluetun + qbittorrent, always together).
set -u

REACH_EVERY=5            # loop iterations (60 s each) between reachability checks
REACH_FAILS_MAX=3        # consecutive failures before reconnecting (~15 min)
RECONNECT_COOLDOWN=1800  # never reconnect more than once per 30 min

log() { echo "[$(date -Iseconds)] $*"; }

reconnect_vpn() {
  log "reconnecting VPN: restarting gluetun, then qbittorrent"
  docker restart gluetun >/dev/null || { log "gluetun restart failed"; return; }
  i=0
  while [ "$i" -lt 40 ]; do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null)" = healthy ] &&
      docker exec gluetun test -s /tmp/gluetun/forwarded_port; then
      break
    fi
    i=$((i + 1))
    sleep 3
  done
  docker restart qbittorrent >/dev/null || log "qbittorrent restart failed"
  sleep 15
  docker exec qbittorrent /usr/local/bin/sync-qbittorrent-port.sh >/dev/null 2>&1 ||
    log "port sync failed (ofelia retries every 5 min)"
  server=$(docker logs gluetun 2>&1 | grep 'Peer Connection Initiated' | tail -1 |
    grep -o 'node-[a-z0-9-]*')
  log "reconnected to ${server:-unknown server}"
}

loops=0
fails=0
last_reconnect=0

while true; do
  state=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null || echo missing)
  if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
    log "qbittorrent state=$state, starting"
    docker start qbittorrent || log "start failed"
  elif [ "$state" = "running" ]; then
    gluetun_state=$(docker inspect -f '{{.State.Status}}' gluetun 2>/dev/null || echo missing)
    if [ "$gluetun_state" = "running" ] &&
      ! docker exec gluetun netstat -tln 2>/dev/null | grep -q ':8080 '; then
      log "qbit listener missing from gluetun netns (orphaned), restarting qbittorrent"
      docker restart qbittorrent || log "restart failed"
    fi
  fi

  loops=$((loops + 1))
  if [ "$state" = "running" ] && [ $((loops % REACH_EVERY)) -eq 0 ]; then
    ip=$(docker exec gluetun cat /tmp/gluetun/ip 2>/dev/null)
    port=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null)
    if [ -n "$ip" ] && [ -n "$port" ]; then
      if nc -z -w 10 "$ip" "$port"; then
        [ "$fails" -gt 0 ] && log "reachable again at $ip:$port"
        fails=0
      else
        fails=$((fails + 1))
        log "NOT reachable at $ip:$port (failure $fails/$REACH_FAILS_MAX)"
        now=$(date +%s)
        if [ "$fails" -ge "$REACH_FAILS_MAX" ]; then
          if [ $((now - last_reconnect)) -ge "$RECONNECT_COOLDOWN" ]; then
            reconnect_vpn
            last_reconnect=$(date +%s)
            fails=0
          else
            log "reconnect suppressed by cooldown"
          fi
        fi
      fi
    fi
  fi
  sleep 60
done
