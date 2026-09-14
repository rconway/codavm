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
  sudo -u "${SSH_USER}" bash <<'SCRIPT'
curl --proto "=https" --tlsv1.2 -sSf https://setup.atuin.sh | sh -s -- --non-interactive
SCRIPT
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

# Helper function to apply a git patch if it hasn't been applied already
apply_patch() {
  patchfile=$(mktemp)
  cat >"$patchfile"
  chmod 644 "$patchfile"
  sudo -u "${SSH_USER}" PATCHNAME="$1" REPOS="$2" PATCHFILE="$patchfile" bash <<'SCRIPT'
cd "$REPOS"
if ! git apply --reverse --check "$PATCHFILE" 2>/dev/null; then
  echo "==> Applying patch $PATCHNAME"
  git apply "$PATCHFILE"
  echo "==> DONE: Applied patch $PATCHNAME"
else
  echo "==> Patch $PATCHNAME already applied" >&2
fi
SCRIPT
  rm -f "$patchfile"
}

# MODS for localcoda repo
#
# docker registries configuration
sudo -u "${SSH_USER}" bash <<'SCRIPT'
cat <<EOF >"$HOME/localcoda/registries.yaml"
mirrors:
  "docker.io":
    endpoint:
      - http://docker.io.registry.c0a80032.nip.io:5000
  "ghcr.io":
    endpoint:
      - http://ghcr.io.registry.c0a80032.nip.io:5000
  "quay.io":
    endpoint:
      - http://quay.io.registry.c0a80032.nip.io:5000
configs:
  "docker.io":
    tls:
      insecure: true
  "ghcr.io":
    tls:
      insecure: true
  "quay.io":
    tls:
      insecure: true
EOF
SCRIPT
#
# Use sysbox as the virtualization engine for localcoda
cat <<'EOF' | apply_patch "engine" "/home/${SSH_USER}/localcoda"
diff --git a/backend/cfg/conf b/backend/cfg/conf
index ac9af93..6d4ee30 100644
--- a/backend/cfg/conf
+++ b/backend/cfg/conf
@@ -1,6 +1,6 @@
 ##General configuration options
 #Allowed virtualization engines supported for backend are docker or sysbox. Frontend will always use docker.
-VIRT_ENGINE=docker
+VIRT_ENGINE=sysbox
 #Allowed orchestration engines supported at the moment are local and kubernetes
 ORCHESTRATION_ENGINE=local
 #Default tutorial duration (in seconds). Set to "-1" to disable.
EOF
#
# Use custom registries.yaml for k3s
cat <<'EOF' | apply_patch "registries" "/home/${SSH_USER}/localcoda"
diff --git a/backend/cfg/conf b/backend/cfg/conf
index ac9af93..68f0830 100644
--- a/backend/cfg/conf
+++ b/backend/cfg/conf
@@ -38,6 +38,7 @@ REMOTE_PORT=1
 #Custom registries.yaml file for k3s
 #Note that this file will be mounted into the backend container at /etc/rancher/k3s/registries.yaml and will be used by k3s when starting the tutorial containers. Can be used to (for example) supply credentials for DockerHub or other private registries - or to configure alternate registries, such as a pull-through cache.
 #K3S_REGISTRY_YAML="/path/to/your/k3s/registries.yaml"
+K3S_REGISTRY_YAML="$HOME/localcoda/registries.yaml"
 ##Advanced configuration - LOCAL ORCHESTRATOR
 #Local orchestration engine mount port for backend. If you want to start multiple docker backends on the same machine you will need to set the port to \$RANDOM_PORT in order for the different containers not to clash. This will add also the port to EXT_DOMAIN_NAME and properly update all the urls
 LOCAL_INT_IPPORT=0.0.0.0:\$RANDOM_PORT
EOF
# End of localcoda repo modifications

# MODS for eoepca-killercoda repos
#
# Switch to the appropriate branch for eoepca-killercoda
sudo -u "${SSH_USER}" bash <<'SCRIPT'
cd "$HOME/eoepca-killercoda" && git switch eoepca-2.1 ; cd "$HOME"
envfile="$HOME/eoepca-killercoda/.env"
grep -qxF 'export LOCALCODA_ROOT="../localcoda"' "$envfile" 2>/dev/null ||
  echo 'export LOCALCODA_ROOT="../localcoda"' >>"$envfile"
SCRIPT
# Deploy k9s for each tutorial
sudo -u "${SSH_USER}" bash <<'SCRIPT'
cd "$HOME"
find $HOME/eoepca-killercoda -path "$HOME/eoepca-killercoda/commons" -prune \
  -o -name assets -type d -exec ln -snfr $HOME/eoepca-killercoda/commons/assets/k9s {} \;
SCRIPT
# End of eoepca-killercoda repo modifications

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
