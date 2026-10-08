# -*- mode: ruby -*-
# vi: set ft=ruby :

require "ipaddr"

def positive_integer_env(name, default)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  abort "#{name} must be a positive integer" unless value.positive?
  value
rescue ArgumentError
  abort "#{name} must be a positive integer"
end

def ipv4_env(name, default)
  value = ENV.fetch(name, default)
  address = IPAddr.new(value)
  abort "#{name} must be an IPv4 address" unless address.ipv4? && value.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/)
  value
rescue IPAddr::InvalidAddressError
  abort "#{name} must be an IPv4 address"
end

# Host-overridable VM resource defaults (memory in MB, disk in GB).
VM_CPUS = positive_integer_env("CODAVM_CPUS", 4)
VM_MEMORY_MB = positive_integer_env("CODAVM_MEMORY_MB", 8192)
VM_DISK_GB = positive_integer_env("CODAVM_DISK_GB", 64)

# Host-overridable guest addresses on each provider's private network.
VBOX_IP = ipv4_env("CODAVM_VBOX_IP", "192.168.56.10")
LIBVIRT_IP = ipv4_env("CODAVM_LIBVIRT_IP", "172.28.128.100")
LOCALCODA_BRANCH = ENV.fetch("CODAVM_LOCALCODA_BRANCH", "eoepca-2.1")
TUTORIALS_BRANCH = ENV.fetch("CODAVM_TUTORIALS_BRANCH", "eoepca-2.1")
VM_NAME = ENV.fetch("CODAVM_NAME", "codavm")
VM_HOSTNAME = ENV.fetch("CODAVM_HOSTNAME", "codavm")
# Optional: a routable DNS domain (e.g. mydomain.com) to use instead of the
# nip.io domain derived from the guest's private network IP.
EXT_DOMAIN_NAME = ENV.fetch("CODAVM_EXT_DOMAIN_NAME", "")
# Ports used by Localcoda tutorials. Forwarded from the host when EXT_DOMAIN_NAME is set.
PORT_MIN = positive_integer_env("CODAVM_PORT_MIN", 20000)
PORT_MAX = positive_integer_env("CODAVM_PORT_MAX", 20009)

