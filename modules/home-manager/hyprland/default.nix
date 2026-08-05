{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.myHyprland;
  dotsConfig = "${inputs.dots-hyprland}/dots/.config";

  # Only the background differs from upstream's hyprlock.conf (same
  # wallpaper as SDDM, for a consistent login/lock look) — rest copied verbatim.
  hyprlockText = ''
    source=~/.config/hypr/hyprlock/colors.conf

    background {
        path = ${../../../assets/backgrounds/wallpaper.png}
    }
    input-field {
        monitor =
        size = 250, 50
        outline_thickness = 2
        dots_size = 0.1
        dots_spacing = 0.3
        outer_color = $entry_border_color
        inner_color = $entry_background_color
        font_color = $entry_color
        fade_on_empty = true

        position = 0, 20
        halign = center
        valign = center
    }

    label {
        monitor =
        text = $LAYOUT
        color = $text_color
        font_size = 14
        font_family = $font_family
        position = -30, 30
        halign = right
        valign = bottom
    }

    label { # Caps Lock Warning
        monitor =
        text = cmd[update:250] ''${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprlock/check-capslock.sh
        color = $text_color
        font_size = 13
        font_family = $font_family
        position = 0, -25
        halign = center
        valign = center
    }


    label { # Clock
        monitor =
        text = $TIME
        color = $text_color
        font_size = 65
        font_family = $font_family_clock

        position = 0, 300
        halign = center
        valign = center
    }
    label { # Date
        monitor =
        text = cmd[update:5000] date +"%A, %B %d"
        color = $text_color
        font_size = 17
        font_family = $font_family_clock

        position = 0, 240
        halign = center
        valign = center
    }

    label { # User
        monitor =
        text =     $USER
        color = $text_color
        outline_thickness = 2
        dots_size = 0.2
        dots_spacing = 0.2
        dots_center = true
        font_size = 20
        font_family = $font_family
        position = 0, 50
        halign = center
        valign = bottom
    }

    label { # Status
        monitor =
        text = cmd[update:5000] ''${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprlock/status.sh
        color = $text_color
        font_size = 14
        font_family = $font_family

        position = 30, -30
        halign = left
        valign = top
    }
  '';

  # Sets the wallpaper (and derives matugen colors, neutral scheme) via
  # dots-hyprland's own switchwall.sh — the same script the GUI picker uses.
  # Runs on every start (idempotent) rather than tracking first-login state,
  # so a GUI-picked wallpaper resets to this one on next login.
  execsText = ''
    hl.on("hyprland.start", function ()
        hl.exec_cmd("$HOME/.config/quickshell/ii/scripts/colors/switchwall.sh --image ${../../../assets/backgrounds/wallpaper.png} --type scheme-neutral --mode dark")
    end)
  '';

  # Upstream hardcodes input.kb_layout = "us" in general.lua; hyprland.lua
  # require()s custom/general.lua right after, so this hl.config() merges on
  # top and only changes kb_layout. Needed since Hyprland (Wayland, no X
  # server) never picks up services.xserver.xkb on its own.
  generalOverrideText = ''
    hl.config({
        input = {
            kb_layout = "${cfg.keyboardLayout}",
        },
    })
  '';

  # bar.bottom/cornerStyle values read from Config.qml's schema. This file
  # doesn't exist upstream (Quickshell creates it on demand), so a direct
  # override is safe here, unlike hyprlock.conf below.
  configJson = builtins.toJSON {
    bar = {
      bottom = true;
      cornerStyle = 1;
    };
    # 0 No | 1 Yes | 2 Local. Off by default (template repo, no API keys
    # wired up). "weeb" is upstream's literal name for the Anime sidebar tab.
    policies = {
      ai = 0;
      weeb = 0;
    };
    background = {
      widgets = {
        # "cookie" (analog dial, default) vs "digital" — see Config.qml's
        # background.widgets.clock schema for further options.
        clock.style = "digital";
      };
    };
  };

  # Upstream foot.ini sets shell=fish, but fish resolves its universal-vars
  # file through the config's real (symlinked) path — the read-only Nix
  # store — and fails to start. Switch to bash instead; rest is unchanged.
  footText = ''
    shell=bash
    term=xterm-256color

    title=foot

    font=JetBrainsMono Nerd Font:size=11
    letter-spacing=0
    dpi-aware=no

    pad=25x25

    bold-text-in-bright=no

    [scrollback]
    lines=10000

    [cursor]
    style=beam
    blink=no
    beam-thickness=1.5

    [key-bindings]
    scrollback-up-page=Page_Up
    scrollback-down-page=Page_Down
    clipboard-copy=Control+c
    clipboard-paste=Control+v
    search-start=Control+f
    font-increase=Control+plus Control+equal Control+KP_Add
    font-decrease=Control+minus Control+KP_Subtract
    font-reset=Control+0 Control+KP_0

    [search-bindings]
    cancel=Escape
    find-prev=Shift+F3
    find-next=F3 Control+G
    delete-prev-word=Control+BackSpace

    [text-bindings]
    \x03=Control+Shift+c
  '';

  # Files this module overrides regardless of cfg.overrideDir. A direct
  # xdg.configFile override doesn't work for files that exist upstream
  # (monitors.lua is the exception) — they lose to the recursive scan. Folded
  # into the same overlay mechanism as overrideDir instead.
  builtinOverrides = pkgs.runCommand "dots-hyprland-builtin-overrides" { } ''
    mkdir -p $out/hypr/custom $out/foot
    cp ${pkgs.writeText "hyprlock.conf" hyprlockText} $out/hypr/hyprlock.conf
    cp ${pkgs.writeText "execs.lua" execsText} $out/hypr/custom/execs.lua
    cp ${pkgs.writeText "general.lua" generalOverrideText} $out/hypr/custom/general.lua
    cp ${pkgs.writeText "foot.ini" footText} $out/foot/foot.ini
  '';

  # Layer upstream -> builtin overrides -> optional user overrideDir, each
  # via cp -rT so later layers win. Sidesteps the xdg.configFile-vs-recursive-
  # scan collision — Home Manager sees one already-merged tree, not competing entries.
  dotsConfigMerged = pkgs.runCommand "dots-hyprland-config-merged" { } ''
    cp -r ${dotsConfig} $out
    chmod -R u+w $out
    cp -rT ${builtinOverrides} $out
    ${lib.optionalString (cfg.overrideDir != null) ''cp -rT ${cfg.overrideDir} $out''}
  '';

  # Vendored as-is from end-4/dots-hyprland. Cosmetic theming extras (Kvantum,
  # dolphinrc/konsolerc/kdeglobals) skipped — apps fall back gracefully if
  # missing. kde-material-you-colors stays: switchwall.sh's post_process needs
  # its config.conf, or it defaults to light + tonal-spot regardless of theme.
  configDirs = [
    "hypr"
    "quickshell"
    "fish"
    "fontconfig"
    "foot"
    "fuzzel"
    "kitty"
    "matugen"
    "mpv"
    "wlogout"
    "kde-material-you-colors"
  ];

  # Two fonts the shell/matugen theming reference aren't in nixpkgs.
  # ponytail: hand-fetched from Google's font repo with verified hashes,
  # cosmetic-only gap if this ever needs to be swapped for a proper package.
  mkFont = name: url: hash:
    pkgs.runCommand name { } ''
      install -Dm444 ${pkgs.fetchurl { inherit url hash; }} $out/share/fonts/truetype/${name}.ttf
    '';

  spaceGrotesk = mkFont "SpaceGrotesk"
    "https://raw.githubusercontent.com/google/fonts/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"
    "sha256-rK1t4fyTQ29cDx9BN3Ue8E8a6jBj5wNlNZcP/PvXn3I=";

  readexPro = mkFont "ReadexPro"
    "https://raw.githubusercontent.com/google/fonts/main/ofl/readexpro/ReadexPro%5BHEXP,wght%5D.ttf"
    "sha256-Jou6fh6POxTXmLP7DkDrqj/DkwjJrAAg4vr23xgcww4=";

  # Non-builtin QML modules the shell imports — found via a static grep scan
  # of the vendored tree, cross-checked against `qs`'s "module ... is not
  # installed" errors. home.packages alone isn't enough; each needs its
  # qmldir on QML(2)_IMPORT_PATH. Qt.labs.*/QtQuick*/QtCore/Quickshell.* are
  # already covered by the `quickshell` package, left off on purpose.
  qmlModulePackages = with pkgs.kdePackages; [
    qt5compat # Qt5Compat.GraphicalEffects
    qtpositioning # QtPositioning (weather widget)
    # kdePackages.kirigami itself is a thin QT_PLUGIN_PATH-wrapping
    # derivation with no lib/qt-6/qml dir of its own — .unwrapped is the
    # actual build output that has org.kde.kirigami's qmldir.
    kirigami.unwrapped # org.kde.kirigami
    syntax-highlighting # org.kde.syntaxhighlighting
  ];
in
{
  options.myHyprland = {
    enable = lib.mkEnableOption "the end-4/dots-hyprland (illogical-impulse) desktop shell";

    monitors = lib.mkOption {
      type = lib.types.lines;
      default = ''
        hl.monitor({ output = "*", mode = "preferred", position = "auto", scale = 1 })
      '';
      description = ''
        Contents of ~/.config/hypr/monitors.lua. hyprland.lua require()s this
        automatically when present — the per-host override point, one
        hl.monitor(...) call per display.
      '';
    };

    overrideDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional directory mirroring the dots-hyprland tree (e.g.
        "''${overrideDir}/hypr/custom/keybinds.lua"). Any file present here
        replaces the matching upstream file; everything else falls back to
        upstream untouched. Leave null (default) to run pure upstream.
      '';
    };

    keyboardLayout = lib.mkOption {
      type = lib.types.str;
      default = "us";
      description = ''
        Value for Hyprland's input.kb_layout, applied via a
        custom/general.lua override that merges on top of upstream's
        hardcoded "us". Defaults to "us" so plain clones stay untouched.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile = lib.genAttrs configDirs (name: {
      source = "${dotsConfigMerged}/${name}";
      recursive = true;
    }) // {
      "hypr/monitors.lua".text = cfg.monitors;

      # dots-hyprland references this path as a git submodule the github:
      # fetcher never pulls (empty dir upstream, zero files) — see
      # dots-hyprland-shapes in flake.nix.
      "quickshell/ii/modules/common/widgets/shapes" = {
        source = inputs.dots-hyprland-shapes;
        recursive = true;
      };
    };

    # switchwall.sh's pre_process sets color-scheme via gsettings and
    # kde-material-you-colors reads it back — without the dconf backend both
    # calls fail and it silently regenerates a light scheme.
    dconf.enable = true;

    home.packages = with pkgs; [
      # Shell + widgets
      quickshell
      matugen
      hyprsunset
      hypridle
      hyprlock
      # SUPER+Return tries foot/kitty/alacritty/... in order and no-ops if
      # none are installed. foot is first, so installing it (not kitty) makes
      # it the default with zero config — also sidesteps a kitty bug where
      # its theme include resolves into the read-only Nix store.
      foot
      wl-clipboard
      cliphist
      playerctl
      brightnessctl
      cava
      pavucontrol

      # Fonts used throughout the shell + matugen theming
      nerd-fonts.jetbrains-mono
      material-symbols
      rubik
      spaceGrotesk
      readexPro

      # Basic tooling the shell's scripts 
      jq
      ripgrep
      bc
      wget
      eza
      fzf
      xdg-user-dirs
      gnome-keyring

      # KDE runtime bits the shell integrates with (QT_QPA_PLATFORMTHEME=kde,
      # bluetooth/network kcmodules, polkit prompts, file manager)
      kdePackages.polkit-kde-agent-1
      kdePackages.plasma-nm
      kdePackages.bluedevil
      kdePackages.dolphin
      kdePackages.systemsettings

      # switchwall.sh's post_process runs kde-material-you-colors to
      # regenerate kdeglobals/color-schemes from the matugen palette.
      # Without this binary + gsettings/dconf below, Qt apps (dolphin...)
      # silently stay on the default light Breeze theme.
      python3Packages.kde-material-you-colors
      kdePackages.plasma-integration # the "kde" QPA platform theme that reads kdeglobals
      # kde-material-you-colors shells out to `plasma-apply-colorscheme`,
      # shipped in plasma-workspace — without it the tool exits 127 right
      # after generating .colors, and no kdeglobals ever gets written.
      kdePackages.plasma-workspace
      gsettings-desktop-schemas
      # `gsettings` itself lives in glib's `bin` output (plain `pkgs.glib`
      # installs only `out`) — without it switchwall's gsettings calls fail.
      glib.bin
      adw-gtk3 # gtk-theme 'adw-gtk3-dark' that pre_process sets for GTK apps

      fish
      starship

      # ii's Python-backed widgets (weather/AI) expect a venv the upstream
      # installer builds with uv. ponytail: not wired up here — if those
      # widgets error, `uv venv ~/.local/state/quickshell/.venv` by hand.
      uv
    ] ++ qmlModulePackages;

    # config.json is runtime-mutable — the shell rewrites it every wallpaper
    # change, steamrolling a one-time seed. xdg.configFile fares worse: once
    # written through, home-manager refuses to switch. Re-apply our keys via
    # a jq deep-merge on every activation instead.
    home.activation.applyIllogicalImpulseConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      target="$HOME/.config/illogical-impulse/config.json"
      overrides=${pkgs.writeText "illogical-impulse-overrides.json" configJson}
      mkdir -p "$(dirname "$target")"
      if [ -e "$target" ]; then
        ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" "$overrides" > "$target.tmp" && mv "$target.tmp" "$target"
      else
        install -Dm644 "$overrides" "$target"
      fi
    '';

    # home.sessionVariables doesn't reach the real session (verified via
    # /proc/<hyprland-pid>/environ) — QML2_IMPORT_PATH/QML_IMPORT_PATH are set
    # via environment.sessionVariables in the host configs instead, using this same list.
  };
}
