# AGENTS.md

This file guides agentic coding tools working in this repository.

## Project Overview

Tofu Stack is a self-hosted media automation stack (*Arr stack) on macOS.
Docker Compose orchestrates most services; Tdarr nodes and a socat bridge run via launchd.
Secrets live in the `tofu-stack-secrets/` submodule and must never be committed.

## Repository Layout

- `docker-compose.yml`: Service definitions and Traefik routing labels.
- `tofu-stack-secrets/`: Git submodule with credentials and Traefik configs.
- `mounts/`: Persistent container data and Traefik logs/certs.
- `tdarr_node/`: Tdarr node configs, launchd plist files, and downloader script.
- `README.md`: Human-readable architecture notes and detailed walkthroughs.

## Build, Lint, Test

This repo is infrastructure-focused and does not ship a traditional build/test suite.
Use the operational commands below to validate changes.

### Build / Validate

- Validate docker-compose syntax: `docker compose config`
- Apply changes: `docker compose up -d`
- Recreate a single service: `docker compose up -d --force-recreate <service>`

### Lint

- No linter is configured in-repo. Keep YAML and scripts clean and consistent.

### Test / Health Checks

- Check running services: `docker compose ps`
- Tail logs: `docker compose logs -f <service>`
- Test Gluetun connectivity: `docker compose exec gluetun ping 8.8.8.8`

### Single Test Equivalent

- There are no unit tests. Treat per-service healthchecks or targeted commands as a single test.
- Example: `docker compose logs -f gluetun` or `docker compose exec <service> <cmd>`

## Service Operations

- Start all containers: `docker compose up -d`
- Stop all containers: `docker compose down`
- Restart a service: `docker compose restart <service>`

## Tdarr Nodes (macOS)

- Download node: `python3 tdarr_node/download-tdarr-node.py tdarr_tanjiro`
- Install LaunchAgent: `cp tdarr_node/tdarr_tanjiro/com.tofu-stack.tdarr-node.tanjiro.plist ~/Library/LaunchAgents/`
- Start/stop: `launchctl load ~/Library/LaunchAgents/com.tofu-stack.tdarr-node.tanjiro.plist`
- Manual start: `cd tdarr_node/tdarr_tanjiro && ./Tdarr_Node`

## Home Assistant Bridge (socat)

- LaunchAgent plist: `~/Library/LaunchAgents/com.homeassistant.bridge.plist`
- Start/stop: `launchctl load ~/Library/LaunchAgents/com.homeassistant.bridge.plist`
- Logs: `tail -f /tmp/ha_bridge.err`
- Traefik must route to `http://host.docker.internal:8124`, never `192.168.1.5:8123`.

## Architecture Notes

- Cloudflare Edge → Cloudflare Tunnel → cloudflared → Traefik → Service.
- TLS terminates at Cloudflare; internal traffic is HTTP between cloudflared and Traefik.
- Services using `network_mode: service:gluetun` put Traefik labels on `gluetun`.

## Storage Layout

- SSD working storage: `/Volumes/Working-Storage/` (downloads, tdarr_cache).
- HDD media storage: `/Volumes/Plex-Storage/media/` (movies, shows, downloads).

## Code Style Guidelines

### YAML (docker-compose, Traefik)

- Use 2-space indentation and keep keys aligned.
- Keep service sections grouped and separated by comment banners.
- Prefer explicit ports and volumes; document any `network_mode` usage.
- Keep Traefik labels grouped and consistent by service.

### Shell Scripts

- Prefer POSIX-compatible shell unless a script requires bash.
- Add `set -euo pipefail` for new scripts unless there is a clear reason not to.
- Quote variables and paths, especially when user input is involved.

### Python Scripts

- Use 4-space indentation and standard library modules only unless needed.
- Keep functions small and focused; prefer pure functions over side effects.
- Use explicit error handling with clear, user-focused messages.

## Imports and Formatting

- Order imports: standard library first, then third-party, then local.
- Keep line length reasonable (around 100 chars) for readability.
- Avoid trailing whitespace and keep one newline at EOF.

## Naming Conventions

- Services: lowercase with hyphens only when required by external tooling.
- Files: use lowercase with hyphens or underscores; match existing patterns.
- Variables: `snake_case` in Python and shell; `SCREAMING_SNAKE_CASE` for constants.

## Types and Data Handling

- Python: type hints are optional, but keep data structures explicit.
- Avoid implicit type conversions that could mask errors.

## Error Handling

- Fail fast with clear messages when a command cannot proceed.
- Log critical errors to stderr in scripts where practical.

## Security and Secrets

- Never commit secrets from `tofu-stack-secrets/`.
- Do not inline credentials in `docker-compose.yml` unless already present.
- Be mindful that logs can contain secrets; avoid printing them.

## Change Workflow (Compose)

- Validate changes with `docker compose config` before applying.
- Apply updates with `docker compose up -d`.
- Check logs for modified services after deploy.

## Rules Sources

- No `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md` found.
