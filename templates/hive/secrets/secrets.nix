# agenix recipients map.
#
# Each `<name>.age` is encrypted to the listed public keys. The ONLY recipient
# that matters in production is the box's own SSH host key (ed25519) — that key
# is what decrypts secrets on the box at activation, and it is generated
# automatically on first boot. You usually also add your own user key so you
# can `agenix -e` a secret from your laptop.
#
# Fill in the box key after first boot:
#   ssh-keyscan -t ed25519 46.62.199.15
# (see docs/bootstrap.md, or run `vacationvm-register-host` from the framework).

let
  # The box's SSH host public key (decrypts secrets on the server):
  wyrm = "ssh-ed25519 AAAA...REPLACE_WITH_BOX_HOST_KEY...";

  # Your laptop key (so you can edit secrets):
  admin = "ssh-ed25519 AAAA...REPLACE_WITH_YOUR_KEY... you@laptop";

  all = [ wyrm admin ];
in
{
  # Porkbun API credentials — consumed by the DNS reconciler.
  "porkbun-api-key.age".publicKeys = all;
  "porkbun-secret-key.age".publicKeys = all;

  # Per-app secrets.
  "annexwyrm-password.age".publicKeys = all;
}
