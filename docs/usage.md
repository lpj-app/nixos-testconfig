Rebuild with specified host config:
```bash
sudo nixos-rebuild switch --flake /<path-to-config-folder>#nixos
```

Layout:
- `hosts/<name>/configuration.nix` — system-level config per Maschine. Importiert
  `hardware-configuration.nix` und User-Module aus `../../users/<user>/nixos.nix`.
- `users/<name>/nixos.nix` — User-Account (groups, shell, password, ssh keys).
- `users/<name>/home.nix` — Home-Manager Config (Pakete, Dotfiles).
- `modules/` — wiederverwendbare Module für mehrere Hosts.

Neuen Host anlegen: `hosts/<name>/` mit `configuration.nix` und
`hardware-configuration.nix` erstellen. `flake.nix` erkennt neue Hosts
automatisch — rebuild mit `--flake .#<name>`.


  Einmalig bei Erstinstallation oder  Hardware switch:
  sudo nixos-generate-config --show-hardware-config > hosts/<name>/hardware-configuration.nix
  git add hosts/<name>/hardware-configuration.nix
  git commit -m "add hardware config for <name>"
  git push

  Bei allen späteren Rebuilds auf dem Gerät:
  git pull
  sudo nixos-rebuild switch --flake .#<name>
  Mehr nicht. Keine Generierung, kein Touch an hardware-configuration.nix.