# ts-mullvad-rotate

Automatically selects and rotates the lowest-latency [Mullvad](https://mullvad.net) exit node via [Tailscale](https://tailscale.com), on a schedule, at boot, or manually. Filters out countries you don't want (e.g. UK nodes) and picks the fastest from a random sample by pinging candidates using the Mullvad public API.

---

## How it works

1. Fetches the list of available Mullvad exit nodes from your Tailscale tailnet
2. Filters out any excluded countries (default: UK)
3. Pulls public IPs from the Mullvad relay API for latency testing
4. Pings a random sample of 8 candidates, 3 pings each
5. Connects to the lowest-latency node via `tailscale set --exit-node`
6. Runs every 6 hours via a systemd timer, and once at boot (with a 15-second delay to avoid a race condition with Tailscale starting up)

---

## Requirements

- Linux with systemd
- [Tailscale](https://tailscale.com/download/linux) installed and logged in
- A Mullvad subscription [linked to your Tailscale account](https://tailscale.com/kb/1258/mullvad-exit-nodes)
- `curl`, `ping`, `python3`, `bash`

### Check dependencies

```bash
which curl ping python3 bash tailscale
```

---

## Files

| File | Description |
|---|---|
| `ts-mullvad-rotate.sh` | Main script |
| `ts-mullvad-rotate.service` | systemd service unit |
| `ts-mullvad-rotate.timer` | systemd timer unit (runs on boot + every 6h) |

---

## Installation

### 1. Install the script

```bash
sudo cp ts-mullvad-rotate.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/ts-mullvad-rotate.sh
```

### 2. Test it manually

```bash
sudo /usr/local/bin/ts-mullvad-rotate.sh
```

You should see it fetch nodes, ping candidates, and connect to the fastest one.

### 3. Install the systemd units

```bash
sudo cp ts-mullvad-rotate.service /etc/systemd/system/
sudo cp ts-mullvad-rotate.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ts-mullvad-rotate.timer
```

### 4. Verify it's running

```bash
systemctl status ts-mullvad-rotate.timer
journalctl -u ts-mullvad-rotate.service -n 20
```

---

## Configuration

Edit the config block near the top of `ts-mullvad-rotate.sh`:

```bash
# Countries to exclude (matched against the Mullvad API country name field)
EXCLUDE_COUNTRIES=("UK")

# Restrict to specific countries only — leave empty to allow all non-excluded
# Example: ONLY_COUNTRIES=("Germany" "Netherlands" "Sweden")
ONLY_COUNTRIES=()

# How many random candidates to ping and compare
PING_SAMPLE=8

# Pings per candidate and timeout in seconds
PING_COUNT=3
PING_TIMEOUT=3

# Keep LAN access while using exit node
ALLOW_LAN=true
```

> **Note:** Country names must match the Mullvad API's `country` field exactly (e.g. `"UK"` not `"United Kingdom"`).

To change the rotation interval, edit `ts-mullvad-rotate.timer`:

```ini
OnUnitActiveSec=6h   # Change to 1h, 12h, 24h, etc.
```

Then reload:

```bash
sudo systemctl daemon-reload
```

---

## Checking your current exit node

```bash
tailscale status | grep -i "exit node"
# or
tailscale debug prefs | grep ExitNode
```

Verify you're connected through Mullvad:

```bash
curl https://am.i.mullvad.net/connected
```

---

## Logs

The script logs to journald by default. View with:

```bash
journalctl -u ts-mullvad-rotate.service
journalctl -u ts-mullvad-rotate.service --since "today"
```

---

## Notes

- Boot timing uses two layers: the timer waits `OnBootSec=30sec` before firing, and the service adds a further `ExecStartPre=/bin/sleep 15` delay. This guards against a race condition where the script fires before Tailscale has fully connected and the Mullvad API fetch fails.
- Running `sudo tailscale down` or `sudo tailscale up` during troubleshooting will clear the active exit node — just re-run the script or wait for the timer to fire.
- Tested on Nobara Linux (Fedora-based). Should work on any systemd-based distro.

---

## License

MIT
