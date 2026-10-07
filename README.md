# Coda VM

This repository defines a Vagrant VM primarily as a self-contained environment for running the EOEPCA Localcoda tutorials. Provisioning installs Docker and Sysbox, then clones `localcoda` and `eoepca-killercoda` into the VM's `vagrant` home directory. The VM can also be used for development; when available, your host SSH key and Git configuration are copied into the VM, allowing you to push to Git repositories over SSH.

## Requirements

- Git and [Vagrant](https://developer.hashicorp.com/vagrant) installed on the host<br>
  _Vagrant 2.1.0 or newer for trigger support; check your provider plugin’s compatibility requirements._
  - [Vagrant download and install](https://developer.hashicorp.com/vagrant/install)
- One Vagrant [provider](https://developer.hashicorp.com/vagrant/docs/providers) installed and usable by your user:<br>
  _Note that the VM is intended for headless use; no graphical console or desktop is required_
  - **VirtualBox:** install Oracle VirtualBox
    - [Download and install](https://www.virtualbox.org/wiki/Downloads)
    - [Provider docs](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox)
  - **libvirt:** install and configure libvirt/QEMU for your host, then install the Vagrant provider plugin with `vagrant plugin install vagrant-libvirt`. The plugin may also require host development libraries; follow the `vagrant-libvirt` installation instructions for your distribution.

The default VM resources are 4 CPUs, 8 GB RAM, and a 64 GB disk. Make sure the host has enough available resources. These host environment variables configure the Vagrant machine name, guest hostname, VM resources, guest addresses, and tutorial branch:

| Environment variable | Default | Setting |
| --- | ---: | --- |
| `CODAVM_CPUS` | `4` | Virtual CPUs |
| `CODAVM_MEMORY_MB` | `8192` | Memory in MB |
| `CODAVM_DISK_GB` | `64` | Disk size in GB |
| `CODAVM_VBOX_IP` | `192.168.56.10` | VirtualBox guest IP |
| `CODAVM_LIBVIRT_IP` | `172.28.128.100` | libvirt guest IP |
| `CODAVM_KILLERCODA_BRANCH` | `eoepca-2.1` | Tutorial repository branch |
| `CODAVM_NAME` | `codavm` | Vagrant machine name (SSH config host and libvirt domain) |
| `CODAVM_HOSTNAME` | `codavm` | Guest hostname |
| `CODAVM_EXT_DOMAIN_NAME` | *(none)* | Routable DNS domain (e.g. `mydomain.com`) to use instead of the nip.io domain derived from the guest IP |
| `CODAVM_PORT_MIN` | `20000` | First Localcoda tutorial port to configure and forward |
| `CODAVM_PORT_MAX` | `20009` | Last Localcoda tutorial port to configure and forward |

By default, tutorial URLs use a nip.io domain derived from the VM's private IP. To use a routable domain instead, set `CODAVM_EXT_DOMAIN_NAME` before starting the VM and configure wildcard DNS for that domain to resolve to the Vagrant host's reachable IP address. When an external domain is set, Vagrant forwards the configured tutorial port range from the host to the VM on all host interfaces; allow that range through the host firewall and any upstream firewall. The port bounds must include the ports assigned by Localcoda tutorials.

For example, if wildcard DNS for `tutorials.example.com` points to the host, configure the VM and start it with:

```sh
export CODAVM_EXT_DOMAIN_NAME=tutorials.example.com
export CODAVM_PORT_MIN=20000
export CODAVM_PORT_MAX=20009
vagrant up --provider=libvirt
```

Leave `CODAVM_EXT_DOMAIN_NAME` unset to keep using nip.io URLs without forwarding tutorial ports from the host.

For example, to use fewer resources with libvirt:

```sh
export CODAVM_CPUS=2
export CODAVM_MEMORY_MB=4096
export CODAVM_DISK_GB=40
vagrant up --provider=libvirt
```

Keep the variables set for later Vagrant commands in that shell so its configuration continues to match the VM. Resource values must be positive integers; IP overrides must be IPv4 addresses. Initial startup provisions Ubuntu, installs Docker and Sysbox, and clones the tutorial repositories, so allow time for downloads and ensure the host has internet access.

The provider IP variables are optional. If you override one, choose an unused IPv4 address on that provider's private network; the configured address is also used to derive the tutorial environment's nip.io domain. For example, to change the libvirt guest IP:

```sh
export CODAVM_LIBVIRT_IP=172.28.128.110
vagrant up --provider=libvirt
```

## Start the VM

Clone this repository on the host and enter its directory:

```sh
git clone https://github.com/rconway/codavm.git
cd codavm
```

Start the VM using your chosen provider. Specify the provider explicitly if more than one is installed:

```sh
vagrant up --provider=virtualbox
```

Or, for libvirt:

```sh
vagrant up --provider=libvirt
```

Vagrant downloads the Ubuntu box the first time it is needed.

## Connect to the VM

When provisioning finishes, connect to the VM:

```sh
vagrant ssh
```

The VM is intended for headless use; no graphical console or desktop is required. Once it is running, work inside it over SSH.

You can use `vagrant ssh`, a regular SSH client, or connect from VS Code with Remote-SSH using the generated `ssh-config` file (see [VM lifecycle](#vm-lifecycle)).

To make the VM's SSH host available through your normal SSH configuration, add an `Include` for the generated file at the top of `~/.ssh/config`, replacing the placeholder with the path to your local codavm directory:

```sshconfig
Include <path-to-your-codavm-dir>/ssh-config
```

## Run a tutorial

If not already connected to the VM via SSH, do so first:

```sh
vagrant ssh
```

In the VM, change to the tutorials checkout and run a tutorial by its directory name:

```sh
cd ~/eoepca-killercoda
./run.sh discovery
```

Replace `discovery` with the name of another tutorial directory in `eoepca-killercoda`.

Alternatively, you can connect and run the tutorial in a single command:

```sh
vagrant ssh -c "./eoepca-killercoda/run.sh discovery"
```

Once the tutorial is running then the terminal output provides the URL to connect in your browser.

## Tutorial branch selection

Provisioning checks out the `eoepca-2.1` branch by default and configures the tutorial environment to use the neighboring `~/localcoda` checkout. To use a different branch, set the override before creating the VM:

```sh
export CODAVM_KILLERCODA_BRANCH=my-feature-branch
vagrant up --provider=virtualbox
```

For an existing VM, set the variable and run `vagrant provision` to switch its checkout to that branch. Alternatively you can directly switch the branch from within the VM.

## VM lifecycle

Run these commands from the host, in this repository's directory:

```sh
vagrant halt       # stop the VM
vagrant up         # start it again
vagrant destroy    # delete the VM and its virtual disk
```

The generated `ssh-config` file can also be used to connect with a regular SSH client:

```sh
ssh -F ssh-config "${CODAVM_NAME:-codavm}"
```

The VM is disposable: `vagrant destroy` removes its disk, including the cloned repositories and any tutorial data stored in the VM.

## Custom provisioning

The core setup in `provision.sh` is extended by shell hooks in `provision.d/`. During provisioning, every `*.sh` hook in that directory is sourced automatically, in filename order, after the core packages and repositories are set up. Hooks can therefore apply machine- or user-specific configuration without changing the reusable core script. The directory can be empty or absent; numeric filename prefixes such as `10-` and `20-` control the order when multiple hooks are used.

Hooks run in the provisioning script's shell context and can use its variables and helper functions. Treat them as provisioning code: review what they do before running `vagrant up` or `vagrant provision`. See the [provision.d README](provision.d/README.md) for the hook interface, available helpers, and examples.

The [contributed k9s hook](provision.d/contrib/10-enable-k9s-for-all-tutorials.sh) is an example that enables k9s assets for all tutorials. Files under `contrib/` are not loaded automatically. To include this hook, copy it into `provision.d/` or create a symbolic link there. Run either command from the `provision.d/` directory:

```sh
cp ./contrib/10-enable-k9s-for-all-tutorials.sh .
# Or:
ln -s ./contrib/10-enable-k9s-for-all-tutorials.sh .
```

## Notes

- The Vagrantfile supports VirtualBox and libvirt. The provider selected by `vagrant up` must be installed on the host.
- Provisioning configures Docker to use the VM's local DNS resolver, including on libvirt, so containers can resolve tutorial service names.
- If present on the host, Vagrant copies an SSH key and the host Git config (`~/.config/git/config` and/or `~/.gitconfig`) into the guest during provisioning. This makes it possible to use your Git identity and push to repositories over SSH from the VM.
- If provisioning needs to be rerun after a change, use `vagrant provision` from the host repository directory - or sometimes `vagrant reload --provision` if the VM needs to be restarted as well.
