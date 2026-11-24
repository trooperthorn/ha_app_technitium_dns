# Fresh build FROM the upstream Technitium image, not the Home Assistant
# base image: Technitium ships its own .NET runtime and application, and
# there is nothing this app adds to the container besides the first-run
# password seeding and the option-to-environment translation in run.sh.
#
# Pinned tag: technitium/dns-server:15.6.2
# Digest (linux/amd64 manifest list, read from Docker Hub 2026-10-18):
#   sha256:eb48ac5c135f4ab936b536f74f853d53e15ab39ef37fdbc9598a089b90d9f245
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
#
# 2026-11-22: the overlay tag is bumped by Dependabot within the 10.0 line.
# 10.0.15 clears the High GHSA advisories Grype reports against
# Microsoft.AspNetCore.App.Runtime.linux-x64 10.0.13 and 10.0.14 (all "fixed
# in 10.0.15"). technitium/dns-server:15.6.2 bundles 10.0.13 itself, so the
# final stage below removes whatever shared framework versions the Technitium
# image ships before copying this stage's in, rather than naming one version.
FROM mcr.microsoft.com/dotnet/aspnet:11.0.0@sha256:ca396ece3f2a2e62c7a03f1d7d710b8bc7e8c9dea5597d091178d9f5bfca13f0 AS dotnet-runtime-patch

FROM technitium/dns-server:15.6.2@sha256:eb48ac5c135f4ab936b536f74f853d53e15ab39ef37fdbc9598a089b90d9f245

# Replace the shared frameworks baked into the Technitium image with the
# ones from the overlay stage. The bundled version folders are removed first
# and by directory, not by version number: a plain COPY over an existing
# directory merges files in rather than replacing the directory, so the
# bundled (older, vulnerable) version folders would otherwise remain on disk
# and still get flagged by the vulnerability scan. An earlier form of this
# step removed only a hard-coded 10.0.9 folder, which silently stopped
# matching once Technitium moved to 10.0.13. .NET's own framework resolution
# always accepts a newer patch within the same major.minor, regardless of the
# application's rollForward setting, so this does not require touching
# Technitium's own runtimeconfig.json. Verify after building:
# `dotnet --list-runtimes` inside the container should report only the
# overlay stage's version for both frameworks (the Test workflow's smoke test
# asserts this), and the Security workflow's vulnerability scan should list no
# Microsoft.*.App.Runtime.linux-x64 entries for older versions.
RUN rm -rf /usr/share/dotnet/shared/Microsoft.NETCore.App \
    /usr/share/dotnet/shared/Microsoft.AspNetCore.App
COPY --from=dotnet-runtime-patch /usr/share/dotnet/shared/Microsoft.NETCore.App /usr/share/dotnet/shared/Microsoft.NETCore.App
COPY --from=dotnet-runtime-patch /usr/share/dotnet/shared/Microsoft.AspNetCore.App /usr/share/dotnet/shared/Microsoft.AspNetCore.App

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
#
# apt-get upgrade applies the distro's own security updates to the OS
# packages inherited from the pinned Technitium image, which is rebuilt far
# less often than Ubuntu publishes fixes. Without it the Security workflow
# fails on fixable findings in packages this app never installs itself
# (2026-11-16: libbrotli1 CVE-2026-111497, High and KEV-listed, plus apt and
# libapt-pkg6.0t64 CVE-2026-109518, High).
RUN apt-get update \
    && apt-get upgrade -y \
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
