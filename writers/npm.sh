#!/usr/bin/env bash
#
# setup-upwarden v2 credential writer — npm (Tier B)
#
# Writes <workdir>/.npmrc so `npm`, `npx`, `pnpm`, `yarn` install/publish
# through the Upwarden ecosystem proxy. The registry credential is NEVER
# written to disk: the on-disk _authToken line carries the LITERAL string
# `${UPWARDEN_CREDENTIAL}`, which npm resolves from the process environment at
# install time. The v2 core has already exported UPWARDEN_CREDENTIAL to the
# job env (GITHUB_ENV) and ::add-mask::ed its value before this writer runs.
#
# Inputs (env, provided by the core):
#   UPWARDEN_CREDENTIAL        registry credential (vke_ token / OIDC JWT) — masked
#   UPWARDEN_REGISTRY_HOST     e.g. npm.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL      full resolved registry URL for npm
#   UPWARDEN_WORKING_DIRECTORY target dir for .npmrc (default: current dir)
#   UPWARDEN_TOOL / UPWARDEN_UNIT  informational (unused here)

set -euo pipefail

# --- 1. Refuse to run without a credential ---------------------------------
# The reference in .npmrc is useless if the env var it points at is empty, and
# a silent no-auth .npmrc would fail installs with a confusing 401 later.
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "::error::[setup-upwarden] npm writer: UPWARDEN_CREDENTIAL is empty — nothing to wire." >&2
  exit 1
fi

host="${UPWARDEN_REGISTRY_HOST:?[setup-upwarden] npm writer: UPWARDEN_REGISTRY_HOST is required}"
url="${UPWARDEN_REGISTRY_URL:?[setup-upwarden] npm writer: UPWARDEN_REGISTRY_URL is required}"
workdir="${UPWARDEN_WORKING_DIRECTORY:-.}"

# --- 2. Resolve the target file --------------------------------------------
mkdir -p "${workdir}"
target="${workdir%/}/.npmrc"

# Block markers let us find and replace ONLY our own lines on a re-run, leaving
# any user-authored .npmrc content untouched (idempotent merge).
begin='# >>> upwarden-managed (setup-upwarden) >>>'
end='# <<< upwarden-managed (setup-upwarden) <<<'

# --- 3. Merge: strip any prior upwarden-managed block, keep everything else -
# Drop the fenced block (inclusive of both markers). awk keeps every other
# line verbatim, so a hand-maintained .npmrc survives intact.
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
if [ -f "${target}" ]; then
  awk -v b="${begin}" -v e="${end}" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip != 1 { print }
  ' "${target}" > "${tmp}"
  # Guarantee the surviving user content ends with a newline so our appended
  # block never glues onto the user's last line.
  if [ -s "${tmp}" ] && [ "$(tail -c1 "${tmp}"; echo x)" != $'\nx' ]; then
    printf '\n' >> "${tmp}"
  fi
fi

# --- 4. Append our block ----------------------------------------------------
# FOOTGUN encoded here: the _authToken value must land on disk as the LITERAL
# eight-plus-eleven characters `${UPWARDEN_CREDENTIAL}`, NOT the expanded
# secret. Single quotes around that fragment stop the shell expanding it; npm
# does the env expansion itself at runtime. `registry=` and the block go LAST
# so they win over any earlier user-set default for the same keys.
{
  echo "${begin}"
  echo "registry=${url}"
  echo "//${host}/:_authToken="'${UPWARDEN_CREDENTIAL}'
  echo "always-auth=true"
  echo "${end}"
} >> "${tmp}"

mv "${tmp}" "${target}"
trap - EXIT

# --- 5. One non-secret human log line --------------------------------------
echo "[setup-upwarden] npm: wired ${target} -> ${url} (auth via \${UPWARDEN_CREDENTIAL}, never on disk)"
