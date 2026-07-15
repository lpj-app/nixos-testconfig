{ config, pkgs, inputs, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../../users/lpj/nixos.nix
  ];

  # Bootloader legacy
  #boot.loader.grub.enable = true;
  #boot.loader.grub.device = "/dev/sda";
  #boot.loader.grub.useOSProber = true;

  # Bootloader UEFi
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Kernel params for silent boot
  boot.consoleLogLevel = 0;
  boot.kernelParams = [
    "quiet"
    "splash"
    "boot.shell_on_fail"
    "loglevel=3"
    "rd.systemd.show_status=false"
    "rd.udev.log_level=3"
    "udev.log_priority=3"
    "vt.global_cursor_default=0" # Disables blinking cursor on boot
  ];

  # Enables Plymouth very early in the initrd (ramdisk)
  boot.initrd.systemd.enable = true;
  boot.initrd.verbose = false;

  # Disables status messages on console from systemd
  systemd.settings.Manager = {
    ShowStatus = "no";
  };

  boot.plymouth = {
    enable = true;
    theme = "default-theme";
    themePackages = [ (pkgs.callPackage ../../themes/default-theme/default.nix { }) ];
  };

  # Removes all users from the system except for the ones defined in home-manager config
  users.mutableUsers = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.auto-optimise-store = true;
  # and cap boot menu entries:
  boot.loader.systemd-boot.configurationLimit = 10;  # or grub equivalent

  time.timeZone = "Europe/Berlin";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };

  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  
  # Default hyprland config
  #programs.hyprland.enable = true;

  # Nvidia hyprland config
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  environment.sessionVariables = {
    #If your cursor becomes invisible
    WLR_NO_HARDWARE_CURSORS = "1";
    #Hint electron apps to use wayland
    NIXOS_OZONE_WL = "1";
  };

  hardware = {
    # Opengl
    graphics.enable = true;

    # Most wayland compositors need this
    nvidia.modesetting.enable = true;
  };

  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];


  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };
  console.keyMap = "de";

  services.printing.enable = true;

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  programs.firefox.enable = true;

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    waybar
    eww
    dunst
    libnotify
    awww
    kitty
    wofi

    (pkgs.waybar.overrideAttrs (oldAttrs: {
      mesonFlags = oldAttrs.mesonFlags ++ [ "-Dexperimental=true" ];
      })
    )
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "hm-backup";
    users.lpj = import ../../users/lpj/home.nix;
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "25.11";
}
