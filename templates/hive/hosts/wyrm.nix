# The box. Replace the hardware/boot/networking bits with what your provider
# generated (nixos-anywhere, nixos-generate-config, or a cloud-image module),
# then set the vacationvm block at the bottom.

{ lib, modulesPath, ... }:

{
  imports = [
    # For a typical cloud VM you import the provider image module here, e.g.:
    #   "${modulesPath}/virtualisation/amazon-image.nix"
    # or your generated ./hardware-configuration.nix. The stub below is enough
    # to evaluate; it is NOT enough to actually boot — replace it.
  ];

  # --- replace this stub with your real disk/boot config -------------------
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  # -------------------------------------------------------------------------

  networking.hostName = "wyrm";
  networking.useDHCP = lib.mkDefault true;

  # Admin SSH. The box's own ed25519 host key is the agenix decryption
  # identity (see secrets/secrets.nix), generated automatically on first boot.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA...REPLACE_WITH_YOUR_LAPTOP_KEY... you@laptop"
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ── The fleet ────────────────────────────────────────────────────────────
  vacationvm = {
    enable = true;
    acmeEmail = "jm@memorici.de"; # Let's Encrypt registration
    publicIp4 = "46.62.199.15"; # every app domain gets an A record here
    # publicIp6 = "2a01:4f9:...";  # uncomment to also emit AAAA records

    # agenix `<name>.age` files live here. Porkbun credentials
    # (porkbun-api-key.age + porkbun-secret-key.age) are picked up automatically.
    secretsDir = ../secrets;
  };

  system.stateVersion = "24.11";
}
