#!/usr/bin/env bash
# =============================================================================
# ts-mullvad-rotate.sh
# Selects the lowest-latency non-UK Mullvad exit node by:
#   1. Getting available Tailscale Mullvad nodes from tailscale exit-node list
#   2. Looking up their real public IPs from Mullvad's API
#   3. ICMP pinging a random sample to find the fastest
#   4. Connecting via tailscale set
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------

# Countries to exclude (matched against country_name from Mullvad API)
EXCLUDE_COUNTRIES=("UK")

# Optionally restrict to specific countries only (leave empty to allow all)
# Example: ONLY_COUNTRIES=("Germany" "Netherlands" "Sweden")
ONLY_COUNTRIES=()

# How many random candidates to ping and compare
PING_SAMPLE=8

# ICMP pings per node and timeout per ping in seconds
PING_COUNT=3
PING_TIMEOUT=3

# Keep LAN access while using exit node (true/false)
ALLOW_LAN=true

# Log file (set to "" to disable logging)
LOG_FILE="/var/log/ts-mullvad-rotate.log"

# --- Helpers -----------------------------------------------------------------

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

# --- Checks ------------------------------------------------------------------

command -v tailscale &>/dev/null || die "tailscale not found in PATH"
command -v ping      &>/dev/null || die "ping not found in PATH"
command -v curl      &>/dev/null || die "curl not found in PATH"
command -v python3   &>/dev/null || die "python3 not found in PATH"
tailscale status &>/dev/null     || die "tailscale daemon not running"

# --- Get Tailscale Mullvad node list -----------------------------------------

log "Fetching Mullvad exit nodes from Tailscale..."

mapfile -t TS_NODES < <(
    tailscale exit-node list 2>/dev/null \
    | tail -n +2 \
    | grep "mullvad"
)

[[ ${#TS_NODES[@]} -gt 0 ]] \
    || die "No Mullvad exit nodes found. Is the Mullvad add-on enabled on your tailnet?"

# Build a lookup of short hostname -> tailscale full hostname
# e.g. "de-fra-wg-001" -> "de-fra-wg-001.mullvad.ts.net"
declare -A TS_HOSTNAME_MAP
for line in "${TS_NODES[@]}"; do
    full_hostname=$(echo "$line" | awk '{print $2}')
    # Skip Any pseudo-entries
    [[ "$full_hostname" == *"-any-"* ]] && continue
    short=$(echo "$full_hostname" | cut -d'.' -f1)
    TS_HOSTNAME_MAP["$short"]="$full_hostname"
done

log "Found ${#TS_HOSTNAME_MAP[@]} specific Tailscale Mullvad nodes."

# --- Fetch Mullvad public relay list with real IPs ---------------------------

log "Fetching Mullvad relay list for public IPs..."

RELAY_JSON=$(curl -sf --max-time 10 "https://api.mullvad.net/www/relays/wireguard/" 2>/dev/null) \
    || die "Failed to fetch Mullvad relay list. Check your internet connection."

# --- Build filtered candidate list -------------------------------------------
# Each entry: "public_ip tailscale_hostname country_name"

CANDIDATES=()

while IFS= read -r entry; do
    short_host=$(echo "$entry" | awk '{print $1}')
    public_ip=$(echo "$entry"  | awk '{print $2}')
    country=$(echo "$entry"    | cut -d' ' -f3-)

    # Must exist in our Tailscale node list
    [[ -v TS_HOSTNAME_MAP["$short_host"] ]] || continue
    ts_hostname="${TS_HOSTNAME_MAP[$short_host]}"

    # Apply country exclusions
    skip=false
    for excl in "${EXCLUDE_COUNTRIES[@]}"; do
        if echo "$country" | grep -qi "$excl"; then
            skip=true
            break
        fi
    done
    $skip && continue

    # Apply allowlist if set
    if [[ ${#ONLY_COUNTRIES[@]} -gt 0 ]]; then
        allowed=false
        for only in "${ONLY_COUNTRIES[@]}"; do
            if echo "$country" | grep -qi "$only"; then
                allowed=true
                break
            fi
        done
        $allowed || continue
    fi

    CANDIDATES+=("$public_ip $ts_hostname $country")

done < <(echo "$RELAY_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get('active') and r.get('ipv4_addr_in'):
        print(r['hostname'], r['ipv4_addr_in'], r['country_name'])
")

[[ ${#CANDIDATES[@]} -gt 0 ]] \
    || die "No eligible exit nodes after filtering."

log "Found ${#CANDIDATES[@]} eligible node(s) after filtering."

# --- Pick a random sample to ping --------------------------------------------

SAMPLE_SIZE=$(( ${#CANDIDATES[@]} < PING_SAMPLE ? ${#CANDIDATES[@]} : PING_SAMPLE ))

mapfile -t SAMPLE < <(
    printf '%s\n' "${CANDIDATES[@]}" | shuf | head -n "$SAMPLE_SIZE"
)

log "Pinging $SAMPLE_SIZE candidate node(s) to find the fastest..."

# --- ICMP ping each candidate ------------------------------------------------

BEST_HOST=""
BEST_MS=999999

for entry in "${SAMPLE[@]}"; do
    public_ip=$(   echo "$entry" | awk '{print $1}')
    ts_hostname=$( echo "$entry" | awk '{print $2}')
    country=$(     echo "$entry" | cut -d' ' -f3-)

    raw=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$public_ip" 2>/dev/null || true)
    avg_ms=$(echo "$raw" | grep -oP 'rtt.*=\s*[\d.]+/\K[\d.]+' | head -1)

    if [[ -z "$avg_ms" ]]; then
        log "  $ts_hostname ($country) — no response (skipping)"
        continue
    fi

    avg_int=$(printf '%.0f' "$avg_ms")
    log "  $ts_hostname ($country) — ${avg_ms}ms"

    if (( avg_int < BEST_MS )); then
        BEST_MS=$avg_int
        BEST_HOST=$ts_hostname
    fi
done

# --- Fallback to random if all pings failed ----------------------------------

if [[ -z "$BEST_HOST" ]]; then
    log "WARNING: All pings failed. Falling back to random selection."
    random_entry="${CANDIDATES[RANDOM % ${#CANDIDATES[@]}]}"
    BEST_HOST=$(echo "$random_entry" | awk '{print $2}')
    BEST_MS=0
fi

log "Best node: $BEST_HOST (${BEST_MS}ms avg)"

# --- Connect -----------------------------------------------------------------

CMD=(tailscale set --exit-node="$BEST_HOST")
if [[ "$ALLOW_LAN" == "true" ]]; then
    CMD+=(--exit-node-allow-lan-access=true)
fi

log "Running: ${CMD[*]}"
"${CMD[@]}" && log "Connected successfully via $BEST_HOST" || die "Failed to set exit node"
