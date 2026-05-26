# Default Connectivity for Nix hosts
NIXADDR ?= 192.168.0.38
NIXPORT ?= 22
NIXUSER ?= root

# Default harddrive for Nix host
NIXHDD ?= /dev/sda

# Switch Partition Labels
PARTION_LABEL := $(if $(filter /dev/nvme0n1,$(NIXHDD)),p,)

# Reusable SSH options
SSH_OPTIONS = -o PubkeyAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no

# Directory of Makefile
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# System name used in config
#NIXNAME ?= vm-x86_64-qemu
NIXNAME ?= nixos

# Switch OS configs
UNAME := $(shell uname)

# build and switch config. This command will build the selected system config and switch to the new state.
# To test if the config changes are valid, use `make check`. To "demo" the config without adding it to the 
# bootloader, run `make test`
switch:
	sudo nixos-rebuild switch --flake ".#${NIXNAME}"

# check config. This command will validate the whole config including all systems. To "demo" the config without
# adding it to the bootloader, run `make test`
check:
	nix flake check

# test config. This command will build the selected system config and switch to the new state WITHOUT adding
# the result to the bootloader selector. After rebooting, the system will return to the last "switched" state.
# Use `make switch` to add a change permanently.
test:
	sudo nixos-rebuild test --flake ".#${NIXNAME}"

# bootstrap a new VM. The VM should have booted the most recent ISO drive and its root user password
# set to "root". This command will create a partition schema and install nixos. Afterwards, the
# host must be rebooted.
#
# The partition schema follows the NixOS Manual
# (see: https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning)
vm/init:
	# create partition schema
	ssh $(SSH_OPTIONS) -p$(NIXPORT) root@$(NIXADDR) " \
		parted $(NIXHDD) -- mklabel gpt; \
		parted $(NIXHDD) -- mkpart root ext4 512MB -8GB; \
		parted $(NIXHDD) -- mkpart swap linux-swap -8GB 100%; \
		parted $(NIXHDD) -- mkpart ESP fat32 1MB 512MB; \
		parted $(NIXHDD) -- set 3 esp on; \
		sleep 1; \
		mkfs.ext4 -L nixos $(NIXHDD)$(PARTITION_LABEL)1; \
		mkswap -L swap $(NIXHDD)$(PARTITION_LABEL)2; \
		mkfs.fat -F 32 -n boot $(NIXHDD)$(PARTITION_LABEL)3; \
		sleep 1; \
		mount /dev/disk/by-label/nixos /mnt; \
		mkdir -p /mnt/boot; \
		mount -o umask=077 /dev/disk/by-label/boot /mnt/boot; \
		swapon $(NIXHDD)$(PARTITION_LABEL)2; \
		sleep 1; \
		nixos-generate-config --root /mnt; \
		sleep 1; \
		sed --in-place '/system\.stateVersion = .*/a \
			nix.package = pkgs.nixVersions.latest;\n \
			nix.extraOptions = \"experimental-features = nix-command flakes\";\n \
  		services.openssh.enable = true;\n \
			services.openssh.settings.PasswordAuthentication = true;\n \
			services.openssh.settings.PermitRootLogin = \"yes\";\n \
			users.users.root.initialPassword = \"root\";\n \
		' /mnt/etc/nixos/configuration.nix; \
		nixos-install --no-root-passwd && reboot; \
	"
	# wait until host is back up
	@until ssh $(SSH_OPTIONS) -p$(NIXPORT) -o ConnectTimeout=5 root@$(NIXADDR) true; do \
		sleep 2; \
	done
	# copy config
	NIXUSER=root $(MAKE) vm/copy
	# build config
	NIXUSER=root $(MAKE) vm/switch
	# done

# copy keys to VM. This command will copy the .ssh and other key-stores to the vm specified.
vm/keys:
	# SSH keys
	rsync -av -e 'ssh $(SSH_OPTIONS)' \
		--exclude='environment' \
		--exclude='known_hosts' \
		--exclude='known_hosts.old' \
		$(HOME)/.ssh/ $(NIXUSER)@$(NIXADDR):~/.ssh

# copy config to VM. This command will copy all config files from this repo to the vm specified. Git-
# Checkout branch 'main' for the latest stable version.
vm/copy:
	rsync -av -e 'ssh $(SSH_OPTIONS) -p$(NIXPORT)' \
		--exclude='.git/' \
		--exclude='docs/' \
		--exclude='iso/' \
		--rsync-path="sudo rsync" \
		$(MAKEFILE_DIR)/ $(NIXUSER)@$(NIXADDR):/nix-config

# switch config on VM. This command will build the config stored in /vim-config on the vm. Use vm/copy
# to update the config directory.
vm/switch:
	ssh -tt $(SSH_OPTIONS) -p$(NIXPORT) $(NIXUSER)@$(NIXADDR) " \
		sudo NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nixos-rebuild switch --flake \"/nix-config#${NIXNAME}\" \
	"

# build config for WSL. This command will build the config for a wsl istance and stores the outputs in
# ./result/tarball. Copy that to the windows machine and run the follwing commands
#
# `wsl --import nixos .\nixos .\path\to\nixos\tarball.tar.gz`
#
#	`wsl -d nixos`
wsl:
	nix build ".#nixosConfigurations.wsl.config.system.build.tarballBuilder"
