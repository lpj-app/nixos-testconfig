{
  description = "Nixos config flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Raw dotfiles only — upstream's flake targets non-NixOS and doesn't
    # deploy them; we vendor the tree ourselves via a home-manager module.
    dots-hyprland = {
      url = "github:end-4/dots-hyprland";
      flake = false;
    };

    # A git submodule of dots-hyprland; github: only fetches tarballs (no
    # submodules), so it's pulled separately and symlinked in by the hyprland module.
    dots-hyprland-shapes = {
      url = "github:end-4/rounded-polygon-qmljs";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      # Every subdirectory of ./hosts becomes a nixosConfiguration with the
      # same name. To add a new host, create ./hosts/<name>/ containing
      # configuration.nix, hardware-configuration.nix and home.nix, then run
      #   sudo nixos-rebuild switch --flake .#<name>
      hostsDir = ./hosts;
      hostNames = builtins.attrNames (
        nixpkgs.lib.filterAttrs (_: type: type == "directory")
          (builtins.readDir hostsDir)
      );

      mkHost = name: nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          (hostsDir + "/${name}/configuration.nix")
          inputs.home-manager.nixosModules.default
        ];
      };
    in {
      nixosConfigurations = nixpkgs.lib.genAttrs hostNames mkHost;
    };
}
