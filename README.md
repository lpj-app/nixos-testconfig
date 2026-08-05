# nixos-testconfig

Flake-based NixOS config for a handful of personal machines — a laptop and a
desktop running Hyprland — bootstrapped and deployed remotely over SSH via
`make`, rather than edited by hand on each box.

## Table of Contents

1. [Repository layout](#1-repository-layout)
2. [Bootstrapping a new host](#2-bootstrapping-a-new-host)
3. [Day-to-day rebuilds](#3-day-to-day-rebuilds)
4. [Running end-4/dots-hyprland on NixOS via Home Manager](#4-running-end-4dots-hyprland-on-nixos-via-home-manager)
5. [Full-disk encryption (LUKS)](#5-full-disk-encryption-luks)
6. [Boot splash (Plymouth)](#6-boot-splash-plymouth)
7. [Known limitations](#7-known-limitations)

## 1. Repository layout

```
flake.nix                          entry point; auto-discovers every hosts/<name>/ as a nixosConfiguration
hosts/<name>/configuration.nix     system-level config for one machine
users/<name>/nixos.nix             system-level user account (password hash, SSH keys, groups)
users/<name>/home*.nix             Home Manager profile (packages, dotfiles) for that user
modules/                           reusable NixOS/Home Manager modules shared across hosts
themes/                            Plymouth boot theme packages (see §6)
Makefile                           the whole remote bootstrap/deploy workflow (see §2, §3)
```

`flake.nix`'s `mkHost` builds a `nixosConfigurations.<name>` for every
directory under `hosts/` by reading the directory listing — adding a host is
`mkdir hosts/<name>` plus a `configuration.nix`, no edit to `flake.nix`
itself needed.

Every current host config imports its hardware description from the same
fixed, absolute path instead of a repo-committed file:

```nix
imports = [
  /etc/nixos/hardware-configuration.nix
  # ...
];
```

That's also why every `nixos-rebuild`/`nix flake check` invocation in this
repo carries `--impure` — an absolute path outside the flake's own tree can't
be read under pure evaluation. The file itself is never checked into git:
disk UUIDs and partition labels are machine-specific, and a repo-committed
copy would silently go stale the moment you reinstall or swap hardware.
`make switch` (§3) runs `nixos-generate-config` on the target machine once,
the first time that file is missing, and leaves it alone on every rebuild
after that.

## 2. Bootstrapping a new host

Starting point: a machine booted from a NixOS installer ISO/`.img`, reachable
over SSH as `root`.

Set the connection variables for the target, either by editing the Makefile
defaults or overriding them on the command line:

| Variable | Default | Meaning |
|---|---|---|
| `NIXADDR` | `192.168.0.152` | target IP |
| `NIXPORT` | `22` | SSH port |
| `NIXHDD` | `/dev/nvme0n1` | disk to partition — run `lsblk` on the target first and match by size, not by guessing the name |
| `NIXNAME` | `laptop` | which `hosts/<name>/` to build |
| `LUKS` | `true` | encrypt the root partition — see [§5](#5-full-disk-encryption-luks) |
| `SSH_KEY` | unset | path to a private key, to skip password prompts |

Then:

```bash
make init NIXNAME=<host> NIXADDR=<ip> NIXHDD=/dev/<disk>
```

`init` does the whole bootstrap in one shot, following the
[NixOS manual's partitioning guide](https://nixos.org/manual/nixos/stable/#sec-installation-manual-partitioning):

1. Checks that `LUKS` matches what `hosts/<name>/configuration.nix` actually
   expects (its `luksEnable` toggle — see §5) and refuses to touch the disk
   on a mismatch, before running anything destructive.
2. Partitions the disk with `parted` — root (ext4 or LUKS), swap, and a FAT
   ESP — formats each, and mounts them at `/mnt`.
3. Runs `nixos-generate-config --root /mnt` and patches the generated
   `configuration.nix` (via `sed`) to enable flakes and password SSH login
   for the *next* step, since the freshly-installed system otherwise has no
   way back in.
4. Runs `nixos-install` and reboots.
5. Waits for the host to come back up, then chains into `copy` and `switch`
   (as `root`, since the flake-defined normal user doesn't exist until the
   first successful switch) to actually apply this repo's config.
6. Hands `/nix-config` ownership over to the real deploy user
   (`NIXUSER`, e.g. `lpj`) so future `copy`/`switch` runs don't need root.

Run `make keys` afterwards if the target also needs your `~/.ssh` contents
copied over (for pushing to a git remote from the device itself, etc.).

## 3. Day-to-day rebuilds

Two modes, depending on where the command runs:

**Locally, on the machine being changed:**
```bash
make conf/switch   # sudo nixos-rebuild switch --flake .#<NIXNAME>
make conf/test      # same, but doesn't persist across reboot
make conf/check      # nix flake check --impure, validates every host at once
```

**Remotely, over SSH, for headless machines:**
```bash
make copy-switch NIXNAME=<host> NIXADDR=<ip>
```
which is `copy` (rsync the whole repo to `/nix-config` on the target,
excluding `.git/`, `docs/`, `iso/`, `local/`) followed by `switch`
(`nixos-rebuild switch --flake "/nix-config#<host>" --impure`, generating
`/etc/nixos/hardware-configuration.nix` first if it isn't there yet — see
§1). `switch` uses `ssh -tt` specifically so `sudo`'s password prompt has a
real terminal to write to.

## 4. Running end-4/dots-hyprland on NixOS via Home Manager

Technical reference for how this repo wires up the
[end-4/dots-hyprland](https://github.com/end-4/dots-hyprland) (Quickshell)
desktop shell declaratively on NixOS. This section is the "how it works"
reference, not a troubleshooting log.

### Table of Contents

1. [The core idea: vendor, don't reimplement](#41-the-core-idea-vendor-dont-reimplement)
2. [The `myHyprland` module](#42-the-myhyprland-module)
3. [Wiring it into a host](#43-wiring-it-into-a-host)
4. [What vendoring alone doesn't give you](#44-what-vendoring-alone-doesnt-give-you)
   - [4.1 `$qsConfig`](#441-qsconfig)
   - [4.2 Qt6 QML addon modules](#442-qt6-qml-addon-modules)
   - [4.3 Git submodules](#443-git-submodules)
   - [4.4 Environment variable propagation](#444-environment-variable-propagation)
   - [4.5 Customizing anything: `myHyprland.overrideDir`](#445-customizing-anything-myhyprlandoverridedir)
5. [Session manager: UWSM](#45-session-manager-uwsm)
6. [Customizing appearance and behavior: `config.json`](#46-customizing-appearance-and-behavior-configjson)
   - [6.1 Why it's not a plain `xdg.configFile`](#461-why-its-not-a-plain-xdgconfigfile)
   - [6.2 Finding the setting you want](#462-finding-the-setting-you-want)
   - [6.3 Reference: settings this repo already sets](#463-reference-settings-this-repo-already-sets)
   - [6.4 Clock: hiding, centering, style](#464-clock-hiding-centering-style)
   - [6.5 Desktop icons: not supported](#465-desktop-icons-not-supported)
7. [Setting the wallpaper](#47-setting-the-wallpaper)
8. [Choosing a terminal](#48-choosing-a-terminal)
9. [Known limitations](#49-known-limitations)
10. [Adding a new host](#410-adding-a-new-host)
11. [Debugging checklist / maintenance workflow](#411-debugging-checklist--maintenance-workflow)

### 4.1 The core idea: vendor, don't reimplement

end-4/dots-hyprland ships as an imperative installer script that writes
config files, builds a Python venv, and pulls in Arch-specific packages.
That doesn't map to NixOS. Instead of reimplementing their Quickshell shell
piece by piece, this repo takes their config tree as-is via a flake input
and symlinks it into `~/.config`, unmodified:

```nix
# flake.nix
inputs.dots-hyprland = {
  url = "github:end-4/dots-hyprland";
  flake = false; # it's a plain git checkout, not a flake itself
};
```

Home Manager's `xdg.configFile` with `recursive = true` then mirrors each
top-level directory from their `dots/.config/` into the real `~/.config/`,
as individual per-file symlinks into the Nix store. Everything upstream
ships — the Quickshell bar, session screen, notifications, lock screen — is
used as-is. No custom QML.

### 4.2 The `myHyprland` module

`modules/home-manager/hyprland/default.nix` is the whole integration. It
exposes one option:

```nix
myHyprland.enable = true;
myHyprland.monitors = ''
  hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
'';
```

`monitors` is the one file the module *does* override
(`hypr/monitors.lua`) — dots-hyprland's own `hyprland.lua` `require()`s it
automatically if present, so it's the natural per-host override point for
monitor layout.

Everything else the module does:
- Symlinks `hypr/`, `quickshell/`, `fish/`, `fontconfig/`, `foot/`,
  `fuzzel/`, `kitty/`, `matugen/`, `mpv/`, `wlogout/` from the flake input,
  recursively.
- Installs the packages the shell shells out to (`quickshell`, `matugen`,
  `hypridle`, `hyprlock`, `cliphist`, KDE integration bits, fonts, ...).
- Sets up the Qt6 QML addon modules the vendored QML actually imports (see
  [4.4.2](#442-qt6-qml-addon-modules)).
- Symlinks in one git submodule the flake fetcher can't reach on its own
  (see [4.4.3](#443-git-submodules)).

### 4.3 Wiring it into a host

A host that wants this shell imports the user's `home-laptop.nix` (which
sets `myHyprland.enable = true`) instead of the older, non-vendored
`home.nix`:

```nix
# hosts/<name>/configuration.nix
home-manager.users.lpj = import ../../users/lpj/home-laptop.nix;

programs.hyprland.enable = true;
programs.hyprland.xwayland.enable = true;
programs.uwsm.enable = true;              # see 4.5
services.displayManager.sddm.enable = true;
services.displayManager.sddm.wayland.enable = true;
```

`hosts/laptop` and `hosts/laptop-vm` both do this. `hosts/nixos` still uses
the older `home.nix` + a hand-written `hyprland.conf` — the two approaches
are not mixed within one host.

### 4.4 What vendoring alone doesn't give you

Symlinking the config tree gets you 90% of the way. The remaining 10% is
stuff upstream's installer script normally handles, that a pure file-vendor
approach has to replace explicitly.

#### 4.4.1 `$qsConfig`

dots-hyprland's `hypr/hyprland/execs.lua` launches the shell with
`qs -c $qsConfig` as its very first autostart command. Upstream's installer
sets this env var; we don't run their installer, so it's unset by default —
and an unset `$qsConfig` means `qs -c` gets no path and silently never
starts anything. Set it explicitly, host-side (not in the Home Manager
module — see [4.4.4](#444-environment-variable-propagation) for why):

```nix
environment.sessionVariables.qsConfig = "ii";
```

**Must be the bare config name, not a path.** `qs --help` is explicit about
this: `-c`/`--config` takes a name resolved under
`<xdg-dir>/quickshell/<name>/shell.qml`; `-p`/`--path` is the one that takes
a path. A full path (`$HOME/.config/quickshell/ii`) happens to still work
for the direct `qs -c $qsConfig` launch, which is exactly why this is easy
to get wrong and not notice — but `hyprland/keybinds.lua` builds other paths
by string-concatenating `$HOME/.config/quickshell/$qsConfig/scripts`, and
with a full path in there that becomes a doubled, nonexistent path. Every
script launched that way (screenshot OCR, emoji picker, wallpaper switching,
video recording) silently no-ops. Shipped this exact regression once —
caught it by manually expanding the string on the live host, not by
guessing:

```bash
su lpj -c "qsConfig=/home/lpj/.config/quickshell/ii; echo \$HOME/.config/quickshell/\$qsConfig/scripts"
# -> /home/lpj/.config/quickshell//home/lpj/.config/quickshell/ii/scripts  (broken)
```

#### 4.4.2 Qt6 QML addon modules

The vendored QML imports a few Qt6 modules that the `quickshell` package
doesn't pull in on its own. Being in `home.packages` isn't enough — the QML
engine needs each module's `qmldir` on `QML_IMPORT_PATH`/`QML2_IMPORT_PATH`,
or you get `module "X" is not installed` and the shell dies before drawing
anything.

Find the full set with one grep instead of chasing errors one at a time:

```bash
grep -RhoE '^import [A-Za-z][A-Za-z0-9_.]*' ~/.config/quickshell/ii/ | sort -u
```

`Qt.labs.*`, `QtQuick*`, `QtQml*`, `QtCore`, `Quickshell.*` are core modules
`quickshell` already provides. The actual addons, as of this writing:

| Import | Package |
|---|---|
| `Qt5Compat.GraphicalEffects` | `kdePackages.qt5compat` |
| `QtPositioning` | `kdePackages.qtpositioning` |
| `org.kde.kirigami` | `kdePackages.kirigami.unwrapped` — **not** plain `kirigami`, that's a wrapper derivation with no `lib/qt-6/qml` of its own |
| `org.kde.syntaxhighlighting` | `kdePackages.syntax-highlighting` |

```nix
qmlModulePackages = with pkgs.kdePackages; [
  qt5compat qtpositioning kirigami.unwrapped syntax-highlighting
];
# home.packages ++ qmlModulePackages
# QML_IMPORT_PATH / QML2_IMPORT_PATH = pkgs.lib.makeSearchPath "lib/qt-6/qml" qmlModulePackages
```

#### 4.4.3 Git submodules

`dots/.config/quickshell/ii/modules/common/widgets/shapes` is a git
submodule in the upstream repo. The `github:` flake fetcher only pulls the
tarball of the main repo — submodule directories come through completely
empty. Fetch the submodule as its own flake input and symlink it into the
right nested path:

```nix
# flake.nix
dots-hyprland-shapes = {
  url = "github:end-4/rounded-polygon-qmljs";
  flake = false;
};

# modules/home-manager/hyprland/default.nix
xdg.configFile."quickshell/ii/modules/common/widgets/shapes" = {
  source = inputs.dots-hyprland-shapes;
  recursive = true;
};
```

If upstream adds more submodules later, check `.gitmodules` in the
`dots-hyprland` flake input's store path and repeat this pattern.

#### 4.4.4 Environment variable propagation

Two mechanisms can set environment variables in this stack, and only one of
them reliably reaches a real SDDM → UWSM → Hyprland session:

- `home.sessionVariables` (Home Manager) → written to `~/.hm-session-vars.sh`,
  meant to be sourced by a login shell's `~/.profile`. That file doesn't
  exist for this user (`programs.bash.enable` isn't set), and UWSM doesn't
  launch Hyprland through a login shell anyway. **Doesn't work here.**
- `environment.sessionVariables` (NixOS, host-level) → propagates through
  `/etc/set-environment` + PAM, which the real session does go through.
  **Use this one.**

Verify by checking the actual running process, not a shell test — `su`/
`su -` don't replicate a real `pam_systemd` login session and can give false
negatives:

```bash
tr '\0' '\n' < /proc/<hyprland-pid>/environ | grep VARNAME
```

Similarly, a `xdg.configFile` override loses to home-manager's own
recursive scan whenever upstream already ships a file at that exact path
(even an empty one) — `hypr/custom/env.lua` exists upstream, so overriding
it directly doesn't take effect; `hypr/monitors.lua` isn't shipped upstream
at all, so overriding it works fine. It's about pre-existing-file collision,
not nesting depth. For file content (not env vars), see
[4.4.5](#445-customizing-anything-myhyprlandoverridedir) instead of fighting
this directly.

#### 4.4.5 Customizing anything: `myHyprland.overrideDir`

For anything beyond env vars — keybinds, window rules, general.lua, even
Quickshell bar QML — set `myHyprland.overrideDir` to a directory that
mirrors the vendored tree's structure:

```nix
myHyprland.overrideDir = ../../users/lpj/hyprland-overrides;
```

Any file present at `<overrideDir>/<same relative path>` replaces the
upstream file; anything not present falls through to upstream untouched.
Implementation: copy upstream into a fresh derivation, then `cp -rT` the
override dir on top — no per-file `xdg.configFile` entry competes with the
recursive scan, because there's only one merged source tree by the time
Home Manager sees it.

Leave it `null` (the default) for a completely unmodified upstream shell —
that's the point: a fresh clone of this repo/template needs zero
customization to build and run, and customizing later means "drop a file at
the matching path," not "understand and edit this Nix module."

### 4.5 Session manager: UWSM

`programs.hyprland.withUWSM` defaults to `true`, so SDDM always shows a
"Hyprland (uwsm managed)" session entry — whether or not UWSM is actually
usable. Without `programs.uwsm.enable = true`, that session fails
immediately (missing `wayland-session-bindpid@.service` systemd unit) and
looks like a generic black-screen crash. Either:

- pick the plain **"Hyprland"** entry at the SDDM login screen, or
- set `programs.uwsm.enable = true;` for proper systemd-session integration
  (recommended — it's what Hyprland itself now recommends as the standard
  launch path).

### 4.6 Customizing appearance and behavior: `config.json`

Most of what you'd want to tweak — bar position, whether the AI sidebar or
"weeb" (their word, `SidebarLeftContent.qml`) anime tab show up, the
on-screen clock, wallpaper theming mode — isn't in QML or Lua at all. It's
in `~/.config/illogical-impulse/config.json`, read (and partly re-written)
by `modules/common/Config.qml`.

#### 4.6.1 Why it's not a plain `xdg.configFile`

`config.json` is runtime-mutable: the shell writes to it itself (wallpaper
switching updates `background.wallpaperPath`; `Config.qml`'s own load path
fills in every schema key missing from the file with its QML-declared
default and writes the whole merged document back out). A plain
`xdg.configFile` symlink fights this on two fronts:

- The moment anything writes through it, the next `home-manager switch`
  finds a real file where it expected to manage a symlink, refuses to
  proceed, and tries to back it up to `.hm-backup` — which then blocks the
  *next* switch too, since that backup path is already taken. Hit this for
  real, not hypothetically.
- Even if you work around that, a one-time seed of just the keys you care
  about gets steamrolled the first time `Config.qml` does its
  fill-defaults-and-write-back pass — watched a seeded
  `"policies": {"ai": 0, "weeb": 0}` come back as `{"ai": 1, "weeb": 1}`
  after nothing more than the shell starting once.

The fix (`modules/home-manager/hyprland/default.nix`,
`home.activation.applyIllogicalImpulseConfig`): re-apply your override keys
on **every** activation via a `jq` deep-merge, not a one-time file write.

```nix
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
```

`jq`'s `*` operator deep-merges two objects with the right-hand side
winning per-key — your `configJson` values always win, everything else the
shell owns (or hasn't normalized yet) is left alone. Survives both the
home-manager-symlink problem and the shell's own rewrite-on-load behavior,
because it just runs again next time regardless of what's currently there.

#### 4.6.2 Finding the setting you want

Don't guess key names or nesting — `modules/common/Config.qml` **is** the
schema, as a tree of `property JsonObject`/`property <type>` declarations
that mirrors the JSON structure exactly:

```bash
grep -n 'property JsonObject\|Singleton {' ~/.config/quickshell/ii/modules/common/Config.qml
```

gives you the object nesting; `sed -n '<start>,<end>p'` on a specific
range gets you that object's actual leaf properties (types + defaults +
inline comments — the allowed enum values for e.g. `cornerStyle` or
`policies.weeb` are documented right there as `//` comments). Cross-check
against a script that reads the same file if you want to see a setting's
real-world effect, e.g. `switchwall.sh` reading
`.appearance.wallpaperTheming.enableQtApps` or
`.background.wallpaperPath`.

#### 4.6.3 Reference: settings this repo already sets

| Key | Value | Why |
|---|---|---|
| `bar.bottom` | `true` | bar at the bottom instead of top |
| `bar.cornerStyle` | `1` | `0` Hug, `1` **Float**, `2` Plain rectangle |
| `policies.ai` | `0` | `0` No, `1` Yes, `2` Local — sidebar LLM chat off by default (template repo, not everyone has API keys to wire up) |
| `policies.weeb` | `0` | `0` No, `1` Open, `2` Closet — gates the "Anime" sidebar tab, literally named this upstream |

`background.widgets.clock.enable` (default `true`) is **not** overridden —
turn it off, or restyle it (`style: "cookie"` vs `"digital"`, hand styles,
date format, ...) via the same `configJson` attrset and the nested
`background.widgets.clock`/`.cookie`/`.digital` objects in `Config.qml`.

#### 4.6.4 Clock: hiding, centering, style

The schema (`Config.qml`, `background.widgets.clock`):

| Key | Default | Meaning |
|---|---|---|
| `enable` | `true` | set `false` to hide the clock entirely |
| `style` / `styleLocked` | `"cookie"` | `"cookie"` (analog dial) vs `"digital"`; this repo already overrides `style` to `"digital"` in `modules/home-manager/hyprland/default.nix` |
| `placementStrategy` | `"leastBusy"` | `"free"` (draggable), `"leastBusy"`, `"mostBusy"` — the latter two auto-place the widget based on a busyness scan of the wallpaper, **not** the screen center |
| `x`, `y` | `100`, `100` | runtime pixel position, only used/updated when `placementStrategy` is `"free"` |
| `digital.*` | — | font family/weight/width/roundness, `vertical`, `showDate`, `adaptiveAlignment` (auto left/center/right text alignment based on screen position) |

**To hide it**: set `background.widgets.clock.enable = false;` in the
module's `configJson` attrset (same place `clock.style` is already set).

**To center it**: there is no `"center"` placement option — only
`free`/`leastBusy`/`mostBusy`. Centering means:

1. Set `placementStrategy = "free"` (via `configJson`, or live via
   `SUPER + I` → **Background** → **Widget: Clock** → placement selector →
   **Draggable**).
2. Drag the clock widget on the desktop to the middle with the mouse and
   release. `AbstractBackgroundWidget.qml`'s `onReleased` handler writes the
   dropped position straight back to `background.widgets.clock.x`/`.y` in
   `~/.config/illogical-impulse/config.json`.

**Don't hardcode `x`/`y` in `configJson` to fake a centered position.** The
widget's actual on-screen width (hence the pixel offset needed to center it)
depends on runtime font settings and isn't computable from Nix; and because
`home.activation.applyIllogicalImpulseConfig` re-applies every key in
`configJson` on **every** `home-manager switch` (right-hand-side-wins `jq`
merge — see [4.6.1](#461-why-its-not-a-plain-xdgconfigfile)), baking in
`x`/`y` would silently undo any manual re-drag on the next switch. Setting
`placementStrategy` (or `enable`) declaratively is fine since those aren't
meant to be user-dragged state; leave `x`/`y` as pure runtime state, set once
through the GUI.

#### 4.6.5 Desktop icons: not supported

There's no equivalent of Windows/GNOME-Files desktop icons in this stack, and
nothing to configure to get them. Wayland compositors (Hyprland included)
have no X11 root-window concept for a compositor-drawn desktop surface with
clickable file icons, and dots-hyprland/Quickshell ships no desktop-icons
widget (`modules/ii/background/widgets/` only has `clock` and `weather`;
confirmed via the upstream source tree, not just an educated guess). Getting
this would mean writing a new Quickshell widget from scratch — out of scope
for a config tweak, not a flag anywhere in `Config.qml`.

### 4.7 Setting the wallpaper

Not a static file copy — dots-hyprland derives matugen color theming
(desktop, terminal, Qt apps) from whatever image is set, so setting the
wallpaper means running the same script the wallpaper-picker GUI uses,
`~/.config/quickshell/ii/scripts/colors/switchwall.sh`:

```nix
# modules/home-manager/hyprland/default.nix, execsText, require()d via
# hypr/custom/execs.lua (an upstream-provided, otherwise-empty hook point)
hl.on("hyprland.start", function ()
    hl.exec_cmd("$HOME/.config/quickshell/ii/scripts/colors/switchwall.sh --image ${wallpaperPath} --type scheme-neutral")
end)
```

`--type scheme-neutral` picks matugen's neutral/desaturated color scheme
(other options: `scheme-monochrome`, `scheme-tonal-spot`, `scheme-vibrant`,
...; omit `--type` and it auto-detects from the image via a Python venv
script most of these vendored setups don't have wired up — pass it
explicitly instead of depending on that). Runs on every Hyprland start, not
gated behind "did this already run" state — it's idempotent (same image in,
same result out), which is simpler than maintaining a first-run marker file.
Trade-off: if you pick a different wallpaper through the GUI mid-session,
it resets to this one on your next login.

### 4.8 Choosing a terminal

`hyprland/variables.lua`'s `terminal` tries, in order:
`foot`, `kitty -1`, `alacritty`, `wezterm`, `konsole`, `kgx`, `uxterm`,
`xterm`, first one found on `PATH` wins
(`launch_first_available.sh`). The vendored `configDirs` list includes
config directories for several of these regardless of which is actually
installed (just config, not the binary) — installing the package is what
actually makes it available, e.g. `home.packages = [ pkgs.foot ];`.

`kitty` had a live bug worth knowing about if you use it: its vendored
`kitty.conf` does `include
~/.local/state/quickshell/user/generated/terminal/kitty-theme.conf`, a file
matugen generates. Depending on symlink resolution timing/state this can
end up pointing kitty at a path under the (read-only) Nix store for its own
tmp/socket handling — "cannot create tmp file in nix store" on launch.
`foot` (first in the fallback list anyway, and what this repo installs) has
no equivalent issue.

### 4.9 Known limitations

| Environment | Works? |
|---|---|
| Bare metal (Intel iGPU, Nvidia dGPU) | Yes |
| Bare metal (AMD CPU, Nvidia dGPU) | Yes — see `hosts/pc` for a worked example (4.10) |
| QEMU + `virtio-gpu-gl` | Yes (real GPU-backed render node via virgl/venus) |
| Hyper-V (any generation, incl. GPU-P passthrough) | **No** — synthetic display adapter has no render node, and Hyprland's Aquamarine backend requires one device that's both KMS- and render-capable. See `docs/hyperv-graphics-limitations.md`. |

This whole module (`myHyprland`) and the vendored Quickshell shell have no
GPU-vendor or CPU-vendor coupling anywhere — they only care that
`hardware.graphics.enable` gives them a working render node. CPU
microcode and GPU driver selection are ordinary host-level NixOS options,
unrelated to anything in sections 4.1–4.8.

### 4.10 Adding a new host

1. Create `hosts/<name>/configuration.nix`, import
   `/etc/nixos/hardware-configuration.nix` (native, machine-generated — never
   a repo-static hardware file, each machine has its own disk UUIDs; see §1).
2. `home-manager.users.lpj = import ../../users/lpj/home-laptop.nix;`
3. `programs.hyprland.enable`, `programs.uwsm.enable`, SDDM as in 4.3.
4. Override `myHyprland.monitors` via `home-manager.users.lpj.myHyprland.monitors`
   if the display layout differs from the default wildcard. **Wrap the
   override in `lib.mkForce`** (needs `lib` added to the host file's
   `{ config, pkgs, lib, inputs, ... }:` header) — `myHyprland.monitors` is
   `lib.types.lines`, which *concatenates* multiple definitions with a
   newline instead of erroring on conflict, so without `mkForce` you'd get
   both `home-laptop.nix`'s `eDP-1` line and your override's line, not a
   replacement.
5. Pin/update `flake.lock` before first build — dots-hyprland (`main`
   branch) needs Hyprland >= 0.55 for its native Lua config; older pins
   silently ignore the whole vendored config instead of erroring.
6. Don't forget `../../users/lpj/nixos.nix` in `imports` — it's the
   system-level user account (hashed password, SSH keys, `wheel`/`docker`
   groups), separate from the home-manager profile. Every existing host
   imports it (`hosts/laptop/configuration.nix`); skipping it combined with
   `users.mutableUsers = false;` means no login for `lpj` (or `root`) at all.
7. GPU/CPU-vendor bits (not covered elsewhere, since the Hyprland/Quickshell
   layer doesn't care): AMD CPU needs
   `hardware.cpu.amd.updateMicrocode = true;` +
   `hardware.enableRedistributableFirmware = true;`. Nvidia GPU needs
   `services.xserver.videoDrivers = [ "nvidia" ];`,
   `hardware.graphics.enable32Bit = true;` (only if you need 32-bit/Steam
   support), and a `hardware.nvidia` block with `modesetting.enable = true;`,
   `package = config.boot.kernelPackages.nvidiaPackages.stable;`, and
   `open = true;` (NVIDIA's recommended default for Turing-generation cards
   and later — RTX 20-series onward). None of this existed anywhere in the
   repo before `hosts/pc`; `hosts/nixos`'s `hardware.nvidia.modesetting.enable`
   alone is not a complete/working reference.

### 4.11 Debugging checklist / maintenance workflow

If the shell doesn't render (black screen, cursor only, no bar/wallpaper),
in order:

1. Confirm the right host actually built: `hostname`,
   `readlink -f /run/current-system`.
2. Confirm the right SDDM session was picked (plain "Hyprland", not "uwsm
   managed", unless `programs.uwsm.enable` is set).
3. Check `hyprctl monitors` / `hyprctl clients` — is there a real GPU
   renderer, or GL/DRM errors in `~/.cache`/`/run/user/<uid>/hypr/*/hyprland.log`?
4. If Hyprland itself is fine but nothing from the shell shows: run
   `qs -c ii` by hand with the real session's env vars and read its actual
   stderr — don't guess.

More generally, for "how do I change X" questions on this shell, the
reliable order of operations that actually found answers in this repo
(rather than trial-and-error edits) was:

1. **Grep for the setting**, don't assume a name: `grep -rn <keyword>
   ~/.config/quickshell/ii/modules/common/Config.qml` for anything
   appearance/behavior-related, or `grep -rn <keyword>
   ~/.config/hypr/hyprland/*.lua` for window-management/keybind-related.
2. **Read the source that consumes it**, not just the declaration — a
   script like `switchwall.sh` reading `.background.wallpaperPath` tells you
   the real key path and real accepted values, more reliably than a QML
   default which may be stale or overridden elsewhere.
3. **Test by hand before writing Nix**: run `qs -c ii` directly with the
   real session's env vars, or edit the live file over SSH/a root shell and
   watch what happens, *then* encode the working answer as Nix. Writing Nix
   first and rebuilding to find out if a value/path is even right wastes a
   full rebuild cycle per guess.
4. **Verify on the live process, not a `su` shell** — `su`/`su -` don't
   replicate a real `pam_systemd` session and will give false negatives for
   anything environment- or DBus-session-related (4.4.4).

## 5. Full-disk encryption (LUKS)

Not enabled on any host by default. The pattern below is worked out and
wired into `hosts/laptop/configuration.nix` (currently `luksEnable = false`,
so it changes nothing until you flip it) — copy it into any other host that
needs the same thing.

### 5.1 The toggle

A `let`-bound flag at the top of the host file, kept local to that file
rather than a shared NixOS option, since it's only ever read within it:

```nix
{ config, lib, pkgs, inputs, ... }:   # note: lib must be added here

let
  luksEnable = false;
  luksRootPartuuid = "REPLACE-WITH-BLKID-OUTPUT";
in
{
  # ...
  boot.initrd.luks.devices = lib.mkIf luksEnable {
    cryptroot.device = "/dev/disk/by-partuuid/${luksRootPartuuid}";
  };
}
```

`lib.mkIf` wrapping the whole `boot.initrd.*` value (not each leaf
individually) is what lets one `luksEnable` flag gate an arbitrarily nested
attrset in one shot — this is the same pattern nixpkgs itself uses for
`config = lib.mkIf cfg.enable { ... };` throughout the module tree.

### 5.2 The Makefile side

`make init` provisions the disk, so it needs to know about `LUKS` too — and
needs to agree with whatever the target host's config says, or you end up
with an encrypted disk a plaintext-only config can't mount (or vice versa).
`Makefile`'s `init` target:

1. Refuses to run at all if `LUKS=<value>` doesn't match `luksEnable` in
   `hosts/$(NIXNAME)/configuration.nix` (a `grep` check, before any `parted`
   call):
   ```make
   @if [ "$(LUKS)" = "true" ]; then \
       grep -q 'luksEnable = true' hosts/$(NIXNAME)/configuration.nix || { echo "..."; exit 1; }; \
   else \
       grep -q 'luksEnable = true' hosts/$(NIXNAME)/configuration.nix && { echo "..."; exit 1; } || true; \
   fi
   ```
2. When `LUKS=true`, formats the root partition through `cryptsetup`
   instead of `mkfs.ext4` directly:
   ```make
   if [ "$(LUKS)" = "true" ]; then \
       cryptsetup luksFormat $(NIXHDD)$(PARTITION_LABEL)1; \
       cryptsetup open $(NIXHDD)$(PARTITION_LABEL)1 cryptroot; \
       mkfs.ext4 -L nixos /dev/mapper/cryptroot; \
   else \
       mkfs.ext4 -L nixos $(NIXHDD)$(PARTITION_LABEL)1; \
   fi
   ```
   Swap and the FAT ESP are never encrypted — firmware/bootloaders can't
   read an encrypted `/boot` to begin with, so LUKS only ever applies to
   root.

The passphrase itself is typed interactively — `init`'s SSH call uses
`-tt` (a real pseudo-terminal) specifically so `cryptsetup luksFormat`/
`cryptsetup open` can prompt for it directly, the same way `switch` already
does for `sudo`. No `--key-file`, no passphrase-bearing environment
variable — either would leave it sitting in shell history or a process
list.

### 5.3 To actually encrypt a host

```bash
make init LUKS=true NIXNAME=<host>
# after it's up: blkid the root partition, copy its PARTUUID
```
then set `luksEnable = true;` and `luksRootPartuuid = "<that PARTUUID>";`
in `hosts/<host>/configuration.nix`, and `make switch`.

### 5.4 Headless variant: unlocking without a keyboard

The pattern above assumes the machine has its own screen/keyboard to type
the passphrase at, same as the graphical NixOS installer's LUKS step. A
kiosk device with no display attached at all — autologin straight into a
browser, managed only over SSH — can't do that. The fit there is
`boot.initrd.network.ssh`: the initrd brings up networking and a tiny SSH
server before unlocking anything, so the passphrase is typed remotely
instead:

```nix
boot.initrd = lib.mkIf luksEnable {
  systemd.enable = true;      # required for initrd-stage SSH
  network.enable = true;      # DHCP in the initrd
  network.ssh = {
    enable = true;
    port = 2222;
    authorizedKeys = config.users.users.<admin>.openssh.authorizedKeys.keys;
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
  };
  secrets."/etc/ssh/ssh_host_ed25519_key" = "/etc/secrets/initrd/ssh_host_ed25519_key";
  luks.devices.cryptroot.device = "/dev/disk/by-partuuid/${luksRootPartuuid}";
};
```

The initrd host key has to be generated once and kept outside the Nix
store (otherwise it changes — and your `known_hosts` breaks — on every
rebuild). At boot: `ssh -p 2222 root@<host>`, type the passphrase at the
prompt that appears, and the boot continues normally.

Trade-off worth knowing before choosing this: a plain power-cycle doesn't
self-heal. Someone has to SSH in and unlock it after every reboot, or the
device just sits at the initrd prompt. Not currently applied to any host in
this repo — it's here as the documented alternative for when §5.1's
console-passphrase version isn't an option.

## 6. Boot splash (Plymouth)

The wall of `Starting X...`/`Started Y...` lines during boot is just
systemd's normal console output when no graphical splash is active.
**Plymouth** is the standard NixOS mechanism for replacing that with a
logo/spinner/progress bar — a daemon that takes over the console between
the kernel handing off and the display manager starting.

### 6.1 What it takes

```nix
boot.kernelParams = [ "quiet" "splash" ];  # without these the text lines stay visible, or flash briefly before Plymouth takes over
boot.initrd.systemd.enable = true;         # Plymouth needs systemd stage-1 to run this early
boot.initrd.verbose = false;
systemd.settings.Manager.ShowStatus = "no"; # silences systemd's own status lines on the real console too

boot.plymouth = {
  enable = true;
  theme = "default-theme";
  themePackages = [ (pkgs.callPackage ../../themes/default-theme/default.nix { }) ];
};
```

`hosts/laptop` already declares this block, with
extra kernel params (`loglevel=3`, `rd.systemd.show_status=false`,
`rd.udev.log_level=3`, `udev.log_priority=3`,
`vt.global_cursor_default=0`) to keep the console fully quiet from the very
first initrd line through to the compositor starting.

### 6.2 Building your own theme

Plymouth themes are a `.plymouth` metadata file, one or more PNGs, and
(for anything beyond a static image) a `.script` file in Plymouth's own
scripting language for animation/positioning. Two ways to get one:

1. **Reskin an existing simple theme** — most lightweight themes (spinner-
   style ones especially) are just that metadata file + PNGs. Copy the
   theme, swap the logo PNG, package the result as its own
   `themePackages` derivation.
2. **Write one from scratch** — only worth it if you need custom animation
   or layout, not just a different logo. Meaningfully more work (Plymouth's
   own scripting language); not the starting point.

### 6.3 Known gap

`hosts/laptop` references
`../../themes/default-theme/default.nix` via `callPackage`, but the
`themes/` directory isn't currently present in this working tree — it
exists in history (commit `23ed92e`, "added plymout theme script", on the
`hyprland-configuration` branch) but hasn't made it back onto whatever
branch you're building from. Building that host as it stands will fail at
that `callPackage` line until `themes/` (and
`assets/themes/lpj.app.png`, which that theme references) is restored —
either `git checkout 23ed92e -- themes/ assets/themes/lpj.app.png`, or point
`theme`/`themePackages` at one of nixpkgs' own bundled themes (`bgrt`,
`spinner`, `text` — no `themePackages` entry needed for those) as a stopgap.

### 6.4 Things to watch for

- **initrd vs. full-system boot**: `boot.plymouth.enable` covers the initrd
  phase too as long as `boot.initrd.systemd.enable` is on (true for every
  host in this repo) — without it, Plymouth only starts after the initrd→
  system handoff, and you'll still see some of the early text lines.
- **`quiet` hides real boot failures too**: if a boot ever hangs, you won't
  see where without the text lines. Get the splash itself working and
  stable before layering more silence on top, not the other way around.
- **Software-rendered/virtualized display paths** (VirtualBox, Hyper-V —
  see [4.9](#49-known-limitations)) may not give Plymouth a working
  KMS/DRM output any more than they give Hyprland one; the two share the
  same underlying requirement.

## 7. Known limitations

- **Hyper-V has no Hyprland-capable render node** — see
  [4.9](#49-known-limitations) and `docs/hyperv-graphics-limitations.md`.
- **`make copy` ships the whole repo to every target**, not just the host
  being deployed — including every other host's config and (more
  pressingly) anything under the repo root regardless of which machine it's
  for. Tracked in `tasks/open-tasks.md`.
- Further scenario-specific notes (Hyper-V VM setup, QEMU VM setup, a
  from-scratch server config walkthrough, the Hyprland implementation's
  original debugging log) live under `docs/` rather than in this file.
