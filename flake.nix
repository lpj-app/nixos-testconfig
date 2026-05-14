{
  description = "Nixos config flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
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
