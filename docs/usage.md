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
