# One image, both roles (project.md §10): ROLE chooses at start.
#
#   docker build -t kick_tracker app/
#   docker run -e ROLE=web ... kick_tracker            # bin/server
#   docker run ... kick_tracker bin/migrate            # before a deploy
ARG ELIXIR_IMAGE=elixir:1.20-otp-28
ARG RUNTIME_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git nodejs npm \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY assets/package.json assets/package-lock.json assets/
RUN npm ci --prefix assets --no-audit --no-fund
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile && mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod
WORKDIR /app
RUN useradd --system --home /app app && chown app /app \
    && mkdir /transfers /journal && chown app /transfers /journal
COPY --from=build --chown=app /app/_build/prod/rel/kick_tracker ./
USER app
# The commit this image was built from (CI passes it): which build each
# node runs, shown on the admin health page.
ARG BUILD_SHA=""
ENV BUILD_SHA=${BUILD_SHA}
EXPOSE 4100
# A collector answers on its own status port (is it collecting, or
# standing by and checking?); the site on /healthz.
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s CMD \
    if [ "$ROLE" = "collector" ]; then curl -fsS http://127.0.0.1:${COLLECTOR_STATUS_PORT:-4101}/healthz; \
    else curl -fsS http://127.0.0.1:${PORT:-4100}/healthz; fi || exit 1
CMD ["/app/bin/server"]
