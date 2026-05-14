{ pkgs, inputs, ... }:

{
  users.users.lpj = {
    isNormalUser = true;
    home = "/home/lpj";
    extraGroups = [
      "docker"
      "wheel"
    ];
    shell = pkgs.bash;
    hashedPassword = "$y$j9T$U.OsKHKNSQc17zW6flJCl1$XbqUsDbLm.TgDOap7YYsVuSw5Sge9R.khYEzhyOtd17";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII1Yr8oOlyzPzumtC9nCm2Gdoz3U+YcRep1FDv3nSzEd testuser@nixos"
    ];
  };
}
