# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Names the machine "codavm" instead of the default "default" (affects
  # `vagrant ssh-config` Host entry, libvirt domain name, log prefixes, etc).
  config.vm.define "codavm"

  # Ubuntu 24.04 (kernel 6.8+) has native ID-mapped mount support, which
  # Sysbox needs and which avoids having to build/install the shiftfs module.
  config.vm.box = "bento/ubuntu-24.04"

  config.vm.hostname = "codavm"

  # VirtualBox
  config.vm.disk :disk, size: "60GB", primary: true
  config.vm.provider :virtualbox do |vb|
    vb.memory = 8192
    vb.cpus = 4
  end

  # libvirt
  config.vm.provider :libvirt do |lv|
    lv.memory = 8192
    lv.cpus = 4
    lv.machine_virtual_size = 60
  end

  # Expand the file-system to the disk size
  config.vm.provision "shell", inline: <<-SHELL
    lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
    resize2fs /dev/ubuntu-vg/ubuntu-lv
  SHELL

  # Required for VS Code Remote-SSH / Dev Containers to work smoothly.
  config.ssh.forward_agent = true

  # Carry the host's git identity into the VM, if present.
  host_git_config = File.expand_path("~/.config/git/config")
  if File.exist?(host_git_config)
    # Remove any prior copy first: SCP preserves the source file's mode, and
    # a read-only source produces a guest file that a later re-provision
    # can't overwrite.
    config.vm.provision "shell", inline: "mkdir -p ~/.config/git && rm -f ~/.config/git/config", privileged: false
    config.vm.provision "file", source: host_git_config, destination: ".config/git/config"
  end

  # Carry the host's SSH keypair into the VM, if present (e.g. for git over SSH).
  host_ssh_key = File.expand_path("~/.ssh/id_rsa")
  if File.exist?(host_ssh_key)
    config.vm.provision "shell", inline: "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub", privileged: false
    config.vm.provision "file", source: host_ssh_key, destination: ".ssh/id_rsa"
    config.vm.provision "file", source: "#{host_ssh_key}.pub", destination: ".ssh/id_rsa.pub"
    config.vm.provision "shell", inline: "chmod 600 ~/.ssh/id_rsa && chmod 644 ~/.ssh/id_rsa.pub", privileged: false
  end

  config.vm.provision "shell", path: "provision.sh"
end
