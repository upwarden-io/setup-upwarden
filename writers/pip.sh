#!/usr/bin/env bash
#
# setup-upwarden v2 credential writer — TOOL: pip (Tier A)
#
# Pip has no first-class credential store: it carries the registry
# credential INSIDE the index URL. That means the credential must be
# percent-encoded (a vke_ token — and soon an OIDC JWT — contains '/',
# '+' and '=' which would otherwise break URL parsing) and then exported
# as PIP_INDEX_URL via $GITHUB_ENV so every subsequent `pip install` in
# the job picks it up.
#
# Tier A => we append NAME=value to the file named by $GITHUB_ENV.
# No credential file is written to disk.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "pip writer: UPWARDEN_CREDENTIAL is empty — nothing to wire (did CORE run?)" >&2
  exit 1
fi

if [ -z "${UPWARDEN_REGISTRY_HOST:-}" ]; then
  echo "pip writer: UPWARDEN_REGISTRY_HOST is empty — cannot build PIP_INDEX_URL" >&2
  exit 1
fi

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "pip writer: GITHUB_ENV is not set — not running inside a GitHub Actions job?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Percent-encode the credential (RFC 3986 unreserved set is kept as-is)
# ---------------------------------------------------------------------------
# Footgun: the raw ::add-mask:: applied by CORE only masks the *raw* token
# string. Once we percent-encode it, '/' becomes '%2F', '=' becomes '%3D',
# etc., which the raw mask will NOT catch — so we MUST emit a fresh mask for
# the encoded form (step 3) BEFORE it can appear in any log or the env file.
urlencode() {
  local string="$1"
  local length=${#string}
  local out=""
  local i c
  i=0
  while [ "$i" -lt "$length" ]; do
    c=${string:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-])
        # unreserved — safe verbatim
        out="$out$c"
        ;;
      *)
        # everything else -> %HH (uppercase hex of the byte)
        out="$out$(printf '%%%02X' "'$c")"
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

ENCODED_CREDENTIAL="$(urlencode "$UPWARDEN_CREDENTIAL")"

# ---------------------------------------------------------------------------
# 3. Mask the TRANSFORMED value before it can surface anywhere
# ---------------------------------------------------------------------------
echo "::add-mask::${ENCODED_CREDENTIAL}"

# ---------------------------------------------------------------------------
# 4. Build the index URL and MERGE it into $GITHUB_ENV idempotently
# ---------------------------------------------------------------------------
PIP_INDEX_URL_VALUE="https://__token__:${ENCODED_CREDENTIAL}@${UPWARDEN_REGISTRY_HOST}/simple/"

# Drop any prior upwarden-managed PIP_INDEX_URL line, keep everything else the
# user (or another writer) put in the env file, then append our fresh value.
# GITHUB_ENV is a flat KEY=value / KEY<<HEREDOC file; a plain grep -v on the
# exact key is the safe, comment-free way to de-dupe.
if [ -f "$GITHUB_ENV" ]; then
  tmp="$(mktemp)"
  grep -v '^PIP_INDEX_URL=' "$GITHUB_ENV" > "$tmp" || true
  mv "$tmp" "$GITHUB_ENV"
fi

printf 'PIP_INDEX_URL=%s\n' "$PIP_INDEX_URL_VALUE" >> "$GITHUB_ENV"

# ---------------------------------------------------------------------------
# 5. One non-secret human log line
# ---------------------------------------------------------------------------
echo "pip: wired PIP_INDEX_URL for __token__@${UPWARDEN_REGISTRY_HOST}/simple/ (credential percent-encoded, masked)"
