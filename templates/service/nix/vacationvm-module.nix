# The vacationvm integration for hello-vvm.
#
# A service ships THIS so that adding it to a fleet is two lines in the hive:
#
#     imports = [ hello-vvm.nixosModules.default ];
#     vacationvm.services.hello-vvm = { enable = true; domain = "hi.fere.me"; };
#
# The module fills in everything run-time (package, exec, socket env) as
# `mkDefault`s under `vacationvm.services.hello-vvm`, leaving the operator to
# decide only enablement, the public domain, and any secrets/greeting. The app
# stays DISABLED until the operator sets `enable = true`, so merely importing
# the module is inert.
#
# Note: this module does NOT depend on the vacationvm flake — it only *sets*
# options under `vacationvm.services.*`, which the fleet module (imported by the
# hive) declares. That keeps services decoupled from the framework version.

self:
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault;
  pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  config.vacationvm.services.hello-vvm = {
    package = mkDefault pkg;
    description = mkDefault "hello-vvm — a tiny vacationvm-style service";
    # Default ExecStart; the daemon reads its socket + greeting from the env
    # below. `listen` defaults to a Unix socket at /run/vacationvm-hello-vvm/sock,
    # which is exactly what VVM_HELLO_SOCKET points the daemon at.
    exec = mkDefault [ "${pkg}/bin/hello-vvm" ];
    environment = {
      VVM_HELLO_SOCKET = mkDefault "/run/vacationvm-hello-vvm/sock";
      VVM_HELLO_GREETING = mkDefault "hello from vacationvm";
    };
  };
}
