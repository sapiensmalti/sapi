# syntax=docker/dockerfile:1
# sapi-egress sidecar image. Built from this checkout by CI (natively per
# architecture) and merged into one multi-arch manifest. The runtime stage is
# Alpine + iptables + one static binary; it starts as root to install the
# namespace firewall and drops to uid 65532 before serving.
FROM rust:1-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked \
    && cp target/release/sapi-egress /sapi-egress \
    && /sapi-egress --version

FROM alpine:3.20
RUN apk add --no-cache iptables ip6tables \
    && addgroup -g 65532 -S egress && adduser -u 65532 -S -G egress -H -s /sbin/nologin egress \
    && mkdir -p /run/egress && chown 65532:65532 /run/egress
COPY --from=builder /sapi-egress /usr/local/bin/sapi-egress
ENTRYPOINT ["/usr/local/bin/sapi-egress"]
