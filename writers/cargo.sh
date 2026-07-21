#!/usr/bin/env bash
set -euo pipefail
#
# setup-upwarden v2 writer :: cargo (tier A, custom-registry mode)
# -----------------------------------------------------------------------------
# Wires `cargo` to install/publish through the Upwarden proxy by exporting a
# named alternate registry ("upwarden") via CARGO_REGISTRIES_* env vars into
# $GITHUB_ENV. Cargo reads these at build time, so nothing secret lands on disk.
#
# NOTE ON MIRRORING: making crates.io itself route transparently through the
# proxy would require [source.crates-io] source-replacement in a
# .cargo/config.toml. Cargo does NOT expose source-replacement via env vars, so
# it is out of scope for this env-only writer. Consumers opt in by naming the
# `upwarden` registry on a dependency (`registry = "upwarden"`).
#
# PENDING-LIVENESS: the engine serves the cargo protocol but it is not yet
# proven against a prod fixture. Treat this writer as not-yet-fixture-proven.
# -----------------------------------------------------------------------------

# Core exports these to GITHUB_ENV before any writer runs.
: "${UPWARDEN_CREDENTIAL:=}"
: "${UPWARDEN_REGISTRY_URL:=}"
: "${UPWARDEN_REGISTRY_HOST:=}"
: "${GITHUB_ENV:=}"

# Rule 1: refuse to proceed without a credential.
if [ -z "${UPWARDEN_CREDENTIAL}" ]; then
  echo "::error::[setup-upwarden/cargo] UPWARDEN_CREDENTIAL is empty; nothing to wire." >&2
  exit 1
fi

# Refuse a credential carrying a newline/CR: it would inject extra lines into
# GITHUB_ENV (a line-oriented file), corrupting the job env.
case "${UPWARDEN_CREDENTIAL}" in
  *$'\n'* | *$'\r'* )
    echo "::error::[setup-upwarden] credential contains a newline/CR — refusing to write it to the environment." >&2
    exit 1 ;;
esac

# The index needs a resolved URL; without it the sparse+ line is meaningless.
if [ -z "${UPWARDEN_REGISTRY_URL}" ]; then
  echo "::error::[setup-upwarden/cargo] UPWARDEN_REGISTRY_URL is empty; cannot build the sparse index." >&2
  exit 1
fi

if [ -z "${GITHUB_ENV}" ]; then
  echo "::error::[setup-upwarden/cargo] GITHUB_ENV is unset; cannot export registry vars." >&2
  exit 1
fi

# FOOTGUN: the "sparse+" scheme prefix is REQUIRED. Without it cargo silently
# falls back to the git index protocol and the proxy URL will not work.
INDEX_VALUE="sparse+${UPWARDEN_REGISTRY_URL}"

# The names we manage. Rule 4: strip any prior copies before re-appending so
# repeated runs stay idempotent and merge cleanly into a file other writers
# also append to (we only touch our own two keys, never the rest).
MANAGED_KEYS='CARGO_REGISTRIES_UPWARDEN_INDEX CARGO_REGISTRIES_UPWARDEN_TOKEN'

if [ -f "${GITHUB_ENV}" ]; then
  tmp="$(mktemp)"
  # Keep every line that is NOT one of our managed NAME=... assignments.
  rc=0; grep -vE '^(CARGO_REGISTRIES_UPWARDEN_INDEX|CARGO_REGISTRIES_UPWARDEN_TOKEN)=' \
    "${GITHUB_ENV}" > "${tmp}" || rc=$?
  [ "$rc" -le 1 ] || { echo "::error::[setup-upwarden] failed reading GITHUB_ENV" >&2; exit 1; }
  mv "${tmp}" "${GITHUB_ENV}"
fi

# Rule 2 (tier A): append NAME=value assignments to $GITHUB_ENV. The index is
# non-secret; the token is the credential, delivered as env (already masked by
# the core). We do not transform the credential, so no extra ::add-mask:: is
# needed (Rule 3 only applies to transformed values).
{
  echo "CARGO_REGISTRIES_UPWARDEN_INDEX=${INDEX_VALUE}"
  echo "CARGO_REGISTRIES_UPWARDEN_TOKEN=${UPWARDEN_CREDENTIAL}"
} >> "${GITHUB_ENV}"

# An auth-required sparse index needs a credential provider, otherwise cargo
# errors "authenticated registries require a credential-provider" and never
# sends the token. The built-in `cargo:token` provider consumes the
# CARGO_REGISTRIES_UPWARDEN_TOKEN we just exported. This is a global setting, so
# NEVER clobber an operator-supplied value: only inject our default when the key
# is unset in the process env AND absent from GITHUB_ENV (which also keeps repeat
# runs of this action idempotent — no duplicate line).
provider_set="${CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS:-}"
if [ -z "${provider_set}" ] \
   && ! grep -qE '^CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS=' "${GITHUB_ENV}" 2>/dev/null; then
  echo "CARGO_REGISTRY_GLOBAL_CREDENTIAL_PROVIDERS=cargo:token" >> "${GITHUB_ENV}"
fi

# Rule 5: exactly one non-secret human log line. Never echo the credential.
echo "[setup-upwarden/cargo] wired registry 'upwarden' -> ${INDEX_VALUE} (token via env; pending-liveness)"
