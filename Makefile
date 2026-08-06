# Default Connectivity for Nix hosts
NIXADDR ?= 192.168.0.152
NIXPORT ?= 22
NIXUSER ?= root

# System name used in config (defined before CONF_LUKS below — it needs it)
NIXNAME ?= laptop

# Default harddrive for Nix host
# To get the right device name run `lsblk` on the host and look for the device with the size matching your drives specs except for the boot drive
NIXHDD ?= /dev/nvme0n1

# Encrypt root during `make init`. Must match hosts/$(NIXNAME)'s luksEnable,
# init aborts on a mismatch.
LUKS ?= true

# luksEnable value read from the target host config, ignoring comment lines.
# (No sed backreferences here — GNU Make's $(shell) on this box silently
# empties any \(...\) capture group, so extraction goes through grep -oE.)
CONF_LUKS := $(shell grep -oE 'luksEnable[[:space:]]*=[[:space:]]*(true|false)' hosts/$(NIXNAME)/configuration.nix | grep -oE '(true|false)$$' | head -n1)

# --include for the user being deployed, expanded into `copy`'s rsync call
# below. NIXUSER is already the account this host is being built for
USER_INCLUDES := --include='users/$(NIXUSER)/' --include='users/$(NIXUSER)/**'

# Switch Partition Labels
PARTITION_LABEL := $(if $(filter /dev/nvme0n1,$(NIXHDD)),p,)

# Reusable SSH options
# Option to use pubkey auth to prevent password prompts by passing SSH_KEY=path/to/key, e.g.:
# make vm/switch SSH_KEY=~/.ssh/id_ed25519
SSH_KEY_NORM := $(subst \,/,$(SSH_KEY))
SSH_OPTIONS = -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $(if $(SSH_KEY_NORM),-i $(SSH_KEY_NORM),-o PubkeyAuthentication=no)

# Directory of Makefile
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Windows: force ssh to resolve next to rsync, or mixing MSYS runtimes
# (e.g. MSYS2 + Git for Windows) breaks signal handling and rsync dies.
RSYNC_BINDIR := $(shell dirname "$$(command -v rsync)" 2>/dev/null)

# Switch OS configs
UNAME := $(shell uname)

# build and switch config. This command will build the selected system config and switch to the new state.
# To test if the config changes are valid, use `make check`. To "demo" the config without adding it to the 
# bootloader, run `make test`
conf/switch:
	sudo nixos-rebuild switch --flake ".#${NIXNAME}" --impure

# check config. This command will validate the whole config including all systems. To "demo" the config without
# adding it to the bootloader, run `make test`
conf/check:
	nix flake check --impure

# test config. This command will build the selected system config and switch to the new state WITHOUT adding
# the result to the bootloader selector. After rebooting, the system will return to the last "switched" state.
# Use `make switch` to add a change permanently.
conf/test:
	sudo nixos-rebuild test --flake ".#${NIXNAME}" --impure

