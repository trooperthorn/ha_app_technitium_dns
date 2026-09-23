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
#
# Technitium 15.4.0 (upstream's own newest release as of 2026-09-15, see
# docs/decisions.md) is built FROM mcr.microsoft.com/dotnet/aspnet:10.0 and
# bundles .NET runtime 10.0.9. Six High-severity GHSA advisories against
# Microsoft.NETCore.App.Runtime.linux-x64 10.0.9 are fixed in 10.0.10/
# 10.0.11, and Technitium has not yet published a release built against a
# newer runtime. This stage pulls mcr.microsoft.com/dotnet/aspnet:10.0.12
# (Microsoft's own newest patch release as of 2026-09-15, superseding both
# fix versions) so its shared framework files can overwrite the ones baked
# into the Technitium image below, without waiting on a Technitium release.
# See docs/decisions.md, "Runtime overlay to clear High CVEs", for the CI
# scan that surfaced this and how to re-verify or remove this stage once
# Technitium ships a release built against a current runtime.
FROM mcr.microsoft.com/dotnet/aspnet:10.0.12@sha256:2d584d8147faddb0d678c5748d47953e5b8e18621ed4fb7049a91381d9d7746f AS dotnet-runtime-patch

FROM technitium/dns-server:15.5.0@sha256:2502fd4993d18a8c6665ce6eefb20c76ca21918c5435a015d9485b36e8275b5e

# Add the 10.0.12 shared frameworks alongside the existing ones, then
# remove the vulnerable 10.0.9 version folders explicitly: a plain COPY over
# an existing directory merges files in rather than replacing the directory,
# so the old 10.0.9 files would otherwise remain on disk (and still get
# flagged by the vulnerability scan) even after 10.0.12 is added. .NET's own
# framework resolution always accepts a newer patch within the same
# major.minor, regardless of the application's rollForward setting, so
# removing 10.0.9 once 10.0.12 is present does not require touching
# Technitium's own runtimeconfig.json. Verify after building: `dotnet --info`
# inside the container should report only 10.0.12 for both frameworks, and
# the Security workflow's vulnerability scan should no longer list the
# Microsoft.NETCore.App.Runtime.linux-x64 10.0.9 GHSA entries.
COPY --from=dotnet-runtime-patch /usr/share/dotnet/shared/Microsoft.NETCore.App /usr/share/dotnet/shared/Microsoft.NETCore.App
COPY --from=dotnet-runtime-patch /usr/share/dotnet/shared/Microsoft.AspNetCore.App /usr/share/dotnet/shared/Microsoft.AspNetCore.App
RUN rm -rf /usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.9 \
    && rm -rf /usr/share/dotnet/shared/Microsoft.AspNetCore.App/10.0.9

ARG BUILD_VERSION
ARG BUILD_ARCH
LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}"

# curl is used by the HEALTHCHECK below. jq parses /data/options.json
# directly: this image is FROM technitium/dns-server, not a Home Assistant
# base image, so bashio (an HA base-image-only shell library) is not present
# here and run.sh must not depend on it. See docs/decisions.md. nginx-light
# is the Ingress reverse proxy added below (see docs/decisions.md, "Ingress
# panel blocked by Technitium's own frame-blocking headers"); the "-light"
# Debian package was confirmed to still include the proxy, map, and headers
# modules this config uses, with a smaller footprint than the full package.
# logrotate rotates the web console access log; see docs/decisions.md, "Web
# console access log for SOC audit tracking".
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq nginx-light logrotate \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Port 5380 is now nginx (the Ingress reverse proxy), not Technitium
# directly; Technitium itself listens on the internal-only 5381 (see
# run.sh). A 200 here confirms both nginx and the upstream Technitium
# console it proxies to are responding; it does not confirm DNS resolution
# or the admin API. See docs/operations.md.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:5380/ || exit 1

ENTRYPOINT []
CMD [ "/run.sh" ]
