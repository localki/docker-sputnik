# Sputnik — compact AmneziaWG entry/exit node (~20 MB)

One container holds a persistent AmneziaWG 3.1 tunnel per `.conf`
(`awg0`, `awg1`, …) and turns its host into either a LAN entry point
(port-forward LAN services into your BigPing local network) or an
internet exit for the LAN.

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/localki/docker-sputnik/main/install.sh \
  | sh -s -- "vpn://..."
```

Without arguments the script asks for the `vpn://` link interactively
(copy it from the profile screen in the BigPing bot, «📱 Amnezia» button).

Requirements on the host: Docker, python3 (to decode the link), git,
`/dev/net/tun` (i.e. a kernel with `CONFIG_TUN=y/m`).

## Modes (no auto-guessing, no exceptions)

Bot profile flags map to modes like this: LAN on + internet off =
🛰 Спутник; LAN off + internet on = 🚇 Тоннель; both on = 🔀 Гибрид;
both off = 🛰️ satellite (cannot initiate anything, no internet; reachable from LAN-enabled hosts).

- `ENTRY_MODE=lan` (default) — entry point into the home LAN. Use only
  with a profile whose internet exit is **OFF**. `FORWARD_PORTS` is
  required, e.g. `8123>192.168.1.10:8123`.
- `ENTRY_MODE=inet` — internet exit for LAN devices pointed at this host.
  Use ONLY with a profile whose LAN access is **OFF** and internet exit
  is **ON**.

## Manual run

```bash
docker build -t sputnik .
docker run -d --name sputnik --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v ./awg.conf:/etc/awg/client.conf:ro \
  -e FORWARD_PORTS='8123>192.168.1.10:8123' \
  sputnik
docker logs -f sputnik   # handshakes every 60 seconds
```

Multiple tunnels: mount a directory of `.conf` files at `/etc/awg`
instead of a single file. `DRYRUN=1` prints all commands without
executing anything.

## Monitoring

```bash
docker logs -f sputnik        # handshake timestamps every 60 seconds
docker inspect --format '{{.State.Health.Status}}' sputnik
```

The image carries a `HEALTHCHECK`: every 60 seconds (after a 3-minute
start period) it requires a handshake no older than 10 minutes on every
tunnel interface. `unhealthy` means the tunnel is down — check the logs.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/localki/docker-sputnik/main/uninstall.sh | sh
sh uninstall.sh --purge   # also image, sources and config (asks first)
```
