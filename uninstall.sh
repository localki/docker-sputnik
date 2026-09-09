#!/bin/sh
# Sputnik uninstaller.
#
#   curl -fsSL https://raw.githubusercontent.com/localki/docker-sputnik/main/uninstall.sh | sh
#
# Stops and removes the entry container. With --purge also removes the
# image, the cloned sources and the config (the vpn:// link stays in your
# bot profile — nothing secret is deleted implicitly... except the local
# client.conf, which is why --purge asks first).
#
# Env knobs: CONTAINER_NAME (default sputnik), SPUTNIK_DIR (/opt/sputnik),
# IMAGE (sputnik).
set -eu

NAME="${CONTAINER_NAME:-sputnik}"
DIR="${SPUTNIK_DIR:-/opt/sputnik}"
IMAGE="${SPUTNIK_IMAGE:-sputnik}"
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            printf 'usage: uninstall.sh [--purge]\n'
            exit 0 ;;
        *) printf '[sputnik] ERROR: unknown argument %s\n' "$arg" >&2; exit 1 ;;
    esac
done

log() { printf '[sputnik] %s\n' "$*"; }
die() { printf '[sputnik] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "no docker on PATH, nothing to remove"

if docker inspect "$NAME" >/dev/null 2>&1; then
    log "stopping $NAME"
    docker stop "$NAME" >/dev/null 2>&1 || true
    log "removing $NAME"
    docker rm "$NAME" >/dev/null 2>&1 || die "cannot remove $NAME"
else
    log "no container named $NAME, nothing to stop"
fi

if [ "$PURGE" -eq 1 ]; then
    printf '[sputnik] delete image %s, sources %s/repo and config %s/client.conf? [y/N] ' \
        "$IMAGE" "$DIR" "$DIR" >&2
    answer=""
    if [ -t 0 ]; then
        read -r answer
    elif [ -c /dev/tty ] && read -r answer </dev/tty; then
        printf '[sputnik] (typed)\n' >&2
    else
        die "no confirmation available — re-run on a terminal"
    fi
    case "$answer" in
        y|Y|yes|YES|да|ДА|д|Д)
            docker rmi "$IMAGE" >/dev/null 2>&1 || log "image $IMAGE already gone"
            rm -rf "$DIR/repo" "$DIR/client.conf" "$DIR/build.log" "$DIR/git.log" "$DIR/run.log"
            log "purged"
            ;;
        *) log "purge cancelled, container is removed" ;;
    esac
fi

log "done"
