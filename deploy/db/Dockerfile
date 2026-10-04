# TimescaleDB with WAL-G for continuous backups and point-in-time recovery
# (project.md §18.1). WAL-G is built from source, statically, because the
# TimescaleDB image is Alpine (musl) and WAL-G's release binaries are glibc.
ARG TIMESCALE_IMAGE=timescale/timescaledb:latest-pg18
ARG GO_IMAGE=golang:1.25-alpine
ARG WALG_VERSION=v3.0.9

FROM ${GO_IMAGE} AS walg
ARG WALG_VERSION
RUN apk add --no-cache git build-base libsodium-dev libsodium-static
RUN git clone --depth 1 --branch ${WALG_VERSION} https://github.com/wal-g/wal-g.git /src
WORKDIR /src
# PostgreSQL flavour, with libsodium (WALG_LIBSODIUM_KEY: without the tag,
# every push fails with "wal-g was not compiled with libsodium"), linked
# statically against Alpine's musl and libsodium.a.
RUN GOEXPERIMENT=jsonv2 CGO_ENABLED=1 go build -trimpath -tags libsodium \
      -ldflags "-s -w -linkmode external -extldflags -static -X github.com/wal-g/wal-g/cmd/pg.walgVersion=${WALG_VERSION}" \
      -o /wal-g ./main/pg
# Fail the build, not the first backup, if encryption isn't in: a round
# trip through an encrypted store.
RUN mkdir /tmp/check && echo ok >/tmp/plain && \
    export WALG_FILE_PREFIX=/tmp/check WALG_LIBSODIUM_KEY_TRANSFORM=hex \
      WALG_LIBSODIUM_KEY=0000000000000000000000000000000000000000000000000000000000000000 && \
    /wal-g st put /tmp/plain plain && \
    ! grep -q ok /tmp/check/plain.lz4 && \
    [ "$(/wal-g st cat --decrypt --decompress plain.lz4)" = ok ] && \
    rm -r /tmp/check /tmp/plain

FROM ${TIMESCALE_IMAGE}
COPY --from=walg /wal-g /usr/local/bin/wal-g
COPY archive.conf /usr/local/share/kick_tracker/archive.conf
COPY 10-archive.sh /docker-entrypoint-initdb.d/10-archive.sh
# WAL-G's store (WALG_FILE_PREFIX=/backups, a volume of its own): owned by
# postgres here, so a new volume mounted on it starts that way.
RUN mkdir -p /backups && chown postgres:postgres /backups && chmod 700 /backups
