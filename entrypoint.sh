#!/bin/sh
# awg-entry: compact AmneziaWG client that turns its host into either a
# LAN entry point (port-forward selected LAN services into the BigPing
# local network) or an internet exit for the LAN.
#
# One container holds a persistent connection per .conf file found in
# AWG_CONF_DIR (default /etc/awg/*.conf): the first becomes awg0, the
# next awg1, and so on. A single file in AWG_CONF keeps the legacy
# single-tunnel behaviour on AWG_IFACE.
#
# Mode policy (no auto-guessing, no exceptions):
#   ENTRY_MODE=lan  (default) - entry point into the home LAN.
#       Use with a profile whose internet exit is OFF. FORWARD_PORTS is
#       required. The container never routes LAN traffic to the internet.
#   ENTRY_MODE=inet - internet exit for LAN devices pointed at this host.
#       Use ONLY with a profile whose LAN access is OFF and internet exit
#       is ON. A both-on or unknown profile must stay in lan mode.
#
# Required mounts/env:
#   /etc/awg/*.conf  - .conf files downloaded from the BigPing bot
#   FORWARD_PORTS    - lan mode: "8123>192.168.1.10:8123,22>192.168.1.10"
#                      (applied to every tunnel interface)
#   LAN_IF           - LAN interface (auto-detected from default route
#                      when empty; mandatory in inet mode if undetectable)
#   DRYRUN=1         - print the commands instead of executing them
set -eu

CONF_DIR="${AWG_CONF_DIR:-/etc/awg}"
SINGLE_CONF="${AWG_CONF:-}"
IFACE_BASE="${AWG_IFACE:-awg0}"
MODE="${ENTRY_MODE:-lan}"
PORTS="${FORWARD_PORTS:-}"
LAN_IF="${LAN_IF:-}"
DRYRUN="${DRYRUN:-0}"

log() { printf '[awg-entry] %s\n' "$*"; }
die() { printf '[awg-entry] ERROR: %s\n' "$*" >&2; exit 1; }
run() {
    if [ "$DRYRUN" = "1" ]; then
        _ifs="$IFS"; IFS=' '; printf '+ %s\n' "$*"; IFS="$_ifs"
    else
        "$@"
    fi
}

case "$MODE" in lan|inet) ;; *) die "ENTRY_MODE must be 'lan' or 'inet', got '$MODE'";; esac

if [ -n "$SINGLE_CONF" ]; then
    [ -f "$SINGLE_CONF" ] || die "client config not found: $SINGLE_CONF (mount it there)"
    CONFS="$SINGLE_CONF"
else
    CONFS=""
    for candidate in "$CONF_DIR"/*.conf; do
        [ -f "$candidate" ] || continue
        CONFS="$CONFS $candidate"
    done
    [ -n "$CONFS" ] || die "no .conf files in $CONF_DIR (mount them there)"
fi

if [ -z "$LAN_IF" ]; then
    LAN_IF="$(ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | head -n 1)"
fi
[ -n "$LAN_IF" ] || die "cannot detect LAN interface, set LAN_IF explicitly"

if [ "$MODE" = "lan" ] && [ -z "$PORTS" ]; then
    die "FORWARD_PORTS is required in lan mode, e.g. FORWARD_PORTS='8123>192.168.1.10:8123'"
fi

# Section-aware INI getter: cfg_get <conf> <section> <key>
cfg_get() {
    awk -v sec="$2" -v key="$3" '
        /^\[/ { cur = substr($0, 2, length($0) - 2); next }
        cur == sec {
            pos = index($0, "=")
            if (pos > 0) {
                k = $0; sub(/=.*/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == key) {
                    v = substr($0, pos + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
                    print v
                }
            }
        }' "$1"
}

# Single-quote one argument for eval.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT INT TERM

