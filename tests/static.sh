#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for f in scripts/*.sh scripts/*.initd tests/*.sh; do
  sh -n "$f"
done
[ -f README.md ]
[ -f .github/workflows/ci.yml ]
grep -q 'GLENV_REF' scripts/bootstrap.sh
grep -q 'nix-daemon' scripts/bootstrap.sh
printf 'Static checks passed\n'
