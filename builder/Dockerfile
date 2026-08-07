FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Base tools needed to configure APT and prepare Proxmox installation media.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gpg \
        xorriso \
    && rm -rf /var/lib/apt/lists/*

# Install the official Proxmox Trixie repository signing key.
RUN curl --fail --location \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        --output /usr/share/keyrings/proxmox-archive-keyring.gpg

# The no-subscription repository is suitable for this build/test tooling.
# A subscription repository could be substituted in managed environments.
RUN printf '%s\n' \
      'Types: deb' \
      'URIs: http://download.proxmox.com/debian/pve' \
      'Suites: trixie' \
      'Components: pve-no-subscription' \
      'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/proxmox.sources

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        proxmox-auto-install-assistant \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY build.sh /usr/local/bin/build-proxmox-pxe

RUN chmod 0755 /usr/local/bin/build-proxmox-pxe

ENTRYPOINT ["build-proxmox-pxe"]
