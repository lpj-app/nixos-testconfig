{ config, pkgs, inputs, ... }:

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
    git
    gh
    obsidian
    tor-browser
    imagemagick # dots-hyprland's wallpaper handling shells out to `magick identify`
  ];

  myHyprland = {
    enable = true;
    # dots-hyprland hardcodes "us"; services.xserver.xkb doesn't reach
    # Hyprland (Wayland) — applied via myHyprland's general.lua merge instead.
    keyboardLayout = "de";
    # Single internal panel — override per host once more machines join in.
    monitors = ''
      hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
    '';
  };

  programs.home-manager.enable = true;
}
