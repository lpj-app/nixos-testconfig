{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../../modules/home-manager/hyprland
  ];

  home.username = "lpj";
  home.homeDirectory = "/home/lpj";
  home.stateVersion = "26.05";

  # Unused by myHyprland — only the old hyprland.conf's `awww` exec-once line
  # read this. dots-hyprland has its own wallpaperSelector GUI instead.
  home.file.".background-image".source = ../../assets/backgrounds/wallpaper.png;

  home.pointerCursor = {
    gtk.enable = true;
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic"; # matches the cursor theme dots-hyprland's own config already references
    size = 24;
  };

  home.packages = with pkgs; [
    # snipping tool pkgs'
    grim
    slurp
    swappy # Config.regionSelector.annotation.useSatty defaults false -> swappy
    git
    gh
    obsidian
    tor-browser
    keepass
    spotify
    vscode
    nodejs
    gnumake # make e.g. for running this config's make commands
    docker
    libreoffice
    gnome-text-editor
    thunderbird
    remmina
    imagemagick # dots-hyprland's wallpaper handling shells out to `magick identify`
    zip
    unzip
    # image/video viewers, set as mimeApps defaults below
    kdePackages.gwenview
    mpv
    pinta
    python3
    networkmanagerapplet
    wireguard-tools
    openssl
  ];

  # Without these, double-clicking an image/video in dolphin (or any
  # xdg-open call) has no associated app and just does nothing.
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      lib.genAttrs [
        "image/png" "image/jpeg" "image/gif" "image/webp" "image/bmp"
        "image/tiff" "image/svg+xml" "image/x-icon" "image/avif" "image/heif"
      ] (_: [ "org.kde.gwenview.desktop" ])
      // lib.genAttrs [
        "video/mp4" "video/x-matroska" "video/webm" "video/quicktime"
        "video/mpeg" "video/x-msvideo" "video/x-flv" "video/3gpp" "video/ogg"
      ] (_: [ "mpv.desktop" ]);
  };

  myHyprland = {
    enable = true;
    # dots-hyprland hardcodes "us"; services.xserver.xkb doesn't reach
    # Hyprland (Wayland) — applied via myHyprland's general.lua merge instead.
    keyboardLayout = "de";
    # Single internal panel — override per host once more machines join in.
    monitors = ''
      hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
    '';

    # kanshi auto-applies the first profile whose `outputs` all match what's
    # currently connected — this is what makes docking/undocking (or "only
    # the second monitor") switch automatically instead of needing a manual
    # hl.monitor() edit. "criteria" below are placeholders: run
    # `hyprctl monitors all` while docked and swap in the real connector
    # names (e.g. "DP-1", "HDMI-A-1") or, more robust against the dock
    # shuffling ports on reconnect, the EDID "description" string
    # hyprctl prints for each output (e.g. "Dell Inc. DELL U2415 ABC12345").
    kanshiProfiles = [
      # Laptop alone, no dock attached.
      {
        profile.name = "mobile";
        profile.outputs = [
          { criteria = "eDP-1"; status = "enable"; }
        ];
      }
      # Docked, both external monitors — internal panel off, monitor 1 to the
      # left, monitor 2 to the right. TODO: replace EXTERNAL-1/2 with real
      # criteria from `hyprctl monitors all`, adjust position/mode/scale.
      {
        profile.name = "docked-dual";
        profile.outputs = [
          { criteria = "eDP-1"; status = "disable"; }
          { criteria = "EXTERNAL-1"; mode = "preferred"; position = "0,0"; scale = 1.0; }
          { criteria = "EXTERNAL-2"; mode = "preferred"; position = "1920,0"; scale = 1.0; }
        ];
      }
      # Docked, but only the second external monitor should be used.
      {
        profile.name = "docked-second-only";
        profile.outputs = [
          { criteria = "eDP-1"; status = "disable"; }
          { criteria = "EXTERNAL-1"; status = "disable"; }
          { criteria = "EXTERNAL-2"; mode = "preferred"; position = "0,0"; scale = 1.0; }
        ];
      }
    ];
  };

  programs.home-manager.enable = true;
}
