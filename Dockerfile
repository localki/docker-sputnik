# Sputnik — compact AmneziaWG entry/exit node (~20 MB).
#
#   docker build -t sputnik .
#   docker buildx build --platform linux/arm64,linux/amd64 -t sputnik .
ARG AWG_GO_REF=v3.1.20260828
ARG AWG_TOOLS_REF=v3.1.20260812

# --- amneziawg-go (static Go binary) --------------------------------------
FROM golang:1.25-alpine AS go-builder
ARG AWG_GO_REF
RUN apk add --no-cache git make \
    && git clone --depth=1 --branch "${AWG_GO_REF}" \
        https://github.com/amnezia-vpn/amneziawg-go.git /src
WORKDIR /src
RUN make

# --- awg CLI (C, musl) ------------------------------------------------------
FROM alpine:3.22 AS tools-builder
ARG AWG_TOOLS_REF
RUN apk add --no-cache git make gcc musl-dev linux-headers \
    && git clone --depth=1 --branch "${AWG_TOOLS_REF}" \
        https://github.com/amnezia-vpn/amneziawg-tools.git /src
WORKDIR /src/src
RUN make

# --- runtime -----------------------------------------------------------------
FROM alpine:3.22
RUN apk add --no-cache iptables iproute2
COPY --from=go-builder /src/amneziawg-go /usr/bin/amneziawg-go
COPY --from=tools-builder /src/src/wg /usr/bin/awg
RUN chmod +x /usr/bin/amneziawg-go /usr/bin/awg
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
    CMD sh -c 'now=$(date +%s); found=0; for d in /sys/class/net/awg*; do [ -e "$d" ] || continue; found=1; iface=$(basename "$d"); if ! awg show "$iface" latest-handshakes 2>/dev/null | awk -v now="$now" "{ if ($2 + 600 < now) exit 1 }"; then exit 1; fi; done; [ "$found" = "1" ]'
ENTRYPOINT ["/app/entrypoint.sh"]
