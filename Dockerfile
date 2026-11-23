# the one place that names the default STK release: publish.yaml reads it from here
ARG STK_VERSION=1.5

# --- build ---
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config ca-certificates curl \
      libcurl4-openssl-dev libssl-dev zlib1g-dev libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

ARG STK_VERSION
# sha256 of SuperTuxKart-${STK_VERSION}-src.tar.gz as published on the GitHub release (the release lists it as the asset
# digest; there is no separate checksum file). Ties the binaries to one identifiable source: the GPL "Corresponding Source".
# Renovate bumps STK_VERSION; run .github/scripts/update-stk-sha.sh on its PR branch to set this to match.
ARG STK_SHA256=33cf8841e4ff4082d80b9248014295bbbea61d14683e86dff100e3ab8f7b27cb
WORKDIR /src
# the release tarball contains the game data, the plain tag archive does not
RUN curl -fsSL -o /tmp/stk-src.tar.gz \
      "https://github.com/supertuxkart/stk-code/releases/download/${STK_VERSION}/SuperTuxKart-${STK_VERSION}-src.tar.gz" \
 && echo "${STK_SHA256}  /tmp/stk-src.tar.gz" | sha256sum -c - \
 && tar xzf /tmp/stk-src.tar.gz --strip-components=1 \
 && rm /tmp/stk-src.tar.gz

# hardening: stack protector, fortified libc calls and full RELRO (Debian's GCC enables only PIE by default); the binary is stripped
# bundled enet/bullet/mcpp are used on purpose: one build, same result on amd64 and arm64
RUN cmake -S /src -B /build \
      -DSERVER_ONLY=ON -DUSE_SYSTEM_ENET=OFF -DUSE_SYSTEM_MCPP=OFF \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/stk \
      -DCMAKE_C_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2" \
      -DCMAKE_CXX_FLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2" \
      -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,relro,-z,now" \
 && cmake --build /build -j"$(nproc)" \
 && cmake --install /build \
 && strip --strip-unneeded /opt/stk/bin/supertuxkart

# upstream license texts: the GPL itself, the per-asset license files of the game data, and the credits
RUN mkdir -p /opt/stk/share/doc/supertuxkart \
 && cp /src/COPYING /src/data/CREDITS /opt/stk/share/doc/supertuxkart/ \
 && (cd /src/data && find . -iname 'licen[cs]e*' -type f -exec cp --parents {} /opt/stk/share/doc/supertuxkart/ \;)

# --- runtime ---
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
ARG STK_VERSION
LABEL org.opencontainers.image.title="supertuxkart-server" \
      org.opencontainers.image.description="SuperTuxKart dedicated server (SERVER_ONLY build) with AI bot client" \
      org.opencontainers.image.source="https://github.com/alfsch/supertuxkart-server" \
      org.opencontainers.image.version="${STK_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
# set by publish.yaml to the year and week: the apt layer below is rebuilt at most once a week, so a security update of the
# Debian packages reaches the image even while the build cache holds it (the C++ build stage stays cached). It is not the day:
# a new value every day would make every publish a new image and defeat the check for unchanged builds.
ARG APT_REFRESH=none
RUN : "packages of ${APT_REFRESH}" \
 && apt-get update && apt-get install -y --no-install-recommends \
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
