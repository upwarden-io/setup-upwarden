#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup-upwarden v2 credential writer: bundler (Ruby / RubyGems)
#
# Tier A writer. Bundler resolves per-source credentials from the environment
# variable BUNDLE_<HOST>, where <HOST> is the registry hostname mangled into an
# env-var-safe token. We therefore hand the credential to Bundler purely via
# $GITHUB_ENV (the GitHub Actions env file); we never write a credential file
# to disk. The Gemfile `source "https://<host>"` declaration is the user's
# responsibility -- this writer only wires the auth, not the source.
#
# Status: PENDING-LIVENESS. The engine serves the RubyGems protocol but it is
# not yet proven against a prod fixture. Wiring is correct per spec; treat as
# experimental until fixtures confirm.
#
# Inputs (all via env, exported by the v2 core before this writer runs):
#   UPWARDEN_CREDENTIAL      registry credential (vke_ token today; already masked)
#   UPWARDEN_REGISTRY_HOST   e.g. rubygems.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL    full resolved URL (informational for bundler)
#   UPWARDEN_TOOL            "bundler"
#   UPWARDEN_UNIT            optional; unused by this tool
#   UPWARDEN_WORKING_DIRECTORY  optional; unused (auth is env-based, not file-based)
# ---------------------------------------------------------------------------

# 1. Fail loud if the core handed us no credential.
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "setup-upwarden(bundler): UPWARDEN_CREDENTIAL is empty; cannot wire Bundler auth." >&2
  exit 1
fi

if [ -z "${UPWARDEN_REGISTRY_HOST:-}" ]; then
  echo "setup-upwarden(bundler): UPWARDEN_REGISTRY_HOST is empty; cannot compute BUNDLE_<HOST> var." >&2
  exit 1
fi

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "setup-upwarden(bundler): GITHUB_ENV is not set; not running inside GitHub Actions?" >&2
  exit 1
fi

# 2. Compute Bundler's env-var name from the host.
#    Bundler upcases the host and replaces '.' -> '__' and '-' -> '___'.
#    Order matters: do dots first, then hyphens (each maps to a distinct run of
#    underscores so the two substitutions do not collide).
HOST_UPPER="$(printf '%s' "$UPWARDEN_REGISTRY_HOST" | tr '[:lower:]' '[:upper:]')"
HOST_MANGLED="$(printf '%s' "$HOST_UPPER" | sed -e 's/\./__/g' -e 's/-/___/g')"
VAR_NAME="BUNDLE_${HOST_MANGLED}"

# Bundler credential form for a token-auth source is "token:x-oauth-basic"
# style; RubyGems/Bundler accepts "<user>:<pass>" -> here we use the literal
# username "token" with the credential as the password.
VAR_VALUE="token:${UPWARDEN_CREDENTIAL}"

# 3. No transform of the credential value itself (it is already masked by the
#    core), so no additional ::add-mask:: is required here.

# 4. Idempotent MERGE into $GITHUB_ENV: strip any prior line this writer wrote
#    for THIS var name, preserve everything else, then append the fresh line.
if [ -f "$GITHUB_ENV" ]; then
  tmp_env="$(mktemp)"
  # Drop existing "BUNDLE_<HOST>=..." lines; keep all other env entries intact.
  grep -v "^${VAR_NAME}=" "$GITHUB_ENV" > "$tmp_env" || true
  mv "$tmp_env" "$GITHUB_ENV"
fi
printf '%s=%s\n' "$VAR_NAME" "$VAR_VALUE" >> "$GITHUB_ENV"

# 5. One non-secret human log line. Note the Gemfile-source responsibility.
echo "setup-upwarden(bundler): wired Bundler auth via ${VAR_NAME} for host ${UPWARDEN_REGISTRY_HOST} (PENDING-LIVENESS). Your Gemfile must declare: source \"${UPWARDEN_REGISTRY_URL:-https://$UPWARDEN_REGISTRY_HOST}\"."
