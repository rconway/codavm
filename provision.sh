#!/usr/bin/env bash
set -euo pipefail

SYSBOX_VERSION="0.7.1"
SYSBOX_DEB="sysbox-ce_${SYSBOX_VERSION}.linux_amd64.deb"
SYSBOX_URL="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/${SYSBOX_DEB}"
SSH_USER="vagrant"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq

# --- Docker Engine (official apt repo) -------------------------------------
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

usermod -aG docker "${SSH_USER}"
systemctl enable --now docker

# --- Sysbox (runs Docker/K8s containers as isolated, unprivileged system
#     containers via the sysbox-runc OCI runtime) ---------------------------
if ! command -v sysbox-runc &>/dev/null; then
  curl -fsSL -o "/tmp/${SYSBOX_DEB}" "${SYSBOX_URL}"

  # Sysbox's installer wants to stop any running containers before install.
  docker rm -f "$(docker ps -aq)" 2>/dev/null || true

  apt-get install -y "/tmp/${SYSBOX_DEB}"
  rm -f "/tmp/${SYSBOX_DEB}"
fi

# The sysbox package registers itself as a Docker runtime and restarts
# docker + sysbox services on install/upgrade, but make sure both are up.
systemctl enable --now sysbox
systemctl restart docker

echo "==> Provisioning complete. Docker + sysbox-runc are ready."
echo "==> Run containers with: docker run --runtime=sysbox-runc ..."
