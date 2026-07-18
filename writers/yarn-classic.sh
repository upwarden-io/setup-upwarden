#!/usr/bin/env bash
#
# setup-upwarden v2 credential writer — TOOL: yarn-classic (Tier B)
#
# Yarn v1 ("classic") has no first-class credential store of its own: for an
# npm-protocol registry it reads auth from an .npmrc, exactly like npm. So this
# writer produces <workdir>/.npmrc in the SAME shape the npm writer does:
#
#     registry=https://<host>/
#     //<host>/:_authToken=${UPWARDEN_CREDENTIAL}
#     always-auth=true
#
# Two things are load-bearing and easy to get wrong:
#
#   * Tier B => the credential is NEVER written to disk. The on-disk .npmrc
#     contains only the environment REFERENCE `${UPWARDEN_CREDENTIAL}`, which
#     npm/yarn resolve at install time. CORE has already exported
#     UPWARDEN_CREDENTIAL into the job env (GITHUB_ENV) before we run, so the
#     reference resolves in every later step.
#
#   * always-auth=true is MANDATORY for Yarn v1. Unlike npm >=7, classic Yarn
#     will NOT send the Authorization header on a plain `yarn install` unless
#     always-auth is set — the registry then answers 401/404 and the failure
#     looks like a missing package, not an auth problem. This is the footgun
#     this writer exists to encode.
#
# Inputs (all via env; exported by the v2 core before this writer runs):
#   UPWARDEN_CREDENTIAL         registry credential (vke_ today / OIDC JWT soon;
#                               already ::add-mask::ed by CORE)
#   UPWARDEN_REGISTRY_HOST      e.g. npm.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL       full resolved URL (informational; host drives .npmrc)
#   UPWARDEN_TOOL               "yarn-classic"
#   UPWARDEN_UNIT               optional; unused by this tool
#   UPWARDEN_WORKING_DIRECTORY  directory to write .npmrc into (default ".")

set -euo pipefail

# ---------------------------------------------------------------------------
# Rule 1: fail loudly if CORE handed us no credential. We still refuse even
# though we only write a reference — an empty credential means auth is broken,
# and silently wiring a dead .npmrc would just defer the failure to install.
# ---------------------------------------------------------------------------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "setup-upwarden(yarn-classic): UPWARDEN_CREDENTIAL is empty; refusing to wire an empty token (did CORE run?)." >&2
  exit 1
fi

# We build the registry + scoped-auth lines from the bare host, so require it.
if [ -z "${UPWARDEN_REGISTRY_HOST:-}" ]; then
  echo "setup-upwarden(yarn-classic): UPWARDEN_REGISTRY_HOST is empty; cannot build .npmrc registry/auth lines." >&2
  exit 1
fi

HOST="${UPWARDEN_REGISTRY_HOST}"
WORKDIR="${UPWARDEN_WORKING_DIRECTORY:-.}"

# The target directory is where the user runs `yarn`; ensure it exists so the
# write cannot fail on a not-yet-created working directory.
mkdir -p "$WORKDIR"
NPMRC="${WORKDIR%/}/.npmrc"

# ---------------------------------------------------------------------------
# Rule 3 (N/A): we do NOT transform the credential — it stays a `${...}`
# reference resolved at runtime — so no extra ::add-mask:: is required beyond
# the one CORE already emitted for the raw value.
# ---------------------------------------------------------------------------

# Sentinel markers delimit the block THIS writer owns. Everything between them
# (inclusive) is ours to replace; everything outside is the user's and is kept
# verbatim. This is what makes the merge in Rule 4 both safe and idempotent.
BEGIN_MARK='# >>> setup-upwarden (yarn-classic) managed — do not edit >>>'
END_MARK='# <<< setup-upwarden (yarn-classic) managed — do not edit <<<'

# ---------------------------------------------------------------------------
# Rule 4: idempotent MERGE. If an .npmrc already exists, strip any prior
# managed block (from a previous run of this writer) but preserve every other
# line the user put there (custom scopes, other registries, cache settings…).
# Marker-delimited deletion is precise: we never guess which loose `registry=`
# or `always-auth=` line was ours vs the user's.
# ---------------------------------------------------------------------------
if [ -f "$NPMRC" ]; then
  tmp="$(mktemp)"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inblock = 1; next }   # drop the begin marker, enter skip mode
    $0 == e { inblock = 0; next }   # drop the end marker, leave skip mode
    inblock { next }                # skip everything inside a prior block
    { print }                       # keep every user line as-is
  ' "$NPMRC" > "$tmp"
  mv "$tmp" "$NPMRC"

  # Guarantee the retained content ends in a newline so our appended block
  # cannot glue onto a user's final unterminated line.
  if [ -s "$NPMRC" ] && [ -n "$(tail -c 1 "$NPMRC")" ]; then
    printf '\n' >> "$NPMRC"
  fi
fi

# ---------------------------------------------------------------------------
# Rule 2: append our managed block. The auth line carries ONLY the literal
# text ${UPWARDEN_CREDENTIAL} — a runtime env reference, never the secret
# itself. Single-quote the heredoc-free printf inputs so the shell does NOT
# expand ${UPWARDEN_CREDENTIAL} here; it must land on disk verbatim.
# ---------------------------------------------------------------------------
{
  printf '%s\n' "$BEGIN_MARK"
  printf 'registry=https://%s/\n' "$HOST"
  printf '//%s/:_authToken=${UPWARDEN_CREDENTIAL}\n' "$HOST"
  printf 'always-auth=true\n'
  printf '%s\n' "$END_MARK"
} >> "$NPMRC"

# ---------------------------------------------------------------------------
# Rule 5: exactly one non-secret human log line.
# ---------------------------------------------------------------------------
echo "setup-upwarden(yarn-classic): wrote ${NPMRC} -> registry https://${HOST}/ with always-auth=true; auth via \${UPWARDEN_CREDENTIAL} env reference (no secret on disk)."
