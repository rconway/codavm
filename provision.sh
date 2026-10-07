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

# --- Clone repos -------------------------------------------------------
# Public repos are cloned over https so they work without any SSH key.
REPOS=(
  "https://github.com/EOEPCA/localcoda"
  "https://github.com/EOEPCA/eoepca-killercoda"
)
EOEPCA_KILLERCODA_BRANCH="${EOEPCA_KILLERCODA_BRANCH:-eoepca-2.1}"

# Shared by custom hooks: true if the SSH keypair carried in from the host
# (see Vagrantfile) is present, checking the same names/order as ssh(1).
has_ssh_key() {
  local name
  for name in id_ed25519 id_ecdsa id_rsa; do
    sudo -u "${SSH_USER}" test -f "/home/${SSH_USER}/.ssh/${name}" && return 0
  done
  return 1
}

# Shared by custom hooks (run at the end of this script) so they can clone
# extra repos using the same guard/retry behavior as the core repos.
clone_repo() {
  local repo="$1"
  local dest
  dest="$(basename "${repo}")"
  if ! sudo -u "${SSH_USER}" test -d "/home/${SSH_USER}/${dest}"; then
    # accept-new: trust the host key on first connect instead of a
    # separate ssh-keyscan step; don't let one failed clone (e.g. auth
    # not yet set up for a given repo) abort the rest of provisioning.
    sudo -u "${SSH_USER}" env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
      git -C "/home/${SSH_USER}" clone "${repo}" \
      || echo "==> WARNING: failed to clone ${repo}, continuing"
  fi
}

# Clone the specified REPOS
for repo in "${REPOS[@]}"; do
  clone_repo "${repo}"
done

# If the user's SSH key is available, configure to use SSH for git pushes (fetches keep using https, needing no key)
# since this user has push access to them via their own SSH key.
if has_ssh_key; then
  for repo in "${REPOS[@]}"; do
    [[ "${repo}" == https://github.com/* ]] || continue
    dest="$(basename "${repo}")"
    ssh_url="$(sed -E 's#https://github.com/(.+)#git@github.com:\1#' <<<"${repo}")"
    sudo -u "${SSH_USER}" git -C "/home/${SSH_USER}/${dest}" remote set-url --push origin "${ssh_url}"
  done
fi

# MODS for localcoda repos
#
# Use sysbox as the virtualization engine for localcoda
conf_file="/home/${SSH_USER}/localcoda/backend/cfg/conf"
sed -i "s/^VIRT_ENGINE=.*/VIRT_ENGINE=sysbox/" "${conf_file}"
grep -qFx "VIRT_ENGINE=sysbox" "${conf_file}" \
  || echo "VIRT_ENGINE=sysbox" >>"${conf_file}"
#
# Set EXT_DOMAIN_NAME: use the caller-supplied domain if given (e.g. a
# routable DNS domain such as mydomain.com), otherwise derive a nip.io
# domain from the external IP address provided by Vagrant.
if [ -n "${EXT_DOMAIN_NAME:-}" ]; then
  domain_name=".${EXT_DOMAIN_NAME}"
else
  hexip="$(printf '%02x%02x%02x%02x' ${EXT_IP_ADDR//./ })"
  domain_name=".${hexip}.nip.io"
fi
# Appends the setting if the sed pattern below matched nothing (0 substitutions).
sed -i "s/^EXT_DOMAIN_NAME=.*/EXT_DOMAIN_NAME=${domain_name}/" "${conf_file}"
grep -qFx "EXT_DOMAIN_NAME=${domain_name}" "${conf_file}" \
  || echo "EXT_DOMAIN_NAME=${domain_name}" >>"${conf_file}"
#
# Keep tutorials within the port range forwarded by the Vagrantfile
sed -i "s/^LOCAL_RANDOMPORT_MIN=.*/LOCAL_RANDOMPORT_MIN=${PORT_MIN}/" "${conf_file}"
sed -i "s/^LOCAL_RANDOMPORT_MAX=.*/LOCAL_RANDOMPORT_MAX=${PORT_MAX}/" "${conf_file}"
# End of localcoda repo modifications

# MODS for eoepca-killercoda repos
#
# Switch to the appropriate branch for eoepca-killercoda
sudo -u "${SSH_USER}" env BRANCH="${EOEPCA_KILLERCODA_BRANCH}" bash <<'SCRIPT'
cd "$HOME/eoepca-killercoda" && git switch "$BRANCH" ; cd "$HOME"
envfile="$HOME/eoepca-killercoda/.env"
grep -qxF 'export LOCALCODA_ROOT="../localcoda"' "$envfile" 2>/dev/null ||
  echo 'export LOCALCODA_ROOT="../localcoda"' >>"$envfile"
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

# --- Configure Docker to use the VM's DNS resolver via the bridge network IP ---
# (libvirt doesn't answer short service names, which makes gRPC lookups time out)
#
# Deduce the docker bridge IP, which will be used as the DNS resolver for containers.
DOCKER_BRIDGE_IP="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
#
# Configure systemd-resolved to listen on the Docker bridge IP
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/docker-bridge.conf <<EOF
[Resolve]
DNSStubListenerExtra=${DOCKER_BRIDGE_IP}
EOF
systemctl restart systemd-resolved
#
# Update Docker daemon configuration to use the Docker bridge IP as the DNS server for containers.
jq --arg ip "${DOCKER_BRIDGE_IP}" '.dns = [$ip]' /etc/docker/daemon.json >/tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json
# ---

# The sysbox package registers itself as a Docker runtime and restarts
# docker + sysbox services on install/upgrade, but make sure both are up.
systemctl enable --now sysbox
systemctl restart docker

echo "==> Provisioning complete. Docker + sysbox-runc are ready."
echo "==> Run containers with: docker run --runtime=sysbox-runc ..."

# --- Custom provisioning hooks -----------------------------------------
# Optional, user-specific customizations live in provision.d/ (synced from
# the project directory via Vagrant's default /vagrant share). Every *.sh
# script found there is run in name-sorted order, after all core
# provisioning above has completed; core provisioning works standalone even
# if provision.d/ is absent or empty.
HOOKS_DIR="/vagrant/provision.d"
if [ -d "${HOOKS_DIR}" ]; then
  for hook in "${HOOKS_DIR}"/*.sh; do
    [ -e "${hook}" ] || continue
    echo "==> Running custom hook: $(basename "${hook}")"
    # shellcheck disable=SC1090
    source "${hook}"
  done
fi
