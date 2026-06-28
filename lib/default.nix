# Pure helper functions for vacationvm.
#
# No I/O, no flake-input access, no `pkgs` — just `lib`. These are exposed as
# the flake's `lib` output (so downstream flakes and `nix eval` can use them)
# AND consumed by the fleet NixOS module to derive the desired DNS record set
# from the `vacationvm.services` declarations.
#
# The headline functions:
#   splitDomain     "blog.fere.me"            -> { apex = "fere.me"; sub = "blog"; }
#   recordsForApp   ip4 ip6 ttl app           -> [ { apex; name; type; content; ttl; } … ]
#   deriveRecords   cfg                        -> [ … ]   (every app + extras, deduped)
#   mkApp           { … }                      -> app submodule config (author ergonomics)

{ lib }:

let
  inherit (lib)
    splitString
    concatStringsSep
    sublist
    length
    hasSuffix
    removeSuffix
    filterAttrs
    mapAttrsToList
    concatMap
    optional
    optionals
    unique
    ;

  # ── Domain math ───────────────────────────────────────────────────────────
  # Heuristic apex = last two dot-separated labels. This is wrong for
  # public-suffix zones ("co.uk", "com.au") — declare `apex` explicitly on the
  # app/record in that case and it is used verbatim.
  inferApex =
    domain:
    let
      parts = splitString "." domain;
      n = length parts;
    in
    if n < 2 then domain else concatStringsSep "." (sublist (n - 2) 2 parts);

  splitDomain =
    {
      domain,
      apex ? null,
    }:
    let
      finalApex = if apex != null then apex else inferApex domain;
      sub =
        if domain == finalApex then
          ""
        else if hasSuffix ".${finalApex}" domain then
          removeSuffix ".${finalApex}" domain
        else
          # domain is not under the given apex; treat it as a bare label. The
          # Python reconciler will key on (apex, name, type) regardless.
          domain;
    in
    {
      apex = finalApex;
      sub = sub;
    };

  # ── Record normalisation ──────────────────────────────────────────────────
  # Turn a loosely-specified record into the canonical
  # { apex; name; type; content; ttl; } shape the reconciler consumes. A record
  # may be given as either `{ name; apex; … }` or `{ fqdn; … }`.
  normaliseRecord =
    defaultTtl: r:
    let
      hasFqdn = r ? fqdn && r.fqdn != null;
      split = splitDomain {
        domain = if hasFqdn then r.fqdn else "${name}.${apexFromName}";
        apex = r.apex or null;
      };
      # When only a bare name + apex are given, build the fqdn for splitting.
      apexFromName = r.apex or (throw "vacationvm: DNS record needs either `fqdn` or both `name` and `apex`");
      name = r.name or "";
      computed =
        if hasFqdn then
          { inherit (split) apex sub; }
        else
          {
            apex = r.apex;
            sub = if name == "@" then "" else name;
          };
    in
    {
      apex = computed.apex;
      name = computed.sub;
      type = r.type or "A";
      content = r.content;
      ttl = r.ttl or defaultTtl;
    };

  # ── Per-app derivation ────────────────────────────────────────────────────
  # ── Effective domain ──────────────────────────────────────────────────────
  # An explicit `app.domain` wins. Otherwise, if the app is `public` and the
  # fleet declares a `tenant` + `baseDomain`, the domain is
  # `<subdomain>.<tenant>.<baseDomain>` (subdomain defaulting to the app name).
  # Otherwise the app is not exposed (null).
  effectiveDomain =
    { tenant ? null, baseDomain ? null }:
    app:
    let
      explicit = app.domain or null;
      sub = if (app.subdomain or null) != null then app.subdomain else (app._name or app.name or null);
      isPublic = app.public or true;
    in
    if explicit != null then
      explicit
    else if isPublic && tenant != null && baseDomain != null && sub != null then
      "${sub}.${tenant}.${baseDomain}"
    else
      null;

  # For one app: an A record (always) and an AAAA record (when an IPv6 is
  # configured) pointing the app's effective FQDN at this box, plus the same for
  # each `aliases` FQDN, plus any verbatim `extraDnsRecords`.
  recordsForApp =
    {
      publicIp4,
      publicIp6 ? null,
      ttl,
      tenant ? null,
      baseDomain ? null,
    }:
    app:
    let
      domain = effectiveDomain { inherit tenant baseDomain; } app;
      hostFqdns = optional (domain != null) domain ++ (app.aliases or [ ]);
      mkAddr =
        fqdn:
        let
          s = splitDomain { domain = fqdn; };
        in
        [
          {
            apex = s.apex;
            name = s.sub;
            type = "A";
            content = publicIp4;
            inherit ttl;
          }
        ]
        ++ optionals (publicIp6 != null) [
          {
            apex = s.apex;
            name = s.sub;
            type = "AAAA";
            content = publicIp6;
            inherit ttl;
          }
        ];
      addrRecords = concatMap mkAddr hostFqdns;
      extra = map (normaliseRecord ttl) (app.extraDnsRecords or [ ]);
    in
    addrRecords ++ extra;

  # ── Fleet-level derivation ────────────────────────────────────────────────
  # Walk every *enabled* app with a domain, plus the fleet-wide
  # `dns.extraRecords`, and return the full desired set. Deduplicated on the
  # full record tuple so two apps sharing an alias don't double-emit.
  deriveRecords =
    cfg:
    let
      ttl = cfg.dns.ttl;
      enabledApps = filterAttrs (_: a: a.enable) cfg.services;
      appRecs = concatMap (
        recordsForApp {
          inherit (cfg) publicIp4;
          publicIp6 = cfg.publicIp6;
          tenant = cfg.tenant or null;
          baseDomain = cfg.baseDomain or null;
          inherit ttl;
        }
      ) (mapAttrsToList (n: a: a // { _name = n; }) enabledApps);
      extraRecs = map (normaliseRecord ttl) cfg.dns.extraRecords;
    in
    unique (appRecs ++ extraRecs);

  # The JSON document the reconciler reads.
  desiredDocument =
    cfg:
    {
      marker = cfg.dns.marker;
      ttl = cfg.dns.ttl;
      records = deriveRecords cfg;
    };

  # ── Author ergonomics ─────────────────────────────────────────────────────
  # `mkApp` is sugar for service flakes: it fills in the conventional unix
  # socket + state/runtime paths from the app name and the package's
  # mainProgram, so a service module only specifies what's non-default.
  mkApp =
    {
      name,
      package,
      mainProgram ? null,
      description ? name,
      socketEnv ? null,
      serveArgs ? [ ],
      initArgs ? null,
      staticFiles ? { },
      packages ? [ ],
      environment ? { },
      extra ? { },
    }:
    let
      bin = "${package}/bin/${if mainProgram != null then mainProgram else (package.meta.mainProgram or name)}";
      socket = "/run/vacationvm-${name}/sock";
    in
    {
      inherit
        package
        description
        staticFiles
        packages
        ;
      listen = {
        type = "unix";
        socket = socket;
      };
      exec = [ bin ] ++ serveArgs;
      preStart = lib.optionals (initArgs != null) [ ([ bin ] ++ initArgs) ];
      environment = environment // lib.optionalAttrs (socketEnv != null) { ${socketEnv} = socket; };
    }
    // extra;

in
{
  inherit
    inferApex
    splitDomain
    normaliseRecord
    effectiveDomain
    recordsForApp
    deriveRecords
    desiredDocument
    mkApp
    ;
}
