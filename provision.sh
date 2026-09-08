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
  jq \
  zsh

chsh -s "$(command -v zsh)" "${SSH_USER}" || usermod -s "$(command -v zsh)" "${SSH_USER}"

# --- oh-my-zsh --------------------------------------------------------------
if ! sudo -u "${SSH_USER}" test -d "/home/${SSH_USER}/.oh-my-zsh"; then
  # The installer can exit non-zero here despite completing successfully
  # (e.g. trying to exec an interactive zsh with no TTY); `|| true` avoids
  # that tripping `set -e`, and the `test -d` guard covers real failures.
  sudo -u "${SSH_USER}" sh -c \
    'export RUNZSH=no CHSH=no; sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
    </dev/null || true
  sudo -u "${SSH_USER}" test -d "/home/${SSH_USER}/.oh-my-zsh"
fi

sed -i \
  -e 's/^ZSH_THEME=.*/ZSH_THEME="bira"/' \
  -e 's/^plugins=(.*/plugins=()/' \
  "/home/${SSH_USER}/.zshrc"

ZSHRC="/home/${SSH_USER}/.zshrc"
if ! grep -qF 'scripts/dotfiles/zshrc' "${ZSHRC}"; then
  cat >>"${ZSHRC}" <<'EOF'

if [ -f $HOME/scripts/dotfiles/zshrc ]; then
  source $HOME/scripts/dotfiles/zshrc
fi
EOF
fi

# --- Atuin (shell history sync/search) -------------------------------------
if ! sudo -u "${SSH_USER}" test -x "/home/${SSH_USER}/.atuin/bin/atuin"; then
  # --non-interactive skips all setup prompts outright (avoids relying on
  # /dev/tty absence, which isn't reliable under Vagrant's shell provisioner).
  sudo -u "${SSH_USER}" bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://setup.atuin.sh | sh -s -- --non-interactive' </dev/null
fi

# --- Clone repos (relies on the SSH keypair provisioned above) -------------
if sudo -u "${SSH_USER}" test -f "/home/${SSH_USER}/.ssh/id_rsa"; then
  for repo in \
    "git@github.com:rconway/scripts" \
    "git@github.com:rconway/localcoda" \
    "git@github.com:EOEPCA/eoepca-killercoda"; do
    dest="$(basename "${repo}")"
    if ! sudo -u "${SSH_USER}" test -d "/home/${SSH_USER}/${dest}"; then
      # accept-new: trust the host key on first connect instead of a
      # separate ssh-keyscan step; don't let one failed clone (e.g. auth
      # not yet set up for a given repo) abort the rest of provisioning.
      sudo -u "${SSH_USER}" env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
        git -C "/home/${SSH_USER}" clone "${repo}" \
        || echo "==> WARNING: failed to clone ${repo}, continuing"
    fi
  done
fi

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
