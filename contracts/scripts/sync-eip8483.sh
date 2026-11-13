#!/usr/bin/env bash
# Copies the runtime bytecode of EIP-8483's two contracts, which the tests use as the reference
# for the registration contracts.
#
#     contracts/scripts/sync-eip8483.sh [<ethereum/EIPs commit>]
#
# Without a commit, it takes the latest version of the EIP: master once the EIP is merged, and the
# head of ethereum/EIPs#12609 until then. It writes the runtime bytecode of the validator and the
# builder contract to contracts/test/vectors/eip8483/, along with the commit it read.
set -euo pipefail

repo=https://github.com/ethereum/EIPs
pr=12609
here=$(cd "$(dirname "$0")" && pwd)
dest="$here/../test/vectors/eip8483"

eip() {
  curl -fsSL "https://raw.githubusercontent.com/ethereum/EIPs/$1/EIPS/eip-8483.md"
}

if [[ $# -gt 0 ]]; then
  commit=$1
else
  commit=$(git ls-remote "$repo" refs/heads/master | cut -f1)
  if ! eip "$commit" >/dev/null 2>&1; then
    commit=$(git ls-remote "$repo" "refs/pull/$pr/head" | cut -f1)
  fi
fi

text=$(eip "$commit") || {
  echo "error: no EIPS/eip-8483.md in ethereum/EIPs at $commit" >&2
  exit 1
}

# The EIP lists each contract's runtime bytecode in the code block after a "Runtime bytecode:"
# line, the validator contract's first and then the builder contract's.
mapfile -t runtimes < <(awk '
  /^Runtime bytecode:/ { want = 1; next }
  want && /^0x[0-9a-f]+$/ { print; want = 0 }
' <<<"$text")
if [[ ${#runtimes[@]} -ne 2 ]]; then
  echo "error: expected 2 runtime bytecodes in EIP-8483 at $commit, found ${#runtimes[@]}" >&2
  exit 1
fi

mkdir -p "$dest"
printf '%s\n' "${runtimes[0]}" >"$dest/validator.hex"
printf '%s\n' "${runtimes[1]}" >"$dest/builder.hex"
echo "$commit" >"$dest/COMMIT"
echo "copied EIP-8483's runtime bytecode at $commit"
