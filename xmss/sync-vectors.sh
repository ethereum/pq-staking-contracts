#!/usr/bin/env bash
# Copy EthLib's leanXMSS test vectors at one commit.
#
#     xmss/sync-vectors.sh <ethlib-commit>
#
# Replaces contracts/test/vectors/ethlib/xmss with the `verify` and `signature_index` cases of
# EthLib's tests/cryptography/xmss at that commit, checks every case against EthLib's
# SHA256SUMS, and records the commit in contracts/test/vectors/ethlib/COMMIT.
set -euo pipefail

commit=${1:?usage: sync-vectors.sh <ethlib-commit>}
here=$(cd "$(dirname "$0")" && pwd)
dest="$here/../contracts/test/vectors/ethlib"
# The operations LeanXmss.sol implements.
operations=(verify signature_index)

# One archive of EthLib at that commit, unpacked outside the tree.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL "https://codeload.github.com/ethereum/EthLib/tar.gz/$commit" | tar -xz -C "$work"

src=$(echo "$work"/*/tests/cryptography/xmss)
[[ -d "$src" ]] || {
  echo "error: no tests/cryptography/xmss in EthLib at $commit" >&2
  exit 1
}

# The digests EthLib pins must hold before anything is copied.
for operation in "${operations[@]}"; do
  (cd "$src" && grep " $operation/" SHA256SUMS | sha256sum --quiet -c -)
done

rm -rf "$dest/xmss"
mkdir -p "$dest/xmss"
for operation in "${operations[@]}"; do
  cp -R "$src/$operation" "$dest/xmss/$operation"
  echo "copied $(find "$dest/xmss/$operation" -name data.yaml | wc -l) $operation cases"
done
echo "$commit" >"$dest/COMMIT"
