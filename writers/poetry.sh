#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-upwarden v2 credential writer :: poetry  (tier C-env)
#
# Poetry consumes registry credentials purely from the environment, keyed by
# the *source name* declared in the user's pyproject.toml under
# [[tool.poetry.source]]. This writer wires the credentials for the source
# named "upwarden":
#
#     POETRY_HTTP_BASIC_UPWARDEN_USERNAME=__token__
#     POETRY_HTTP_BASIC_UPWARDEN_PASSWORD=<UPWARDEN_CREDENTIAL>
#     POETRY_KEYRING_ENABLED=false
#
# There is NO on-disk secret file for Poetry. The credential rides only in the
# job env via $GITHUB_ENV (an approved Tier-A sink; the core has already
# ::add-mask::ed the value). The install source itself must be declared by the
# user in pyproject.toml -- we only supply credentials, never the source.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Inputs (all via env; core exports the credential/registry vars) --------
: "${UPWARDEN_CREDENTIAL:=}"
: "${UPWARDEN_REGISTRY_HOST:=}"
: "${UPWARDEN_REGISTRY_URL:=}"
: "${UPWARDEN_UNIT:=}"
workdir="${UPWARDEN_WORKING_DIRECTORY:-.}"

# The Poetry source name we credential. Poetry uppercases the source name for
# the env-var key, so source "upwarden" -> POETRY_HTTP_BASIC_UPWARDEN_*.
SOURCE_NAME="upwarden"
SOURCE_KEY="UPWARDEN"

# --- Rule 1: fail loudly on an empty credential -----------------------------
if [ -z "${UPWARDEN_CREDENTIAL}" ]; then
  echo "::error::[setup-upwarden][poetry] UPWARDEN_CREDENTIAL is empty; nothing to write." >&2
  exit 1
fi

# $GITHUB_ENV must exist -- it is the only sink for this tier.
if [ -z "${GITHUB_ENV:-}" ] || [ ! -f "${GITHUB_ENV}" ]; then
  echo "::error::[setup-upwarden][poetry] \$GITHUB_ENV is unset or missing; cannot export Poetry credentials." >&2
  exit 1
fi

# --- Rule 4: idempotent merge -----------------------------------------------
# $GITHUB_ENV is our target "file". Strip any upwarden-managed lines from a
# prior run of this writer, keeping everything else the job put there, then
# re-append the current values. We only ever emit simple KEY=value lines, so a
# prefix filter is safe and will not corrupt other steps' heredoc blocks.
# The PASSWORD is written as a multi-line heredoc block (KEY<<DELIM / value /
# DELIM), so cleanup must strip that whole block, not just a KEY= line. The awk
# below captures the delimiter from a prior block's header and skips to its
# close, and still drops the USERNAME/KEYRING simple lines (and any legacy
# single-line PASSWORD= form) for good measure.
PW_KEY="POETRY_HTTP_BASIC_${SOURCE_KEY}_PASSWORD"
simple_re="^(POETRY_HTTP_BASIC_${SOURCE_KEY}_USERNAME|POETRY_KEYRING_ENABLED)="
tmp_env="$(mktemp)"
awk -v pw="${PW_KEY}" -v simple="${simple_re}" '
  BEGIN { hdr = pw "<<" }
  in_block { if ($0 == delim) in_block = 0; next }
  substr($0, 1, length(hdr)) == hdr { delim = substr($0, length(hdr) + 1); in_block = 1; next }
  index($0, pw "=") == 1 { next }
  $0 ~ simple { next }
  { print }
' "${GITHUB_ENV}" > "${tmp_env}"
cat "${tmp_env}" > "${GITHUB_ENV}"
rm -f "${tmp_env}"

# --- Write credentials into the job env -------------------------------------
# __token__ is the conventional username slot; the real secret is the password.
# POETRY_KEYRING_ENABLED=false is mandatory: keyring is on by default and, with
# no keyring backend in headless CI, Poetry hangs/errors on credential lookup.
# The PASSWORD value is untrusted-shaped: a newline in it would, in the plain
# KEY=value form, break GITHUB_ENV parsing and let a crafted credential inject
# further env vars. Emit it via the heredoc form with a random delimiter, and
# refuse to proceed if the credential happens to contain that delimiter (which
# would truncate the block). USERNAME/KEYRING are fixed literals -> plain form.
pw_delim="__UPW_EOF_${RANDOM}${RANDOM}${RANDOM}__"
case "${UPWARDEN_CREDENTIAL}" in
  *"${pw_delim}"*)
    echo "::error::[setup-upwarden][poetry] credential collides with the generated heredoc delimiter; refusing to write a corrupt GITHUB_ENV entry." >&2
    exit 1 ;;
esac
{
  echo "POETRY_HTTP_BASIC_${SOURCE_KEY}_USERNAME=__token__"
  echo "POETRY_HTTP_BASIC_${SOURCE_KEY}_PASSWORD<<${pw_delim}"
  echo "${UPWARDEN_CREDENTIAL}"
  echo "${pw_delim}"
  echo "POETRY_KEYRING_ENABLED=false"
} >> "${GITHUB_ENV}"

# --- Advisory: confirm the user actually declared the source ----------------
# We cannot add the source for the user (it lives in their pyproject.toml and
# affects dependency resolution). Warn clearly if it is absent so the "wired"
# log line below is not mistaken for "installs will now work".
pyproject="${workdir%/}/pyproject.toml"
if [ ! -f "${pyproject}" ]; then
  echo "::warning::[setup-upwarden][poetry] no pyproject.toml at ${pyproject}; add a [[tool.poetry.source]] named '${SOURCE_NAME}' (url = ${UPWARDEN_REGISTRY_URL:-https://${UPWARDEN_REGISTRY_HOST}/}) for these credentials to be used."
elif ! grep -qiE '^\s*\[\[tool\.poetry\.source\]\]' "${pyproject}" \
     || ! grep -qiE "^\s*name\s*=\s*[\"']${SOURCE_NAME}[\"']" "${pyproject}"; then
  echo "::warning::[setup-upwarden][poetry] ${pyproject} has no [[tool.poetry.source]] named '${SOURCE_NAME}'; add one (url = ${UPWARDEN_REGISTRY_URL:-https://${UPWARDEN_REGISTRY_HOST}/}) or Poetry will ignore these credentials."
fi

# --- Rule 5: exactly one non-secret human log line --------------------------
echo "[setup-upwarden][poetry] wired POETRY_HTTP_BASIC_${SOURCE_KEY}_* (source '${SOURCE_NAME}') + POETRY_KEYRING_ENABLED=false -> ${UPWARDEN_REGISTRY_HOST:-registry}"
