#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-upwarden v2 credential writer :: nuget  (tier C-env, PENDING-LIVENESS)
#
# Wires a workspace so `dotnet`/`nuget` restore & push run through the Upwarden
# proxy. Two moving parts:
#   1. A NON-SECRET nuget.config in the working directory that registers the
#      "Upwarden" package source (source URL only, never the credential).
#   2. The credential, delivered to the tool at runtime via a job-env line
#      appended to $GITHUB_ENV. NuGet reads per-source credentials from the
#      env var  NuGetPackageSourceCredentials_<SourceName>  where the value is
#      the literal string  Username=<u>;Password=<p> .
#
# The credential is NEVER written to a file on disk (hard rule 2). It only ever
# lands in $GITHUB_ENV (the Actions job-env file), already ::add-mask::ed by the
# v2 core before this writer runs.
#
# FOOTGUN encoded below: NuGet parses NuGetPackageSourceCredentials_* by
# splitting on ';' and '='. A credential value that itself contains ';' or '='
# is silently mangled -> the Password NuGet actually sends is wrong -> the feed
# 401s with no useful diagnostic. Rather than ship a feed that will fail at
# restore time, we detect that case and fail loudly here.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- inputs (from job env, exported by the v2 core) ------------------------
CRED="${UPWARDEN_CREDENTIAL:-}"
REG_URL="${UPWARDEN_REGISTRY_URL:-}"
WORKDIR="${UPWARDEN_WORKING_DIRECTORY:-.}"

# The NuGet source name. This MUST match the "_Upwarden" segment of the env var
# name below EXACTLY: on Linux the <name> segment of
# NuGetPackageSourceCredentials_<name> is case-sensitive, so a mismatch means
# NuGet never associates the credential with the source.
SOURCE_NAME="Upwarden"
ENV_KEY="NuGetPackageSourceCredentials_${SOURCE_NAME}"

# --- guards ----------------------------------------------------------------
# Hard rule 1: no credential -> hard fail.
if [ -z "${CRED}" ]; then
  echo "::error::[setup-upwarden] nuget: UPWARDEN_CREDENTIAL is empty; nothing to write." >&2
  exit 1
fi

if [ -z "${REG_URL}" ]; then
  echo "::error::[setup-upwarden] nuget: UPWARDEN_REGISTRY_URL is empty; cannot register a source." >&2
  exit 1
fi

# FOOTGUN guard: a ';' or '=' in the credential is silently mis-parsed and
# IGNORED by NuGet's "Username=...;Password=..." credential encoding. Fail loud
# instead of shipping a feed that 401s at restore time.
case "${CRED}" in
  *";"* )
    echo "::error::[setup-upwarden] nuget: credential contains ';', which NuGet's NuGetPackageSourceCredentials_* encoding cannot represent (it splits on ';'). Refusing to write a feed that would silently fail to authenticate." >&2
    exit 1 ;;
  *"="* )
    echo "::error::[setup-upwarden] nuget: credential contains '=', which NuGet's NuGetPackageSourceCredentials_* encoding cannot represent (it splits key/value on '='). Refusing to write a feed that would silently fail to authenticate." >&2
    exit 1 ;;
  *$'\n'* | *$'\r'* )
    echo "::error::[setup-upwarden] nuget: credential contains a newline/CR — refusing to write a corrupt NuGet credential." >&2
    exit 1 ;;
esac

# --- locate / prepare the on-disk nuget.config -----------------------------
# NuGet resolves config case-insensitively; find an existing one in workdir
# (any case) so we merge rather than create a stray second file. Non-recursive:
# we only touch the config in the working directory the caller pointed us at.
mkdir -p "${WORKDIR}"
CONFIG=""
for candidate in "${WORKDIR}"/nuget.config "${WORKDIR}"/NuGet.Config "${WORKDIR}"/NuGet.config "${WORKDIR}"/Nuget.Config; do
  if [ -f "${candidate}" ]; then
    CONFIG="${candidate}"
    break
  fi
done

# A managed marker so re-runs can strip our previous source line cleanly
# (hard rule 4: merge, don't clobber; idempotent).
MANAGED_ADD="    <add key=\"${SOURCE_NAME}\" value=\"${REG_URL}\" /> <!-- upwarden-managed -->"

if [ -z "${CONFIG}" ]; then
  # No config present -> create a minimal, non-secret one. <clear/> drops any
  # inherited/global sources so restores go through the Upwarden proxy
  # deterministically; then declare our source.
  CONFIG="${WORKDIR}/nuget.config"
  cat > "${CONFIG}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
${MANAGED_ADD}
  </packageSources>
</configuration>
EOF
  WROTE="created ${CONFIG}"
else
  # Merge into the user's existing config.
  #   1. strip any prior upwarden-managed source line (idempotent re-run),
  #   2. re-insert our source just before </packageSources>.
  # If there is no <packageSources> section we add one before </configuration>.
  TMP="$(mktemp)"
  # Step 1: drop our previously managed line (marker-tagged) if present.
  grep -v 'upwarden-managed' "${CONFIG}" > "${TMP}" || true

  if grep -q '</packageSources>' "${TMP}"; then
    # Insert our source line immediately before the first closing tag.
    awk -v add="${MANAGED_ADD}" '
      !done && /<\/packageSources>/ { print add; done=1 }
      { print }
    ' "${TMP}" > "${CONFIG}"
  elif grep -q '</configuration>' "${TMP}"; then
    # No packageSources section yet: introduce a complete one.
    awk -v add="${MANAGED_ADD}" '
      !done && /<\/configuration>/ {
        print "  <packageSources>"
        print add
        print "  </packageSources>"
        done=1
      }
      { print }
    ' "${TMP}" > "${CONFIG}"
  else
    # Malformed / unrecognizable config: refuse to guess and corrupt it.
    rm -f "${TMP}"
    echo "::error::[setup-upwarden] nuget: existing ${CONFIG} has no </packageSources> or </configuration> to merge into; refusing to overwrite a user file." >&2
    exit 1
  fi
  rm -f "${TMP}"
  WROTE="merged source into ${CONFIG}"
fi

# --- deliver the credential via job env (never to disk) --------------------
# NuGet reads the per-source credential from this env var at restore/push time.
# The value format is exactly "Username=<u>;Password=<p>" — the guards above
# guarantee the credential contains no ';' or '=' so this encoding is
# unambiguous. Username "token" is a fixed literal the proxy ignores.
#
# We append rather than rewrite $GITHUB_ENV: Actions applies last-wins per key,
# so a re-run's later line supersedes an earlier one (idempotent at resolution
# time), and appending avoids clobbering multiline heredoc entries that other
# steps may have written to the same file.
echo "${ENV_KEY}=Username=token;Password=${CRED}" >> "${GITHUB_ENV}"

# --- one non-secret human log line -----------------------------------------
echo "[setup-upwarden] nuget: registered source '${SOURCE_NAME}' -> ${REG_URL} (${WROTE}); credential via ${ENV_KEY} (job env, not on disk). [pending-liveness]"