Vagrant.configure("2") do |config|
  # Defaults the machine name to "codavm" instead of Vagrant's "default"
  # (affects `vagrant ssh-config` Host entry, libvirt domain name, log prefixes, etc).
  config.vm.define VM_NAME

  # Ubuntu 24.04 (kernel 6.8+) has native ID-mapped mount support, which
  # Sysbox needs and which avoids having to build/install the shiftfs module.
  config.vm.box = "bento/ubuntu-24.04"
  # Later versions have no libvirt build.
  config.vm.box_version = "202508.03.0"

  config.vm.hostname = VM_HOSTNAME

  # VirtualBox
  config.vm.provider :virtualbox do |vb, override|
    vb.memory = VM_MEMORY_MB
    vb.cpus = VM_CPUS
    override.vm.disk :disk, size: "#{VM_DISK_GB}GB", primary: true
    override.vm.network "private_network", ip: VBOX_IP
  end

  # libvirt
  config.vm.provider :libvirt do |lv, override|
    lv.memory = VM_MEMORY_MB
    lv.cpus = VM_CPUS
    lv.machine_virtual_size = VM_DISK_GB
    override.vm.network "private_network", ip: LIBVIRT_IP

    # Works around a vagrant-libvirt bug where the auto-detected custom CPU
    # model ends up with a vendor but no model in the generated domain XML,
    # causing "CPU vendor specified without CPU model" on redefine.
    lv.cpu_mode = "host-passthrough"
  end

  # Expand the partition, LVM physical volume, logical volume, and filesystem.
  config.vm.provision "shell", name: "expand-root-disk", inline: <<-SHELL
    set -eu
    pv_device=$(pvs --noheadings -o pv_name | xargs)
    parent_device=$(lsblk -dnro PKNAME "$pv_device")
    partition_number=$(lsblk -dnro PARTN "$pv_device")
    growpart "/dev/$parent_device" "$partition_number" || [ "$?" -eq 1 ]
    pvresize "$pv_device"
    free_extents=$(vgs --noheadings -o vg_free_count ubuntu-vg | xargs)
    if [ "$free_extents" -gt 0 ]; then
      lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
    fi
    resize2fs /dev/ubuntu-vg/ubuntu-lv
  SHELL

  # With a routable domain, browsers reach the tutorials through the host, so forward the tutorial ports to the VM.
  unless EXT_DOMAIN_NAME.empty?
    (PORT_MIN..PORT_MAX).each do |port|
      config.vm.network "forwarded_port", guest: port, host: port, host_ip: "0.0.0.0"
    end
  end

  # Required for VS Code Remote-SSH / Dev Containers to work smoothly.
  config.ssh.forward_agent = true

  # Carry the host's git identity into the VM, if present.
  host_git_configs = [
    ["~/.config/git/config", ".config/git/config"],
    ["~/.gitconfig", ".gitconfig"]
  ].filter_map do |host_path, guest_path|
    path = File.expand_path(host_path)
    [path, guest_path] if File.exist?(path)
  end
  host_git_configs.each do |host_path, guest_path|
    # Remove any prior copy first: SCP preserves the source file's mode, and
    # a read-only source produces a guest file that a later re-provision
    # can't overwrite.
    setup = guest_path.start_with?(".config/") ? "mkdir -p ~/.config/git && " : ""
    config.vm.provision "shell", inline: "#{setup}rm -f ~/#{guest_path}", privileged: false
    config.vm.provision "file", source: host_path, destination: guest_path
  end

  # Carry the host's SSH keypair into the VM, if present (e.g. for git over SSH).
  # Preference order matches ssh(1)'s default identity file search. Declared
  # before provision.sh's registration below so it runs before provision.sh,
  # which relies on the key already being in place.
  key_basename = ["id_ed25519", "id_ecdsa", "id_rsa"].find do |name|
    File.exist?(File.expand_path("~/.ssh/#{name}"))
  end
  if key_basename
    host_ssh_key = File.expand_path("~/.ssh/#{key_basename}")
    config.vm.provision "shell", inline: "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/#{key_basename} ~/.ssh/#{key_basename}.pub", privileged: false
    config.vm.provision "file", source: host_ssh_key, destination: ".ssh/#{key_basename}"
    config.vm.provision "file", source: "#{host_ssh_key}.pub", destination: ".ssh/#{key_basename}.pub"
    config.vm.provision "shell", inline: "chmod 600 ~/.ssh/#{key_basename} && chmod 644 ~/.ssh/#{key_basename}.pub", privileged: false
  end

  # Run the core provisioning script. Declared after the git-config/SSH-key
  # provisioners above so it runs after them (it relies on the key already
  # being in place).
  config.vm.provider :virtualbox do |vb, override|
    override.vm.provision "shell", path: "provision.sh", env: {
      "EXT_IP_ADDR" => VBOX_IP,
      "EXT_DOMAIN_NAME" => EXT_DOMAIN_NAME,
      "PORT_MIN" => PORT_MIN.to_s,
      "PORT_MAX" => PORT_MAX.to_s,
      "LOCALCODA_BRANCH" => LOCALCODA_BRANCH,
      "TUTORIALS_BRANCH" => TUTORIALS_BRANCH
    }
  end

  config.vm.provider :libvirt do |lv, override|
    override.vm.provision "shell", path: "provision.sh", env: {
      "EXT_IP_ADDR" => LIBVIRT_IP,
      "EXT_DOMAIN_NAME" => EXT_DOMAIN_NAME,
      "PORT_MIN" => PORT_MIN.to_s,
      "PORT_MAX" => PORT_MAX.to_s,
      "LOCALCODA_BRANCH" => LOCALCODA_BRANCH,
      "TUTORIALS_BRANCH" => TUTORIALS_BRANCH
    }
  end

  # Save the ssh-config to a local file after the VM is brought up.
  # This can then be included in your SSH client configuration for easy access to the VM.
  # e.g. with 'Include <path_to_this_directory>/ssh-config'
  config.trigger.after :up do |trigger|
    trigger.info = "Updating ./ssh-config"
    trigger.run = {
      inline: "bash -c 'vagrant ssh-config > ssh-config'"
    }
  end
end
