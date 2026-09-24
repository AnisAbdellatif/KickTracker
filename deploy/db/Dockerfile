# TimescaleDB with WAL-G for continuous backups and point-in-time recovery
# (project.md §18.1). WAL-G is built from source, statically, because the
# TimescaleDB image is Alpine (musl) and WAL-G's release binaries are glibc.
ARG TIMESCALE_IMAGE=timescale/timescaledb:latest-pg18
ARG GO_IMAGE=golang:1.25-bookworm
ARG WALG_VERSION=v3.0.9

FROM ${GO_IMAGE} AS walg
ARG WALG_VERSION
RUN git clone --depth 1 --branch ${WALG_VERSION} https://github.com/wal-g/wal-g.git /src
WORKDIR /src
# PostgreSQL flavour only; no optional C libraries, so the binary is static.
RUN GOEXPERIMENT=jsonv2 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/pg.walgVersion=${WALG_VERSION}" \
      -o /wal-g ./main/pg

FROM ${TIMESCALE_IMAGE}
COPY --from=walg /wal-g /usr/local/bin/wal-g
COPY archive.conf /usr/local/share/kick_tracker/archive.conf
COPY 10-archive.sh /docker-entrypoint-initdb.d/10-archive.sh
