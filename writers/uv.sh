#!/usr/bin/env bash
#
# setup-upwarden v2 writer :: uv  (Tier A — pure env, no on-disk config file)
#
# Wires `uv` to install/publish through the Upwarden registry proxy by exporting
# a NAMED index ("upwarden") plus its HTTP-Basic credentials to $GITHUB_ENV, so
# every subsequent step in the job inherits them.
#
# uv has NO dedicated token env var: it authenticates a named index via
#   UV_INDEX_<NAME>_USERNAME / UV_INDEX_<NAME>_PASSWORD
# so the registry credential rides in the Basic *password* slot with a fixed
# `__token__` username (the proxy ignores the username and reads the password).
#
# Inputs (exported to GITHUB_ENV by the v2 core BEFORE this writer runs):
#   UPWARDEN_CREDENTIAL    - registry credential (vke_ token today / OIDC JWT soon);
#                            already ::add-mask::ed by the core.
#   UPWARDEN_REGISTRY_HOST - e.g. npm.pkg.upwarden.io (informational for uv here)
#   UPWARDEN_REGISTRY_URL  - full resolved index URL for this protocol
# Writer context inputs (may be unused for this tool):
#   UPWARDEN_TOOL, UPWARDEN_UNIT, UPWARDEN_WORKING_DIRECTORY
#
set -euo pipefail

# The fixed name of the uv index we manage. Everything derived from it stays in
# lockstep: the UV_DEFAULT_INDEX label and the UV_INDEX_<NAME>_* credential vars.
INDEX_NAME="upwarden"
INDEX_NAME_UC="UPWARDEN"   # uv upper-cases the index name in the env-var keys

# --- Rule 1: fail loudly on an empty credential. -----------------------------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "::error::[setup-upwarden] uv writer: UPWARDEN_CREDENTIAL is empty; nothing to wire." >&2
  exit 1
fi

# Refuse a credential carrying a newline/CR: it would inject extra lines into
# GITHUB_ENV (a line-oriented file), corrupting the job env.
case "${UPWARDEN_CREDENTIAL}" in
  *$'\n'* | *$'\r'* )
    echo "::error::[setup-upwarden] credential contains a newline/CR — refusing to write it to the environment." >&2
    exit 1 ;;
esac

# UV_DEFAULT_INDEX needs a resolved URL — a named index with no URL is useless.
if [ -z "${UPWARDEN_REGISTRY_URL:-}" ]; then
  echo "::error::[setup-upwarden] uv writer: UPWARDEN_REGISTRY_URL is empty; cannot set the default index URL." >&2
  exit 1
fi

# GITHUB_ENV is our sole output surface for a Tier A tool.
if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::[setup-upwarden] uv writer: GITHUB_ENV is not set; cannot export uv env." >&2
  exit 1
fi

# Defensive re-mask: the core already masked the credential, but masking is
# idempotent and cheap, and it guards against the credential being minted/rotated
# by a path that didn't mask. No transform is applied to the credential (it goes
# into a dedicated env var, NOT embedded into the URL), so no other value needs
# masking here — that's the footgun this Tier A design deliberately sidesteps.
echo "::add-mask::${UPWARDEN_CREDENTIAL}"

# The three keys this writer owns. Listed once so the merge-strip and the
# re-append below can never drift out of sync.
DEFAULT_INDEX_KEY="UV_DEFAULT_INDEX"
USERNAME_KEY="UV_INDEX_${INDEX_NAME_UC}_USERNAME"
PASSWORD_KEY="UV_INDEX_${INDEX_NAME_UC}_PASSWORD"

# --- Rule 4: idempotent MERGE. -----------------------------------------------
# Strip any prior lines WE manage from GITHUB_ENV (leaving every other key that
# other writers or the core wrote untouched), then append fresh values. This
# makes re-runs converge instead of stacking duplicate exports. Our values are
# guaranteed single-line (a token/JWT and a URL), so a line-oriented filter is
# safe and won't disturb any multiline (heredoc-delimited) entries other tools
# may have written.
if [ -s "${GITHUB_ENV}" ]; then
  tmp="$(mktemp)"
  rc=0; grep -v -E "^(${DEFAULT_INDEX_KEY}|${USERNAME_KEY}|${PASSWORD_KEY})=" "${GITHUB_ENV}" > "${tmp}" || rc=$?
  [ "$rc" -le 1 ] || { echo "::error::[setup-upwarden] failed reading GITHUB_ENV" >&2; exit 1; }
  cat "${tmp}" > "${GITHUB_ENV}"
  rm -f "${tmp}"
fi

# --- Append the uv wiring (Rule 2: Tier A writes NAME=value to GITHUB_ENV). ---
# UV_DEFAULT_INDEX uses uv's "name=url" form so this index is the default AND is
# addressable by name for the credential vars below.
{
  echo "${DEFAULT_INDEX_KEY}=${INDEX_NAME}=${UPWARDEN_REGISTRY_URL}"
  echo "${USERNAME_KEY}=__token__"
  echo "${PASSWORD_KEY}=${UPWARDEN_CREDENTIAL}"
} >> "${GITHUB_ENV}"

# --- Rule 5: exactly one non-secret human log line. --------------------------
echo "[setup-upwarden] uv: wired default index '${INDEX_NAME}' -> ${UPWARDEN_REGISTRY_URL} (Basic __token__, credential via ${PASSWORD_KEY})"
