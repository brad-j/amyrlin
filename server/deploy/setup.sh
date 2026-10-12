#!/bin/sh
# Installs or updates the amyrlin server for the current user on a Linux machine with systemd.
#   sh server/deploy/setup.sh
# Checkout:  ~/.local/share/amyrlin/app      Store:   ~/.local/share/amyrlin/store.sqlite
# Settings:  ~/.config/amyrlin/config.json   API key: ~/.config/amyrlin/anthropic-api-key (mode 600, you create it)
# Service:   systemctl --user status amyrlin
set -eu

repo=git@github.com:brad-j/amyrlin.git
app="$HOME/.local/share/amyrlin/app"
conf="$HOME/.config/amyrlin"
unit="$HOME/.config/systemd/user/amyrlin.service"

node=$(command -v node) || { echo "node not found on PATH" >&2; exit 1; }
"$node" -e 'const [a,b]=process.versions.node.split(".").map(Number); if (a<22||(a===22&&b<19)) { console.error("node >= 22.19 needed, have "+process.version); process.exit(1) }'

if [ -d "$app/.git" ]; then git -C "$app" pull --ff-only; else mkdir -p "$(dirname "$app")" && git clone "$repo" "$app"; fi
(cd "$app/server" && pnpm install --frozen-lockfile --filter amyrlin-server --config.confirmModulesPurge=false)

mkdir -p "$conf" && chmod 700 "$conf"
if [ ! -f "$conf/config.json" ]; then
	login=${AMYRLIN_LOGIN:?set AMYRLIN_LOGIN to your Tailscale login for the first install}
	cat > "$conf/config.json" <<JSON
{
  "allowedLogins": ["$login"],
  "cwd": "~/westwood/Projects",
  "model": { "provider": "anthropic", "modelId": "claude-sonnet-5-5" },
  "thinkingLevel": "medium",
  "requireApproval": ["bash", "write", "edit"]
}
JSON
	echo "wrote $conf/config.json"
fi
[ -f "$conf/anthropic-api-key" ] || echo "note: put the Anthropic API key in $conf/anthropic-api-key (chmod 600) before using it"

mkdir -p "$(dirname "$unit")"
cat > "$unit" <<UNIT
[Unit]
Description=amyrlin server (pi-durable agents, protocol v1)
After=network-online.target

[Service]
WorkingDirectory=$app/server
ExecStart=$node --no-warnings src/main.mjs
Environment=AMYRLIN_CONFIG=$conf/config.json
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable amyrlin.service >/dev/null
systemctl --user restart amyrlin.service
sleep 2
systemctl --user --no-pager --lines=5 status amyrlin.service
