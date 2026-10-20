# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=elixir:1.18.4-otp-27

FROM ${ELIXIR_IMAGE} AS build
WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

FROM ${ELIXIR_IMAGE}-slim
WORKDIR /app
ENV LANG=C.UTF-8 PHX_SERVER=true PORT=4000 CACHE_DIR=/data

RUN useradd --create-home app && mkdir /data && chown app /data
COPY --from=build --chown=app /app/_build/prod/rel/charger ./
USER app

VOLUME /data
EXPOSE 4000
CMD ["/app/bin/charger", "start"]
