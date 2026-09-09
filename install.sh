#!/bin/sh
# Sputnik installer — one command to turn this host into a BigPing entry
# (or exit) node.
#
#   curl -fsSL https://raw.githubusercontent.com/localki/docker-sputnik/main/install.sh \
#     | sh -s -- "vpn://..."
#
# Without arguments the script asks for the vpn:// link interactively
# (copy it from the profile screen in the bot, «📱 Amnezia» button).
#
# Env knobs: ENTRY_MODE=lan|inet (default lan), FORWARD_PORTS (lan mode),
# CONTAINER_NAME (default sputnik), SPUTNIK_DIR (default /opt/sputnik).
set -eu

REPO_URL="${SPUTNIK_REPO_URL:-https://github.com/localki/docker-sputnik.git}"
IMAGE="sputnik"
DIR="${SPUTNIK_DIR:-/opt/sputnik}"
NAME="${CONTAINER_NAME:-sputnik}"
MODE="${ENTRY_MODE:-lan}"
PORTS="${FORWARD_PORTS:-}"
VPN_URL="${1:-}"

log() { printf '[sputnik] %s\n' "$*"; }
die() { printf '[sputnik] ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "need '$1' on PATH ($2)"; }

ask() {
    prompt="$1"; out="$2"
    if [ -t 0 ]; then
        printf '[sputnik] %s: ' "$prompt" >&2
        read -r "$out" || die "input aborted"
    elif [ -c /dev/tty ] && read -r "$out" </dev/tty; then
        printf '[sputnik] %s: (typed)\n' "$prompt" >&2
    else
        die "$prompt — pass it as an argument or env (no interactive input available)"
    fi
}

need docker "install Docker first: https://docs.docker.com/engine/install"
need python3 "vpn:// decoding needs python3"
need git "to fetch the image sources"

if [ ! -e /dev/net/tun ]; then
    if zgrep -q "CONFIG_TUN=[ym]" /proc/config.gz 2>/dev/null \
        || grep -q "CONFIG_TUN=[ym]" "/boot/config-$(uname -r)" 2>/dev/null; then
        die "/dev/net/tun is missing (load the tun module: modprobe tun)"
    fi
    die "this kernel has no TUN support (CONFIG_TUN is not set) — tunnels cannot run here"
fi

if [ -z "$VPN_URL" ]; then
    ask "paste the vpn:// link from the bot" VPN_URL
fi
case "$VPN_URL" in
    vpn://*) ;;
    *) die "expected a vpn:// link" ;;
esac

case "$MODE" in lan|inet) ;; *) die "ENTRY_MODE must be 'lan' or 'inet'" ;; esac
if [ "$MODE" = "lan" ] && [ -z "$PORTS" ]; then
    ask "FORWARD_PORTS (e.g. 8123>192.168.1.10:8123)" PORTS
fi

# System dirs need root; be explicit instead of failing halfway.
mkdir -p "$DIR" 2>/dev/null || die "cannot write $DIR — re-run as root or set SPUTNIK_DIR somewhere writable"

log "decoding vpn:// link"
VPN_URL="$VPN_URL" CONF_OUT="$DIR/client.conf" python3 - <<'PYEOF'
import base64
import json
import os
import zlib

url = os.environ["VPN_URL"]
blob = base64.urlsafe_b64decode(url[6:] + "=" * (-len(url[6:]) % 4))
body = zlib.decompress(blob[4:])
cfg = json.loads(body)
ini = json.loads(cfg["containers"][0]["awg"]["last_config"])["config"]
assert "[Interface]" in ini and "[Peer]" in ini, "not an AWG config"
with open(os.environ["CONF_OUT"], "w") as f:
    f.write(ini if ini.endswith("\n") else ini + "\n")
os.chmod(os.environ["CONF_OUT"], 0o600)
print("config ok:", ini.splitlines()[0])
PYEOF

log "fetching image sources"
if [ -d "$DIR/repo/.git" ]; then
    git -C "$DIR/repo" pull --ff-only >"$DIR/git.log" 2>&1 \
        || die "git pull failed, see $DIR/git.log"
    tail -n 1 "$DIR/git.log"
else
    rm -rf "$DIR/repo"
    git clone --depth=1 "$REPO_URL" "$DIR/repo" >"$DIR/git.log" 2>&1 \
        || die "git clone failed, see $DIR/git.log"
    tail -n 1 "$DIR/git.log"
fi

log "building image (first run takes a few minutes)"
docker build -t "$IMAGE" "$DIR/repo" >"$DIR/build.log" 2>&1 \
    || die "docker build failed, see $DIR/build.log"
tail -n 2 "$DIR/build.log"

log "starting container"
docker rm -f "$NAME" >/dev/null 2>&1 || true
RUN_ARGS="--cap-add NET_ADMIN --device /dev/net/tun"
if [ "$MODE" = "lan" ]; then
    # shellcheck disable=SC2086
    docker run -d --name "$NAME" --restart unless-stopped \
        $RUN_ARGS \
        -v "$DIR/client.conf:/etc/awg/client.conf:ro" \
        -e ENTRY_MODE=lan \
        -e FORWARD_PORTS="$PORTS" \
        "$IMAGE" >"$DIR/run.log" 2>&1 \
        || die "docker run failed, see $DIR/run.log"
    tail -n 1 "$DIR/run.log"
else
    docker run -d --name "$NAME" --restart unless-stopped \
        $RUN_ARGS \
        -v "$DIR/client.conf:/etc/awg/client.conf:ro" \
        -e ENTRY_MODE=inet \
        "$IMAGE" >"$DIR/run.log" 2>&1 \
        || die "docker run failed, see $DIR/run.log"
    tail -n 1 "$DIR/run.log"
fi

log "watch the handshake: docker logs -f $NAME"