# Bootstrap a NixOS host from an installer ISO/.img with root password "root".
# Set NIXADDR/NIXPORT/NIXHDD/NIXNAME first. Partitions, installs, reboots —
# once it's back up, run `make copy-switch`. Partition schema per the NixOS
# manual: https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning
init:
	# safety check: LUKS flag must match what the target host config expects,
	# so `make init` can't silently encrypt/leave-plaintext the wrong device
	@if [ "$(LUKS)" = "true" ]; then \
		[ "$(CONF_LUKS)" = "true" ] || { echo "LUKS=true but hosts/$(NIXNAME)/configuration.nix has luksEnable = $(CONF_LUKS) - aborting"; exit 1; }; \
	else \
		[ "$(CONF_LUKS)" != "true" ] || { echo "hosts/$(NIXNAME)/configuration.nix has luksEnable = true but LUKS=true was not passed - aborting"; exit 1; }; \
	fi
	# create partition schema
	# tear down any leftovers from a previous (interrupted) run first, so this
	# can be re-run without manual cleanup on the installer
	ssh -tt $(SSH_OPTIONS) -p$(NIXPORT) root@$(NIXADDR) " \
		set -e; \
		for _i in 1 2 3 4 5 6 7 8; do \
			_left=\$$(lsblk -ln -o MOUNTPOINT $(NIXHDD) 2>/dev/null | sed '/^$$/d' | wc -l); \
			if [ \"\$$_left\" = \"0\" ]; then break; fi; \
			for _mp in \$$(lsblk -ln -o MOUNTPOINT $(NIXHDD) 2>/dev/null | sed '/^$$/d' | sort -r); do \
				umount -l \"\$$_mp\" 2>/dev/null || true; \
			done; \
			sleep 1; \
		done; \
		swapoff -a 2>/dev/null || true; \
		cryptsetup close cryptroot 2>/dev/null || true; \
		sleep 1; \
		_used=\$$(lsblk -ln -o MOUNTPOINT $(NIXHDD) 2>/dev/null | sed '/^$$/d'); \
		if [ -n \"\$$_used\" ]; then \
			echo 'ERROR: $(NIXHDD) is still in use - is this actually the live USB that booted?'; \
			mount | grep '$(NIXHDD)' || true; \
			lsblk -f $(NIXHDD); \
			exit 1; \
		fi; \
		parted -s $(NIXHDD) -- mklabel gpt; \
		parted -s $(NIXHDD) -- mkpart root ext4 512MB -8GB; \
		parted -s $(NIXHDD) -- mkpart swap linux-swap -8GB 100%; \
		parted -s $(NIXHDD) -- mkpart ESP fat32 1MB 512MB; \
		parted -s $(NIXHDD) -- set 3 esp on; \
		sleep 1; \
		wipefs -a $(NIXHDD)$(PARTITION_LABEL)1 $(NIXHDD)$(PARTITION_LABEL)2 $(NIXHDD)$(PARTITION_LABEL)3 2>/dev/null || true; \
		if [ "$(LUKS)" = "true" ]; then \
			cryptsetup luksFormat --batch-mode $(NIXHDD)$(PARTITION_LABEL)1; \
			cryptsetup open $(NIXHDD)$(PARTITION_LABEL)1 cryptroot; \
			mkfs.ext4 -L nixos /dev/mapper/cryptroot; \
		else \
			mkfs.ext4 -L nixos $(NIXHDD)$(PARTITION_LABEL)1; \
		fi; \
		mkswap -L swap $(NIXHDD)$(PARTITION_LABEL)2; \
		mkfs.fat -F 32 -n boot $(NIXHDD)$(PARTITION_LABEL)3; \
		sleep 1; \
		if [ "$(LUKS)" = "true" ]; then \
			mount /dev/mapper/cryptroot /mnt; \
		else \
			mount $(NIXHDD)$(PARTITION_LABEL)1 /mnt; \
		fi; \
		mkdir -p /mnt/boot; \
		mount -o umask=077 $(NIXHDD)$(PARTITION_LABEL)3 /mnt/boot; \
		swapon $(NIXHDD)$(PARTITION_LABEL)2; \
		sleep 1; \
		nixos-generate-config --root /mnt; \
		sleep 1; \
		if ! grep -q 'nix.package' /mnt/etc/nixos/configuration.nix; then \
			sed --in-place '/system\.stateVersion = .*/a \
				nix.package = pkgs.nixVersions.latest;\n \
				nix.extraOptions = \"experimental-features = nix-command flakes\";\n \
				services.openssh.enable = true;\n \
				services.openssh.settings.PasswordAuthentication = true;\n \
				services.openssh.settings.PermitRootLogin = \"yes\";\n \
				users.users.root.initialPassword = \"root\";\n \
			' /mnt/etc/nixos/configuration.nix; \
		fi; \
		nixos-install --no-root-passwd && reboot; \
	"
	# done — init stops here. `make copy-switch` must be run manually once the
	# host has rebooted (and the LUKS passphrase was entered at the console).

# copy keys to target machine. This command will copy the .ssh and other key-stores to the target machine
keys:
	# SSH keys
	PATH="$(RSYNC_BINDIR):$$PATH" rsync -av -e 'ssh $(SSH_OPTIONS)' \
		--exclude='environment' \
		--exclude='known_hosts' \
		--exclude='known_hosts.old' \
		$(HOME)/.ssh/ $(NIXUSER)@$(NIXADDR):~/.ssh

# copy non exluded config files to target machine
# Only hosts/$(NIXNAME) and users/$(NIXUSER) go out — every other host's and
# user's config stays local. Include rules must come before the broader
# hosts/*, users/* excludes: rsync matches top-down and stops at the first hit.
copy:
	PATH="$(RSYNC_BINDIR):$$PATH" rsync -av -e 'ssh $(SSH_OPTIONS) -p$(NIXPORT)' \
		--exclude='.git/' \
		--exclude='docs/' \
		--exclude="scripts/" \
		--exclude='iso/' \
		--exclude='local/' \
		--exclude='.ssh/' \
		--include='hosts/$(NIXNAME)/' \
		--include='hosts/$(NIXNAME)/**' \
		--exclude='hosts/*/' \
		$(USER_INCLUDES) \
		--exclude='users/*/' \
		--rsync-path="rsync" \
		$(MAKEFILE_DIR)/ $(NIXUSER)@$(NIXADDR):/nix-config

# switch config on target machine. 
# rebuilds the specified and copied config on the target machine and switches to it
# Automatically generates hardware-configuration.nix if it doesn't exist in default location
switch:
	ssh -tt $(SSH_OPTIONS) -p$(NIXPORT) $(NIXUSER)@$(NIXADDR) " \
		[ -f /etc/nixos/hardware-configuration.nix ] || sudo nixos-generate-config; \
		sudo NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nixos-rebuild switch --flake \"/nix-config#${NIXNAME}\" --impure \
	"

copy-switch: copy switch

