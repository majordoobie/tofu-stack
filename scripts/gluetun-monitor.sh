#!/bin/bash
# gluetun-monitor.sh - Monitors gluetun health and restarts via docker compose
# This ensures dependent services (qbittorrent, prowlarr, flaresolverr) are also restarted

COMPOSE_DIR="/Users/tanjiro/containers/tofu-stack"
LOG_FILE="/Users/tanjiro/containers/tofu-stack/logs/gluetun-monitor.log"
CHECK_INTERVAL=60  # seconds between health checks
UNHEALTHY_THRESHOLD=3  # consecutive failures before restart

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_gluetun_health() {
    # Check container health status
    local health=$(docker inspect --format='{{.State.Health.Status}}' gluetun 2>/dev/null)

    if [[ "$health" == "healthy" ]]; then
        return 0
    else
        return 1
    fi
}

check_dependent_containers() {
    # Check if any dependent containers are exited
    local exited=0
    for container in qbittorrent prowlarr flaresolverr; do
        local status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
        if [[ "$status" == "exited" ]]; then
            log "WARNING: $container is exited"
            exited=1
        fi
    done
    return $exited
}

restart_vpn_stack() {
    log "Restarting VPN stack via docker compose..."
    cd "$COMPOSE_DIR" || exit 1

    # Use docker compose to restart - this triggers dependency chain
    docker compose up -d gluetun --force-recreate 2>&1 | while read line; do log "  $line"; done

    # Wait for gluetun to be healthy
    log "Waiting for gluetun to become healthy..."
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        sleep 10
        if check_gluetun_health; then
            log "Gluetun is healthy"
            break
        fi
        attempts=$((attempts + 1))
    done

    # Now restart dependent services
    log "Restarting dependent services..."
    docker compose up -d qbittorrent prowlarr flaresolverr --force-recreate 2>&1 | while read line; do log "  $line"; done

    log "VPN stack restart complete"
}

restart_dependent_only() {
    log "Restarting exited dependent containers..."
    cd "$COMPOSE_DIR" || exit 1
    docker compose up -d qbittorrent prowlarr flaresolverr 2>&1 | while read line; do log "  $line"; done
    log "Dependent containers restarted"
}

# Main loop
log "=== Gluetun monitor started ==="
unhealthy_count=0

while true; do
    # First check if dependent containers are exited (even if gluetun is healthy)
    if ! check_dependent_containers; then
        if check_gluetun_health; then
            # Gluetun is healthy but dependents are down - just restart them
            restart_dependent_only
        fi
    fi

    # Check gluetun health
    if check_gluetun_health; then
        if [[ $unhealthy_count -gt 0 ]]; then
            log "Gluetun recovered (was unhealthy for $unhealthy_count checks)"
        fi
        unhealthy_count=0
    else
        unhealthy_count=$((unhealthy_count + 1))
        log "Gluetun unhealthy (count: $unhealthy_count/$UNHEALTHY_THRESHOLD)"

        if [[ $unhealthy_count -ge $UNHEALTHY_THRESHOLD ]]; then
            restart_vpn_stack
            unhealthy_count=0
        fi
    fi

    sleep $CHECK_INTERVAL
done