setup_tunnel() {
    conf="$1"
    iface="$2"
    keydir="$TMPD/$iface"
    mkdir -p "$keydir"

    if [ "$DRYRUN" != "1" ]; then
        amneziawg-go "$iface" &
        for _i in $(seq 1 10); do
            if ip link show "$iface" >/dev/null 2>&1; then break; fi
            sleep 0.5
        done
        ip link show "$iface" >/dev/null 2>&1 || die "interface $iface did not come up"
    else
        log "(dry run: skip amneziawg-go for $iface)"
    fi

    CMD="awg set $(sq "$iface")"
    for spec in \
        "Jc:jc" "Jmin:jmin" "Jmax:jmax" \
        "S1:s1" "S2:s2" "S3:s3" "S4:s4" \
        "H1:h1" "H2:h2" "H3:h3" "H4:h4" \
        "ContentPaddingAddition:content-padding-addition" \
        "RekeyAfterTime:rekey-after-time" "RekeyTimeout:rekey-timeout" \
        "RejectAfterTime:reject-after-time" "KeepaliveTimeout:keepalive-timeout" \
        "MaxHandshakeAttempts:max-handshake-attempts" \
        "RandomTrailers:random-trailers" "DisableCookies:disable-cookies" ; do
        ck="${spec%%:*}"; arg="${spec##*:}"
        val="$(cfg_get "$conf" Interface "$ck")"
        [ -z "$val" ] && val="$(cfg_get "$conf" Peer "$ck")"
        [ -n "$val" ] && CMD="$CMD $arg $(sq "$val")"
    done
    for k in 1 2 3 4 5; do
        val="$(cfg_get "$conf" Interface "I$k")"
        [ -n "$val" ] && CMD="$CMD i$k $(sq "$val")"
    done

    PRIV="$(cfg_get "$conf" Interface PrivateKey)"
    [ -n "$PRIV" ] || die "PrivateKey missing in $conf"
    printf '%s\n' "$PRIV" >"$keydir/priv.key"
    chmod 600 "$keydir/priv.key"
    CMD="$CMD private-key $(sq "$keydir/priv.key")"

    HPK="$(cfg_get "$conf" Interface HeaderProtectionKey)"
    if [ -n "$HPK" ]; then
        printf '%s\n' "$HPK" >"$keydir/hpk.key"
        chmod 600 "$keydir/hpk.key"
        CMD="$CMD header-protection-key $(sq "$keydir/hpk.key")"
    fi

    PUB="$(cfg_get "$conf" Peer PublicKey)"
    PSK="$(cfg_get "$conf" Peer PresharedKey)"
    [ -n "$PUB" ] || die "Peer PublicKey missing in $conf"
    [ -n "$PSK" ] || die "Peer PresharedKey missing in $conf"
    printf '%s\n' "$PSK" >"$keydir/psk.key"
    chmod 600 "$keydir/psk.key"
    CMD="$CMD peer $(sq "$PUB") preshared-key $(sq "$keydir/psk.key")"
    PEER_ALLOWED="$(cfg_get "$conf" Peer AllowedIPs)"
    [ -n "$PEER_ALLOWED" ] && CMD="$CMD allowed-ips $(sq "$PEER_ALLOWED")"
    PEER_ENDPOINT="$(cfg_get "$conf" Peer Endpoint)"
    [ -n "$PEER_ENDPOINT" ] && CMD="$CMD endpoint $(sq "$PEER_ENDPOINT")"
    PEER_KEEPALIVE="$(cfg_get "$conf" Peer PersistentKeepalive)"
    [ -n "$PEER_KEEPALIVE" ] && CMD="$CMD persistent-keepalive $(sq "$PEER_KEEPALIVE")"

    if [ "$DRYRUN" = "1" ]; then
        printf '+ %s\n' "$CMD"
    else
        eval "$CMD"
    fi

    MTU="$(cfg_get "$conf" Interface MTU)"
    [ -n "$MTU" ] && run ip link set dev "$iface" mtu "$MTU"
    ADDRS="$(cfg_get "$conf" Interface Address)"
    OLD_IFS="$IFS"; IFS=','
    for addr in $ADDRS; do
        addr="$(printf '%s' "$addr" | tr -d ' ')"
        [ -n "$addr" ] && run ip address add dev "$iface" "$addr"
    done
    IFS="$OLD_IFS"
    run ip link set up dev "$iface"

    ALLOWED="$(cfg_get "$conf" Peer AllowedIPs)"
    OLD_IFS="$IFS"; IFS=','
    for cidr in $ALLOWED; do
        cidr="$(printf '%s' "$cidr" | tr -d ' ')"
        [ -n "$cidr" ] || continue
        case "$cidr" in
            *:*)
                if [ "$DRYRUN" = "1" ]; then
                    printf '+ ip -6 route replace %s dev %s\n' "$cidr" "$iface"
                else
                    ip -6 route replace "$cidr" dev "$iface" 2>/dev/null || true
                fi
                ;;
            *) run ip route replace "$cidr" dev "$iface" ;;
        esac
    done
    IFS="$OLD_IFS"
}

