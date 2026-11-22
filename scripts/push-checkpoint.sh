#!/usr/bin/env bash
# Publish only the reviewed main checkpoint, even when local branches/tags contain private work.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[[ "$(git symbolic-ref -q --short HEAD)" == main ]] || { echo "Checkpoint requires main." >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo "Review outstanding changes before the checkpoint." >&2; exit 1; }
head=$(git rev-parse HEAD)
git fetch --quiet --no-tags origin refs/heads/main
base=$(git rev-parse FETCH_HEAD)
[[ "$head" != "$base" ]] || { echo "Checkpoint already on origin/main."; exit 0; }
git merge-base --is-ancestor "$base" "$head" || { echo "Origin has changes. Integrate them before retrying." >&2; exit 1; }
git diff --check "$base" "$head"
gitleaks git --redact --no-banner --log-opts="$base..$head" .
python3 scripts/check-docs-drift.py --range "$base..$head" --gate
swift test --package-path kit/MachineSpiritKit
swift test --package-path tools/ms
if ! git diff --quiet "$base" "$head" -- forks/LeaderKey; then
  (
    cd forks/LeaderKey
    xcodebuild -scheme 'Leader Key' -configuration Debug -derivedDataPath ./DerivedData.noindex \
      -skipPackagePluginValidation -skipMacroValidation -testPlan TestPlan '-only-testing:Leader KeyTests' \
      -parallel-testing-enabled NO -quiet test CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
      ENABLE_HARDENED_RUNTIME=NO MS_LEADER_SCHEME=msleaderkey-testing MS_LEGACY_SCHEME=leaderkey-testing \
      'PRODUCT_BUNDLE_IDENTIFIER=com.machinespirit.testing.menu.$(PRODUCT_NAME:rfc1034identifier)'
  )
fi
if ! git diff --quiet "$base" "$head" -- app/MachineSpirit kit/MachineSpiritKit; then
  (
    cd app/MachineSpirit
    xcodebuild -scheme MachineSpirit -configuration Debug -derivedDataPath DerivedData.noindex -quiet build \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  )
fi
[[ "$(git rev-parse HEAD)" == "$head" && -z "$(git status --porcelain)" ]] || { echo "Checkout changed during verification." >&2; exit 1; }
git -c remote.origin.mirror=false push --no-follow-tags --recurse-submodules=no origin "$head:refs/heads/main"
