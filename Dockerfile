# the one place that names the default STK release: publish.yaml reads it from here
ARG STK_VERSION=1.5

# --- build ---
FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config ca-certificates curl \
      libcurl4-openssl-dev libssl-dev zlib1g-dev libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

ARG STK_VERSION
# sha256 of SuperTuxKart-${STK_VERSION}-src.tar.gz as published on the GitHub release (the release lists it as the asset
# digest; there is no separate checksum file). Ties the binaries to one identifiable source: the GPL "Corresponding Source".
# Update together with STK_VERSION.
ARG STK_SHA256=33cf8841e4ff4082d80b9248014295bbbea61d14683e86dff100e3ab8f7b27cb
WORKDIR /src
# the release tarball contains the game data, the plain tag archive does not
RUN curl -fsSL -o /tmp/stk-src.tar.gz \
      "https://github.com/supertuxkart/stk-code/releases/download/${STK_VERSION}/SuperTuxKart-${STK_VERSION}-src.tar.gz" \
 && echo "${STK_SHA256}  /tmp/stk-src.tar.gz" | sha256sum -c - \
 && tar xzf /tmp/stk-src.tar.gz --strip-components=1 \
 && rm /tmp/stk-src.tar.gz

# bundled enet/bullet/mcpp are used on purpose: one build, same result on amd64 and arm64
RUN cmake -S /src -B /build \
      -DSERVER_ONLY=ON -DUSE_SYSTEM_ENET=OFF -DUSE_SYSTEM_MCPP=OFF \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/stk \
 && cmake --build /build -j"$(nproc)" \
 && cmake --install /build

# upstream license texts: the GPL itself, the per-asset license files of the game data, and the credits
RUN mkdir -p /opt/stk/share/doc/supertuxkart \
 && cp /src/COPYING /src/data/CREDITS /opt/stk/share/doc/supertuxkart/ \
 && (cd /src/data && find . -iname 'licen[cs]e*' -type f -exec cp --parents {} /opt/stk/share/doc/supertuxkart/ \;)

# --- runtime ---
FROM debian:trixie-slim
ARG STK_VERSION
LABEL org.opencontainers.image.title="supertuxkart-server" \
      org.opencontainers.image.description="SuperTuxKart dedicated server (SERVER_ONLY build) with AI bot client" \
      org.opencontainers.image.source="https://github.com/alfsch/supertuxkart-server" \
      org.opencontainers.image.version="${STK_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libcurl4t64 libssl3t64 zlib1g libsqlite3-0 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --home-dir /home/stk stk
COPY --from=build /opt/stk /opt/stk
COPY entrypoint.sh healthcheck.sh /usr/local/bin/
COPY LICENSE /opt/stk/share/doc/supertuxkart-server/LICENSE
USER stk
WORKDIR /home/stk
# no HEALTHCHECK here: each instance checks different ports, so the deployment sets it per instance
EXPOSE 2759/udp 2757/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
