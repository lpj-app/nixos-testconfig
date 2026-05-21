{ pkgs, inputs, ... }:

{
  users.users.root = {
    hashedPassword = "$y$j9T$U.OsKHKNSQc17zW6flJCl1$XbqUsDbLm.TgDOap7YYsVuSw5Sge9R.khYEzhyOtd17";
  };

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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4VkrL2AxOhWqGJ33piWD7dsT2svlAMhvHpP67wKLg7 lucapascal2402@gmail.com"
    ];
  };
}