apply_ports() {
    iface="$1"
    OLD_IFS="$IFS"; IFS=','
    for mapping in $PORTS; do
        mapping="$(printf '%s' "$mapping" | tr -d ' ')"
        [ -n "$mapping" ] || continue
        case "$mapping" in
            *\>*:*:*) listen="${mapping%%>*}"; rest="${mapping#*>}" ;;
            *\>*)
                listen="${mapping%%>*}"; rest="${mapping#*>}:$listen" ;;
            *) die "bad FORWARD_PORTS entry '$mapping', want PORT>HOST[:PORT]" ;;
        esac
        host="${rest%%:*}"; port="${rest##*:}"
        case "$listen" in ''|*[!0-9]*) die "bad FORWARD_PORTS entry '$mapping', ports must be numeric" ;; esac
        case "$port" in ''|*[!0-9]*) die "bad FORWARD_PORTS entry '$mapping', ports must be numeric" ;; esac
        [ -n "$host" ] || die "bad FORWARD_PORTS entry '$mapping', empty host"
        run iptables -A FORWARD -i "$iface" -o "$LAN_IF" -p tcp -d "$host" --dport "$port" -j ACCEPT
        run iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport "$listen" -j DNAT --to-destination "$host:$port"
    done
    IFS="$OLD_IFS"
}

if [ "$DRYRUN" = "1" ]; then
    printf '+ sysctl -w net.ipv4.ip_forward=1\n'
elif ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
    log "warning: cannot enable ip_forward inside container, it must be on at host level"
fi

IFACES=""
idx=0
for conf in $CONFS; do
    if [ -n "$SINGLE_CONF" ]; then
        iface="$IFACE_BASE"
    else
        iface="awg$idx"
    fi
    idx=$((idx + 1))
    log "tunnel $iface <- $conf"
    setup_tunnel "$conf" "$iface"
    IFACES="$IFACES $iface"
done

if [ "$MODE" = "lan" ]; then
    for iface in $IFACES; do
        apply_ports "$iface"
    done
    for iface in $IFACES; do
        run iptables -A FORWARD -i "$iface" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        run iptables -A FORWARD -i "$LAN_IF" -o "$iface" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    run iptables -t nat -A POSTROUTING -o "$LAN_IF" -j MASQUERADE
    for iface in $IFACES; do
        run iptables -A FORWARD -i "$iface" -j DROP
    done
    log "lan-entry ready ($IFACES; ports: $PORTS)"
else
    for iface in $IFACES; do
        run iptables -A FORWARD -i "$LAN_IF" -o "$iface" -j ACCEPT
        run iptables -A FORWARD -i "$iface" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    for iface in $IFACES; do
        run iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
    done
    for iface in $IFACES; do
        run iptables -A FORWARD -i "$iface" -j DROP
    done
    log "internet-exit ready ($IFACES via $LAN_IF)"
fi

if [ "$DRYRUN" = "1" ]; then
    log "(dry run: setup complete)"
    exit 0
fi

while true; do
    for iface in $IFACES; do
        printf '%s: ' "$iface"
        awg show "$iface" latest-handshakes 2>/dev/null || true
    done
    sleep 60
done
