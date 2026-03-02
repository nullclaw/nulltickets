# syntax=docker/dockerfile:1

# -- Stage 1: Build ---------------------------------------------------------
FROM alpine:3.23 AS builder

RUN apk add --no-cache zig musl-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY deps/ deps/

RUN zig build -Doptimize=ReleaseSmall

# -- Stage 2: Runtime Base (shared) ----------------------------------------
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nulltickets

RUN apk add --no-cache ca-certificates tzdata

RUN mkdir -p /nulltickets-data && chown -R 65534:65534 /nulltickets-data

COPY --from=builder /app/zig-out/bin/nulltickets /usr/local/bin/nulltickets

ENV NULLTICKETS_PORT=7700
WORKDIR /nulltickets-data
EXPOSE 7700
ENTRYPOINT ["nulltickets"]
CMD ["--port", "7700", "--db", "/nulltickets-data/nulltickets.db"]

# Optional autonomous/root mode:
#   docker build --target release-root -t nulltickets:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
