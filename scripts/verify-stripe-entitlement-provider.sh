#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-local}"
case "$MODE" in
  local|external|release) ;;
  *)
    echo "usage: $0 [local|external|release]" >&2
    exit 64
    ;;
esac

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

ACTUAL_SHA="$(git rev-parse HEAD)"
EXPECTED_SHA="${DIMYMINT_EXPECTED_SOURCE_SHA:-}"
if [[ -n "$EXPECTED_SHA" && "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "source revision mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
  exit 65
fi
if [[ "$MODE" != "local" && -z "$EXPECTED_SHA" ]]; then
  echo "DIMYMINT_EXPECTED_SOURCE_SHA is required in $MODE mode" >&2
  exit 66
fi
if [[ "$MODE" != "local" && -n "$(git status --porcelain)" ]]; then
  echo "$MODE mode requires a clean exact-revision checkout" >&2
  exit 67
fi

git diff --check
git diff --cached --check
python3 - <<'PY_PINS'
import json
from pathlib import Path
expected = json.loads(Path("scripts/dependency-baseline.json").read_text())
pins = json.loads(Path("Package.resolved").read_text())["pins"]
actual = {p["identity"]: {"location": p["location"], "state": p["state"]} for p in pins}
if actual != expected:
    raise SystemExit("Package.resolved differs from the reviewed dependency baseline")
if any(not p["location"].startswith("https://github.com/") for p in pins):
    raise SystemExit("Dependencies must use public HTTPS URLs")
manifest = Path("Package.swift").read_text()
if 'https://github.com/Digipomps/DiMyMicropayments.git' not in manifest or '.upToNextMinor(from: "2026.10.1")' not in manifest:
    raise SystemExit("Package.swift must use the public DiMyMicropayments release line")
PY_PINS
grep -Fq 'self.exposedRoutes = []' Sources/DiMyMintHTTP/MintHTTPRoutes.swift
if grep -R -n -E '/v1/.+(entitlement|quota)|StripeEntitlementProviderService' Sources/DiMyMintHTTP Sources/DiMyMintServer; then
  echo "The entitlement provider must not be exposed by a public HTTP route in v0." >&2
  exit 68
fi

if [[ -n "${DIMYMINT_TEST_POSTGRES_URL:-}" ]]; then
  PSQL_URL="${DIMYMINT_TEST_POSTGRES_PSQL_URL:-$DIMYMINT_TEST_POSTGRES_URL}"
  if [[ "$MODE" == "release" && "${DIMYMINT_TEST_POSTGRES_DISPOSABLE:-}" != "YES" ]]; then
    echo "release mode requires DIMYMINT_TEST_POSTGRES_DISPOSABLE=YES" >&2
    exit 70
  fi
  if [[ "$DIMYMINT_TEST_POSTGRES_URL" =~ ^postgres(ql)?://[^/@:]+:[^/@]+@ ]] \
     || [[ "$DIMYMINT_TEST_POSTGRES_URL" == *"password="* ]] \
     || [[ "$PSQL_URL" =~ ^postgres(ql)?://[^/@:]+:[^/@]+@ ]] \
     || [[ "$PSQL_URL" == *"password="* ]]; then
    echo "Use a credential-free PostgreSQL URL plus .pgpass, client certificate, or peer authentication." >&2
    exit 71
  fi
  command -v psql >/dev/null
  psql -d "$PSQL_URL" -v ON_ERROR_STOP=1 \
    -f db/migrations/0002_stripe_entitlement_provider_v0.sql
elif [[ "$MODE" == "release" ]]; then
  echo "release mode requires DIMYMINT_TEST_POSTGRES_URL for the real PostgreSQL gate" >&2
  exit 69
else
  echo "PostgreSQL gate not run; this result is not release certification." >&2
fi

run_swift_test() {
  # macOS /bin/bash 3.2 treats an empty array as unset under set -u.
  if [[ "$MODE" == "local" ]]; then
    swift test --jobs 2 "$@"
  else
    swift test --disable-automatic-resolution --jobs 2 "$@"
  fi
}

run_swift_test --filter StripeEntitlementProvider
run_swift_test

if [[ -n "${DIMYMINT_TEST_POSTGRES_URL:-}" ]]; then
  run_swift_test --filter PostgresStripeEntitlementProviderIntegrationTests
fi

if [[ "$MODE" != "local" && -n "$(git status --porcelain)" ]]; then
  echo "$MODE mode changed the exact checkout; commit the resolved dependency state before certification" >&2
  git status --short >&2
  exit 75
fi

if [[ "$MODE" == "local" && -n "$(git status --porcelain)" ]]; then
  echo "Stripe entitlement provider local working-tree gate passed (base $ACTUAL_SHA; not exact-commit evidence)."
else
  echo "Stripe entitlement provider $MODE gate passed for exact source $ACTUAL_SHA"
fi
