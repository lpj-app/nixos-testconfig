{ config, lib, pkgs, inputs, ... }:

let
  # hardware-configuration.nix already declares the LUKS device (by-uuid),
  # so no boot.initrd.luks.devices block needed — this toggle is only for
  # the Makefile's `make init` safety check.
  luksEnable = true;

  sddmAstronaut = (pkgs.sddm-astronaut.override {
    themeConfig = {
      Background = "${../../assets/backgrounds/wallpaper.png}";
      #ScreenWidth = "1024";
      #ScreenHeight = "768";
      # Components/Clock.qml multiplies this by 9 for the time, 3 for the
      # header and 2 for the date (default FontSize=13 -> 117pt time text,
      # Lower base -> smaller clock.
      FontSize = "8";
      ScreenPadding = "0";
    };
  }).overrideAttrs (oldAttrs: {
    # Theme sets no cursorShape anywhere, so kwin never gets a cursor surface
    # and the greeter pointer is invisible (sddm-astronaut-theme#93). Patch in
    # a HoverHandler — works under the theme's QtQuick 2.15, unlike
    # Item.cursorShape which needs Qt >= 6.7.
    installPhase = oldAttrs.installPhase + ''
      sed -i "s|^    padding: config.ScreenPadding|&\n    HoverHandler {\n        cursorShape: Qt.ArrowCursor\n    }|" \
        $out/share/sddm/themes/sddm-astronaut-theme/Main.qml
    '';
  });
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../../users/lpj/nixos.nix
  ];

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
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.settings.auto-optimise-store = true;

  networking.hostName = "laptop";
  networking.networkmanager.enable = true;

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
  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };
  console.keyMap = "de";

  # Testing in a Hyper-V VM (GPU-P RTX 3060): GPU-P exposes compute only, no
  # DRM/KMS render node, so Hyprland can't render via nvidia. Display goes
  # through Hyper-V's own hyperv_drm (KMS-only, no render node either) — vgem
  # gives software rendering (llvmpipe/pixman) a device to bind to. Swap back
  # to hardware.nvidia + videoDrivers=["nvidia"] once this runs on bare metal.
  boot.kernelModules = [ "vgem" ];
  hardware.graphics.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    # weston (sddm's default wayland compositor) never draws a cursor sprite
    # on the greeter; kwin_wayland does (reads XCURSOR_THEME, sddm#1894/#1996).
    wayland.compositor = "kwin";
    # sddm-astronaut-theme is Qt6-only; pin the Qt6 sddm build now that
    # plasma6 (which used to pull it in) is off.
    package = pkgs.kdePackages.sddm;
    theme = "sddm-astronaut-theme";
    # Without an explicit CursorTheme here, weston can't load one and draws no
    # pointer (sddm#1996). bibata-cursors is reachable via XCURSOR_PATH below.
    settings.Theme = {
      CursorTheme = "Bibata-Modern-Classic";
      CursorSize = "24";
    };
    # Theme's QML imports these but nixpkgs doesn't declare them as runtime
    # deps — without them the greeter falls back to just the virtual keyboard.
    extraPackages = with pkgs.kdePackages; [
      sddmAstronaut
      qt5compat
      qtmultimedia
      qtsvg
      qtvirtualkeyboard
    ];
  };

  # extraPackages doesn't link into /run/current-system/sw, where SDDM looks
  # for themes — only systemPackages does. bibata-cursors needs to be here
  # too: the greeter runs as its own system user, not lpj/home-manager.
  environment.systemPackages = [ sddmAstronaut pkgs.bibata-cursors pkgs.gsettings-desktop-schemas pkgs.glib.bin pkgs.adw-gtk3 ];

  # SDDM's greeter gets a fresh env — only XCURSOR_THEME/SIZE survive from
  # sddm.conf, XCURSOR_PATH never does. weston/Qt then only look in the sddm
  # user's ~/.icons, not NixOS's /run/current-system/sw/share/icons — symlink
  # bibata into that home directory so it's found.
  systemd.tmpfiles.rules = [
    "d /var/lib/sddm/.icons - - - -"
    "d /var/lib/sddm/.icons/default - - - -"
    "L+ /var/lib/sddm/.icons/Bibata-Modern-Classic - - - - ${pkgs.bibata-cursors}/share/icons/Bibata-Modern-Classic"
    "f /var/lib/sddm/.icons/default/index.theme - - - - ${pkgs.writeText "sddm-default-cursor-index" "[Icon Theme]\nInherits=Bibata-Modern-Classic\n"}"
  ];

  # extraPackages doesn't feed SDDM's own QML import path either — that's
  # baked into the sddm wrapper from its own deps (qtwayland, qtdeclarative).
  # SDDM runs pre-login, so environment.sessionVariables can't reach it —
  # set the Qt vars directly on the service instead.
  systemd.services.display-manager.environment = {
    QML2_IMPORT_PATH = pkgs.lib.makeSearchPath "lib/qt-6/qml" (with pkgs.kdePackages; [ qt5compat qtmultimedia qtsvg qtvirtualkeyboard ]);
    QML_IMPORT_PATH = pkgs.lib.makeSearchPath "lib/qt-6/qml" (with pkgs.kdePackages; [ qt5compat qtmultimedia qtsvg qtvirtualkeyboard ]);
    # kwin/libXcursor scans ~/.icons etc by default, not
    # /run/current-system/sw/share/icons — XCURSOR_PATH below fixes that.
    XCURSOR_THEME = "Bibata-Modern-Classic";
    XCURSOR_SIZE = "24";
    XCURSOR_PATH = "$HOME/.icons:$HOME/.local/share/icons:/run/current-system/sw/share/icons";
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };
  # Needed for the "Hyprland (uwsm)" SDDM entry to actually work — it's
  # advertised regardless (withUWSM defaults true), but its systemd units
  # only get installed when this is enabled.
  programs.uwsm.enable = true;
  programs.hyprlock.enable = true;
  security.polkit.enable = true;
  # dconf-backed `gsettings set color-scheme` (switchwall) silently no-ops
  # without this system service — home-manager's dconf.enable alone isn't enough.
  programs.dconf.enable = true;
  services.gnome.gnome-keyring.enable = true;

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    # execs.lua runs `qs -c $qsConfig` as its first autostart command;
    # upstream's installer normally sets this, we don't run it, so it's set
    # here. Must be a bare name (qs -c resolves <xdg>/quickshell/<name>), not
    # a path — a full path breaks keybinds.lua's own path concatenation
    # (screenshot/OCR/wallpaper scripts silently fail).
    qsConfig = "ii";
    # home.sessionVariables doesn't reach the real session (confirmed via
    # /proc/<pid>/environ) — environment.sessionVariables does. Quickshell's
    # QML engine also needs these modules' qmldir on the import path or `qs`
    # fails with "module ... is not installed".
    QML2_IMPORT_PATH = pkgs.lib.makeSearchPath "lib/qt-6/qml" (with pkgs.kdePackages; [ qt5compat qtpositioning kirigami.unwrapped syntax-highlighting ]);
    QML_IMPORT_PATH = pkgs.lib.makeSearchPath "lib/qt-6/qml" (with pkgs.kdePackages; [ qt5compat qtpositioning kirigami.unwrapped syntax-highlighting ]);
    # env.lua sets QT_QPA_PLATFORMTHEME=kde, but that plugin lives in
    # plasma-integration, not on apps' default QT_PLUGIN_PATH — without this
    # Qt apps silently fall back to the light theme. mkAfter appends, doesn't replace.
    QT_PLUGIN_PATH = lib.mkAfter [ "${pkgs.kdePackages.plasma-integration}/lib/qt-6/plugins" ];
    # Cursor theme for the Hyprland session — home.pointerCursor's own
    # home.sessionVariables doesn't reach the uwsm-launched session, this does.
    XCURSOR_THEME = "Bibata-Modern-Classic";
    XCURSOR_SIZE = "24";
    # mkAfter extends nixpkgs' own XCURSOR_PATH list instead of clobbering it.
    XCURSOR_PATH = lib.mkAfter [ "/run/current-system/sw/share/icons" ];
    # Software rendering fallback — see hardware.graphics.enable above.
    #WLR_RENDERER = "pixman";
    #LIBGL_ALWAYS_SOFTWARE = "1";
    # VM (Hyper-V + hyperv_drm): the hardware cursor plane can fail, leaving
    # the pointer invisible everywhere. Same fix hosts/nixos documents.
    WLR_NO_HARDWARE_CURSORS = "1";
    # German layout for libxkbcommon clients (fuzzel, foot, Qt...). Hyprland
    # ignores this and uses its own input.kb_layout (set via myHyprland).
    XKB_DEFAULT_LAYOUT = "de";
    # Bare `gsettings` (no wrapGAppsHook) finds no schemas on NixOS — point it
    # straight at the package's store path. switchwall.sh and
    # kde-material-you-colors call gsettings bare and silently fall back to
    # the light theme without this.
    GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";
  };

  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.printing.enable = true;

  nixpkgs.config.allowUnfree = true;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    backupFileExtension = "hm-backup";
    users.lpj = import ../../users/lpj/home-laptop.nix;
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
    settings.KbdInteractiveAuthentication = false;
  };
  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "26.05";
}
