# Fetch a box's ed25519 SSH host key and print the agenix recipient line.
#
# The box's SSH host key is its agenix identity: secrets are encrypted to it so
# they can be decrypted on activation. This reads it back over the network
# (TOFU — verify out of band if you're paranoid) and formats it for
# secrets/secrets.nix.
#
# Usage:  vacationvm-register-host <box-ip-or-hostname> [recipient-name]

set -euo pipefail

host="${1:-}"
name="${2:-wyrm}"

if [ -z "$host" ]; then
  echo "usage: vacationvm-register-host <box-ip-or-hostname> [recipient-name]" >&2
  exit 2
fi

echo "scanning $host for its ed25519 host key..." >&2
key="$(ssh-keyscan -T 10 -t ed25519 "$host" 2>/dev/null | awk '$2 == "ssh-ed25519" { print $2, $3; exit }')"

if [ -z "$key" ]; then
  echo "error: could not read an ed25519 host key from $host" >&2
  echo "       is sshd up? has the box finished its first boot?" >&2
  exit 1
fi

echo "" >&2
echo "Add this recipient to secrets/secrets.nix:" >&2
echo "" >&2
printf '  %s = "%s";\n' "$name" "$key"
echo "" >&2
echo "Then re-encrypt secrets to it:  agenix --rekey" >&2
