# Adapter: run annexwyrm as a vacationvm app.
#
# annexwyrm ships a package and a *home-manager* module, but not (yet) a
# vacationvm `nixosModules.default`, so we map its package onto the generic
# `vacationvm.services.<name>` schema here. This is the pattern for adopting ANY
# service that only exposes a package — ~25 declarative lines, no imperative
# state, and it shows every knob the app needs.
#
# A service that ships its own `nixosModules.default` (see the hello-vvm
# template) needs none of this — you just import its module and set enable +
# domain.

{ pkgs, inputs, ... }:

let
  pkg = inputs.annexwyrm.packages.${pkgs.stdenv.hostPlatform.system}.default;
  publicDomain = "wyrm.fere.me";
  dataDir = "/var/lib/vacationvm-annexwyrm";
  socket = "/run/vacationvm-annexwyrm/sock";
in
{
  vacationvm.services.annexwyrm = {
    enable = true;
    description = "annexwyrm — federated git-annex archive";
    package = pkg;

    # Public exposure: Caddy vhost + automatic TLS + DNS A record at this name.
    domain = publicDomain;

    # annexwyrm speaks HTTP/1.1 over a Unix socket; Caddy proxies to it.
    listen = {
      type = "unix";
      socket = socket;
    };

    # Idempotent init then serve, sharing the resolved secret environment.
    exec = [ "${pkg}/bin/annexwyrm" "serve" ];
    preStart = [ [ "${pkg}/bin/annexwyrm" "init" dataDir ] ];

    # Federation identity + data location.
    environment = {
      ANNEXWYRM_DOMAIN = publicDomain;
      ANNEXWYRM_BASE_URL = "https://${publicDomain}";
      ANNEXWYRM_USERNAME = "sweater";
      ANNEXWYRM_INSTANCE_NAME = "sweater's archive";
      ANNEXWYRM_SOCKET = socket;
      ANNEXWYRM_DATA = dataDir;
    };

    # Login password, resolved from agenix at every start (never in the store).
    # Drop the encrypted value in secrets/annexwyrm-password.age.
    environmentSecrets.ANNEXWYRM_PASSWORD = "annexwyrm-password";

    # Tools the daemon shells out to for blob storage / federation.
    packages = [ pkgs.rclone pkgs.git-annex pkgs.git-annex-remote-rclone ];

    # Static CSS lives in the package, version-locked to the binary.
    staticFiles."/static/*" = "${pkg}/share/annexwyrm/static";

    # ActivityPub uploads can be large.
    maxBodySize = "4GB";
  };
}
