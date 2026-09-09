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
ENTRYPOINT ["/app/entrypoint.sh"]
