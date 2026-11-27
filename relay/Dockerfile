# Uplink relay in a container (docs/SELF_HOSTING.md).
#
#   docker build -t ghost-relay .            # from messaging/relay
#   docker run -d --name ghost-relay -p 127.0.0.1:8787:8787 -v ghost-relay-data:/data \
#     --env-file relay.env --restart unless-stopped ghost-relay
#
# Or deploy/compose.yaml, which adds Caddy for TLS (and coturn for calls, if you want it).
# The relay uses nothing but Dart's own library, so the build fetches nothing beyond the Dart image itself.

FROM dart:3.11 AS build
WORKDIR /src
COPY pubspec.yaml ./
COPY bin ./bin
COPY lib ./lib
# The test package is for development only: without it there is nothing to fetch, and pub get only writes the
# package config the compiler reads.
RUN sed -i '/^dev_dependencies:/,$d' pubspec.yaml && dart pub get --offline
RUN mkdir -p /out/data && dart compile exe bin/relay.dart -o /out/ghost-relay

# The compiled program needs only the C library and certificates, which /runtime/ in the Dart image provides.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/ghost-relay /app/ghost-relay
# What it keeps (pairings, usernames, sealed backups, Files, the Marketplace) lives in /data, owned by the user it runs
# as: never root.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
VOLUME /data
EXPOSE 8787
# Listens on every interface inside the container; publish the port to 127.0.0.1 only (as above) and let the web
# server that holds the certificate pass requests on to it.
ENTRYPOINT ["/app/ghost-relay", "--host", "0.0.0.0", "--port", "8787", "--data", "/data"]
