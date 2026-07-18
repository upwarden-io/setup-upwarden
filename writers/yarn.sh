#!/usr/bin/env bash
#
# setup-upwarden v2 credential writer — TOOL: yarn (Tier A)
#
# Yarn Berry (v2, v3, v4) reads its npm registry + auth entirely from the
# environment. There is NO file to write: we just export two variables into
# the GitHub Actions job env so every later step (and `yarn install`) sees them.
#
#   YARN_NPM_REGISTRY_SERVER  -> the resolved registry URL
#   YARN_NPM_AUTH_TOKEN       -> the bearer credential (vke_ today / OIDC JWT soon)
#
# Plug'n'Play (PnP) linker mode has no bearing on how auth is resolved, so it
# needs no special handling here.
#
# CORE has already exported (and ::add-mask::ed) the credential into GITHUB_ENV
# before this writer runs. We consume these from the environment:
#   UPWARDEN_CREDENTIAL     - registry credential (already masked by core)
#   UPWARDEN_REGISTRY_HOST  - e.g. npm.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL   - full resolved URL for this protocol
#   UPWARDEN_WORKING_DIRECTORY - default "." (unused for Tier A; logged for parity)

set -euo pipefail

# --- Rule 1: fail loudly if we have no credential to wire ---------------------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "setup-upwarden(yarn): UPWARDEN_CREDENTIAL is empty; refusing to wire an empty token." >&2
  exit 1
fi

# Refuse a credential carrying a newline/CR: it would inject extra lines into
# GITHUB_ENV (a line-oriented file), corrupting the job env.
case "${UPWARDEN_CREDENTIAL}" in
  *$'\n'* | *$'\r'* )
    echo "::error::[setup-upwarden] credential contains a newline/CR — refusing to write it to the environment." >&2
    exit 1 ;;
esac

# The registry URL is what Yarn will hit; require it too so we never wire auth
# pointed at nowhere.
if [ -z "${UPWARDEN_REGISTRY_URL:-}" ]; then
  echo "setup-upwarden(yarn): UPWARDEN_REGISTRY_URL is empty; cannot set YARN_NPM_REGISTRY_SERVER." >&2
  exit 1
fi

# GITHUB_ENV must exist — Tier A writers have nowhere else to export to.
if [ -z "${GITHUB_ENV:-}" ]; then
  echo "setup-upwarden(yarn): GITHUB_ENV is not set; not running inside GitHub Actions?" >&2
  exit 1
fi

# --- Rule 4: idempotent merge --------------------------------------------------
# GITHUB_ENV is an append-only file that GitHub replays into the job env. If this
# writer runs twice (or another step already set these), a naive append would
# leave duplicate/stale entries. We strip any prior upwarden-managed lines for
# the two names we own, keep everything else the user/other steps wrote, then
# re-append fresh values.
#
# Footgun encoded: GITHUB_ENV also supports a multi-line heredoc form
# (NAME<<DELIM ... DELIM). We ONLY ever emit the single-line NAME=value form
# (our values are a URL and an opaque token — no newlines), so a line-oriented
# filter is safe. We deliberately match `NAME=` and `NAME<<` prefixes so that if
# some earlier writer used the heredoc form we still drop its header — but we do
# NOT try to parse and remove a heredoc body, because inventing delimiter
# handling here would be more fragile than the problem warrants. Our own writes
# never produce a body, so re-runs of THIS writer stay clean.
if [ -s "$GITHUB_ENV" ]; then
  tmp_env="$(mktemp)"
  # Keep every line that is not one of our managed keys (single-line or heredoc header).
  # Distinguish grep's exit codes: 0 = matched (lines dropped), 1 = no match (all
  # lines kept) — both fine. rc >= 2 is a REAL error; because the `cat >` below
  # truncates $GITHUB_ENV first, swallowing it would silently wipe every prior
  # step's env vars, so we fail loud instead.
  rc=0
  grep -Ev '^(YARN_NPM_REGISTRY_SERVER|YARN_NPM_AUTH_TOKEN)(=|<<)' "$GITHUB_ENV" > "$tmp_env" || rc=$?
  [ "$rc" -le 1 ] || { echo '::error::[setup-upwarden] failed reading GITHUB_ENV' >&2; exit 1; }
  cat "$tmp_env" > "$GITHUB_ENV"
  rm -f "$tmp_env"
fi

# --- Rule 2: write only NAME=value into GITHUB_ENV (never a credential file) ---
# The credential lands in the Actions env, not a checked-out/persisted file.
# UPWARDEN_CREDENTIAL is already masked by CORE, so echoing it into GITHUB_ENV
# does not expose it in logs. No transform is applied (Rule 3 N/A: the token is
# passed through verbatim; the URL is used as-is), so no extra ::add-mask::.
{
  printf 'YARN_NPM_REGISTRY_SERVER=%s\n' "$UPWARDEN_REGISTRY_URL"
  printf 'YARN_NPM_AUTH_TOKEN=%s\n' "$UPWARDEN_CREDENTIAL"
} >> "$GITHUB_ENV"

# --- Rule 5: exactly one non-secret human log line ----------------------------
echo "setup-upwarden(yarn): wired Yarn Berry npm auth for ${UPWARDEN_REGISTRY_HOST:-$UPWARDEN_REGISTRY_URL} via YARN_NPM_REGISTRY_SERVER + YARN_NPM_AUTH_TOKEN (env only, no file; wd=${UPWARDEN_WORKING_DIRECTORY:-.})."
