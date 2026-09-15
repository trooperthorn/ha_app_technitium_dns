# Fresh build FROM the upstream Technitium image, not the Home Assistant
# base image: Technitium ships its own .NET runtime and application, and
# there is nothing this app adds to the container besides the first-run
# password seeding and the option-to-environment translation in run.sh.
#
# Pinned tag: technitium/dns-server:15.4.0
# Digest (linux/amd64 manifest list, read from Docker Hub 2026-09-15):
#   sha256:df7d90ef0f7b6fff6916d291a7022cd902290cc31c3141d4158b6c375a641b41
# See docs/decisions.md for how this tag was chosen and how to re-verify it.
#
# Upstream's own Dockerfile (TechnitiumSoftware/DnsServer, read 2026-09-15)
# has no USER directive: the process runs as root inside the upstream image.
# This app does not add a USER either, because /etc/dns is owned by root in
# the upstream image and switching users here would break its own first-run
# file permissions in an unverified way. See docs/security.md, "Container
# user: unverified / not changed".
FROM technitium/dns-server:15.4.0@sha256:df7d90ef0f7b6fff6916d291a7022cd902290cc31c3141d4158b6c375a641b41

ARG BUILD_VERSION
ARG BUILD_ARCH
LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}"

# curl is used by the HEALTHCHECK below and by run.sh to poll the web
# console before generating first-run instructions.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Upstream's own web console has no unauthenticated status route; this
# checks that the port is accepting TCP connections, not that DNS
# resolution or the admin API are healthy. See docs/operations.md.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:5380/ || exit 1

ENTRYPOINT []
CMD [ "/run.sh" ]
