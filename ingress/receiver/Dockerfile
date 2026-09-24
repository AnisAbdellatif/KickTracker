# The webhook receiver (project.md §8.4): verify, envelope, publish or
# spool, answer. Its spool lives in /data (a volume), never in the image.
ARG ELIXIR_IMAGE=elixir:1.20-otp-28
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY lib lib
COPY config/runtime.exs config/
RUN mix compile && mix release

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 SPOOL_PATH=/data/spool.sqlite3
WORKDIR /app
RUN useradd --system --home /app app && mkdir /data && chown app /app /data
COPY --from=build --chown=app /app/_build/prod/rel/receiver ./
USER app
VOLUME /data
EXPOSE 4060
HEALTHCHECK --interval=10s --timeout=3s CMD curl -fsS http://127.0.0.1:${PORT:-4060}/health || exit 1
CMD ["/app/bin/receiver", "start"]
