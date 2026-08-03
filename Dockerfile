# esqlite is a NIF, so the build stage needs a C toolchain and the runtime
# stage must share the build stage's libc. Both are Alpine/musl for that reason:
# swapping either base for a glibc image breaks the compiled .so at load time.
FROM ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine AS build

RUN apk add --no-cache build-base

WORKDIR /build
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src ./src
RUN gleam export erlang-shipment

FROM erlang:29-alpine

RUN adduser -D -h /data reeds
COPY --from=build /build/build/erlang-shipment /app
WORKDIR /app

# Loopback is the right default for a host install and useless in a container,
# where it would bind the container's own lo and never see a published port.
ENV REEDS_BIND=0.0.0.0 \
    REEDS_PORT=7333 \
    REEDS_DB=/data/reeds.db \
    REEDS_CONFIG=/etc/reeds/config.toml

USER reeds
VOLUME /data
EXPOSE 7333

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
