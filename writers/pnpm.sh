#!/usr/bin/env bash
set -euo pipefail
#
# setup-upwarden v2 — per-tool credential writer: pnpm  (Tier B)
# -----------------------------------------------------------------------------
# Wires pnpm to install/publish through the Upwarden registry proxy.
#
# Tier B contract: the on-disk file NEVER contains the literal credential. It
# contains only an environment REFERENCE (${UPWARDEN_CREDENTIAL}) that npm/pnpm
# interpolate at runtime. The core has already exported UPWARDEN_CREDENTIAL to
# the job env (GITHUB_ENV) and ::add-mask::ed it, so the reference resolves at
# install time without the secret ever touching disk.
#
# WHY ~/.npmrc AND NOT THE PROJECT .npmrc (the footgun this writer encodes):
#   pnpm >= 11.5.3 deliberately DROPPED environment-variable interpolation in a
#   *project-level* .npmrc as a supply-chain hardening change — a checked-in
#   .npmrc can no longer siphon ${SECRETS} from the environment. Env expansion
#   still works in the *user* (~/.npmrc) and global configs. So a project-tier
#   token reference (which is exactly Tier B's whole mechanism) silently fails
#   to resolve on modern pnpm and auth breaks. We therefore write the USER file
#   and merge with whatever is already there.
#
# Inputs (all via env):
#   UPWARDEN_CREDENTIAL       required — registry credential (already masked)
#   UPWARDEN_REGISTRY_HOST    e.g. npm.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL     full resolved registry URL for this protocol
#   UPWARDEN_TOOL             "pnpm"
#   UPWARDEN_UNIT             optional npm scope (e.g. @acme); may be empty
#   UPWARDEN_WORKING_DIRECTORY  unused for Tier B (user file is global)
# -----------------------------------------------------------------------------

# Rule 1: fail loudly on an empty credential rather than writing dead auth.
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "::error::[setup-upwarden] pnpm writer: UPWARDEN_CREDENTIAL is empty; nothing to wire." >&2
  exit 1
fi

host="${UPWARDEN_REGISTRY_HOST:?UPWARDEN_REGISTRY_HOST is required}"
registry_url="${UPWARDEN_REGISTRY_URL:-https://${host}/}"
scope="${UPWARDEN_UNIT:-}"

# Deliberately the USER file — see WHY block above.
target="${HOME}/.npmrc"

# Idempotency markers: everything between them is owned by this writer and is
# rewritten on each run. Anything outside is the user's and is preserved.
begin_marker="# >>> upwarden-managed (setup-upwarden pnpm) >>>"
end_marker="# <<< upwarden-managed (setup-upwarden pnpm) <<<"

# Rule 4: MERGE. Strip any prior upwarden-managed block, keep every other line.
tmp="$(mktemp "${TMPDIR:-/tmp}/upwarden-npmrc.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
if [ -f "${target}" ]; then
  awk -v b="${begin_marker}" -v e="${end_marker}" '
    $0 == b { skip = 1; next }   # enter our block: start dropping
    $0 == e { skip = 0; next }   # leave our block: resume keeping
    skip != 1 { print }          # keep everything outside our block
  ' "${target}" > "${tmp}"
fi

# Append a freshly generated managed block. Note the SINGLE-quoted heredoc-free
# writes: the ${UPWARDEN_CREDENTIAL} token below is written LITERALLY (escaped
# $ under -e), so the file carries a reference, not the secret (Rule 2).
{
  echo "${begin_marker}"
  echo "# Written to the USER ~/.npmrc (not the project file) because pnpm"
  echo "# >= 11.5.3 no longer interpolates env vars in a project-level .npmrc."
  echo "registry=${registry_url}"
  # scoped registry mapping when a unit/scope was supplied
  if [ -n "${scope}" ]; then
    # normalise: ensure a single leading '@'
    scope_norm="@${scope#@}"
    echo "${scope_norm}:registry=${registry_url}"
  fi
  # host-scoped token line — reference only, resolved from the job env.
  echo "//${host}/:_authToken=\${UPWARDEN_CREDENTIAL}"
  echo "always-auth=true"
  echo "${end_marker}"
} >> "${tmp}"

# Atomically swap the merged file into place.
mv "${tmp}" "${target}"
trap - EXIT

# Rule 5: exactly one non-secret human log line.
echo "[setup-upwarden] pnpm: merged ${target} -> ${registry_url}${scope:+ (scope ${scope})} (token by \${UPWARDEN_CREDENTIAL} reference)"
