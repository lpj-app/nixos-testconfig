{ config, pkgs, lib, inputs, ... }:

{
  home.username = "lpj";
  home.homeDirectory = "/home/lpj";

  # Hyprland config — minimal setup so the session actually starts.
  xdg.configFile."hypr/hyprland.conf".source = ./hyprland.conf;

  # Quickshell has no Home Manager module — symlink to the live checkout so
  # QML changes are testable with just `qs`, no rebuild needed.
  xdg.configFile."quickshell".source =
    config.lib.file.mkOutOfStoreSymlink "/nix-config/users/lpj/quickshell";

  # Vendored end-4/dots-hyprland Quickshell tree. Kept at its own top-level
  # path, not nested under "quickshell/" — that's already a
  # mkOutOfStoreSymlink, and Home Manager refuses to write through an
  # existing out-of-store symlink. Not wired into exec-once yet; test
  # standalone with `qs -c ~/.config/quickshell-dots-vendor/shell.qml`.
  xdg.configFile."quickshell-dots-vendor".source =
    inputs.dots-hyprland + "/dots/.config/quickshell/ii";

  programs.wofi.enable = true;
  services.dunst.enable = true;

  # Cursor theme, consistent across Hyprland/GTK/Qt. gtk.enable writes it into
  # GTK's settings.ini; Hyprland needs the matching XCURSOR_* vars in hyprland.conf too.
  home.pointerCursor = {
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
  };

  # Delegates Qt apps (Quickshell later) to the GTK theme above instead of
  # maintaining a separate Qt theme.
  qt = {
    enable = true;
    platformTheme.name = "gtk";
  };

  # hyprpolkitagent's binary lives under libexec/, not bin/, so it can't be
  # started via exec-once — declare the unit here instead.
  systemd.user.services.hyprpolkitagent = {
    Unit = {
      Description = "Hyprland Polkit Authentication Agent";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Lock screen, shown by hyprlock's own request or by hypridle below.
  programs.hyprlock = {
    enable = true;
    settings = {
      background = [{
        path = "~/.background-image";
        blur_passes = 2;
      }];
      input-field = [{
        size = "250, 60";
        outline_thickness = 3;
        dots_center = true;
        position = "0, -150";
        halign = "center";
        valign = "center";
      }];
      label = [
        {
          text = "$TIME";
          font_size = 90;
          position = "0, 100";
          halign = "center";
          valign = "center";
        }
        {
          text = ''cmd[update:60000] date +"%A, %d.%m.%Y"'';
          font_size = 24;
          position = "0, 20";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  # Idle handling: lock after 5 min, turn the display off 30s after that,
  # and lock (not just blank) before the system suspends.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "pidof hyprlock || hyprlock";
        after_sleep_cmd = "hyprctl dispatch dpms on";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "pidof hyprlock || hyprlock";
        }
        {
          timeout = 330;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
      ];
    };
  };

  # Home Manager compatibility version — don't bump without checking release notes.
  home.stateVersion = "25.11";

  # False positive: nixos-unstable/home-manager bump version labels on
  # different schedules, but nixpkgs is pinned via flake.nix's follows.
  home.enableNixpkgsReleaseCheck = false;

  home.packages = with pkgs; [
    # Minimal Hyprland userland — terminal + launcher so the keybindings work.
    kitty
    awww
    quickshell
    hyprsunset
    libnotify
    wl-clipboard
    cliphist
    grim
    slurp
    git
    gh
    obsidian
    tor-browser
  ];

  home.file = {
    ".background-image".source = ../../assets/backgrounds/wallpaper.png;
  };

  home.sessionVariables = {
    # Qt6's wrapper only exports NIXPKGS_QT6_QML_IMPORT_PATH, which Qt's QML
    # engine never reads — without this, QtQuick's own types (Text, Item...)
    # fail to resolve even though Quickshell's own modules load fine.
    QML2_IMPORT_PATH = lib.makeSearchPath "lib/qt-6/qml" [
      pkgs.qt6.qtdeclarative
      pkgs.qt6.qtwayland
      pkgs.qt6.qt5compat
      pkgs.quickshell
    ];
  };

  programs.home-manager.enable = true;
}
