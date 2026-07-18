#!/usr/bin/env bash
#
# setup-upwarden v2 writer :: TOOL=gradle (tier C)
# ---------------------------------------------------------------------------
# Wires Gradle dependency resolution through the Upwarden registry by writing a
# global init script at ~/.gradle/init.gradle. The script declares a maven
# repository for `allprojects` and authenticates it with HTTP Basic
# (PasswordCredentials, username "token" + the credential as password). We use
# Basic rather than a pre-set Bearer header because the proxy challenges maven
# clients on a 401 with  WWW-Authenticate: Basic realm="vanguard"  — a static
# Authorization header does not participate in that challenge-response (first
# request / cache-miss / credential rotation), so Basic is the idiomatic form.
# The proxy accepts the vk_/credential as the Basic password.
#
# The init script is NON-SECRET: it never embeds the credential value. At
# resolution time Gradle reads System.getenv("UPWARDEN_CREDENTIAL"), which the
# v2 CORE has already exported into GITHUB_ENV (and thus the job process env)
# before this writer runs.
#
# Inputs (all via env, set by CORE):
#   UPWARDEN_CREDENTIAL       registry credential (already ::add-mask::ed)  [required]
#   UPWARDEN_REGISTRY_URL     full resolved maven repo URL for this protocol [required]
#   UPWARDEN_REGISTRY_HOST    registry host (for the human log line)
#   UPWARDEN_TOOL             "gradle"
#   UPWARDEN_UNIT             optional; unused for the global init script
#   UPWARDEN_WORKING_DIRECTORY optional; unused (init.gradle is user-global)
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Rule 1: fail loud & early if there is no credential to wire. -----------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "::error::[setup-upwarden] gradle writer: UPWARDEN_CREDENTIAL is empty; nothing to wire." >&2
  exit 1
fi
if [ -z "${UPWARDEN_REGISTRY_URL:-}" ]; then
  echo "::error::[setup-upwarden] gradle writer: UPWARDEN_REGISTRY_URL is empty." >&2
  exit 1
fi

# The credential is not transformed here (no percent-encoding: it lives in an
# env var read at runtime, never in a URL), so no extra ::add-mask:: is needed.
# CORE has already masked UPWARDEN_CREDENTIAL. We deliberately do NOT re-echo it.

registry_url="${UPWARDEN_REGISTRY_URL}"
registry_host="${UPWARDEN_REGISTRY_HOST:-${registry_url}}"

# The URL is interpolated into a Groovy SINGLE-quoted string literal below. A
# single-quote or backslash would break out of / corrupt that literal, and a
# newline would break the statement — and since this is a GLOBAL init.gradle, a
# parse error breaks EVERY gradle invocation on the runner. Reject those here.
case "${registry_url}" in
  *"'"* | *"\\"* | *$'\n'* )
    echo "::error::[setup-upwarden] gradle writer: UPWARDEN_REGISTRY_URL contains a single-quote, backslash, or newline; refusing to write an init.gradle that would break all gradle invocations." >&2
    exit 1 ;;
esac

gradle_home="${GRADLE_USER_HOME:-${HOME}/.gradle}"
init_file="${gradle_home}/init.gradle"
mkdir -p "${gradle_home}"

# Marker lines delimiting the block we own, so re-runs MERGE (strip our old
# block, keep any user-authored content) instead of clobbering the file.
begin_marker="// >>> setup-upwarden managed block (do not edit) >>>"
end_marker="// <<< setup-upwarden managed block <<<"

# --- Rule 4: idempotent merge. Drop any prior managed block, keep the rest. --
tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT
if [ -f "${init_file}" ]; then
  # awk: print everything OUTSIDE a begin..end marker pair (inclusive skip),
  # then drop trailing blank lines. Trimming trailing blanks is what keeps the
  # output byte-stable across re-runs (otherwise the separator blank line below
  # accumulates one extra blank per run — a subtle idempotency footgun).
  awk -v b="${begin_marker}" -v e="${end_marker}" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    skip == 1 { next }
    { lines[++n] = $0 }
    END {
      last = 0
      for (i = 1; i <= n; i++) if (lines[i] != "") last = i
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' "${init_file}" > "${tmp_file}"
else
  : > "${tmp_file}"
fi

# --- Rule 2: on-disk file carries only an env REFERENCE, never the value. ----
# Gradle resolves System.getenv("UPWARDEN_CREDENTIAL") at dependency-resolution
# time. The URL is embedded verbatim via uri(); it is non-secret.
{
  # Preserve prior (non-managed) content, then append a freshly-generated block.
  cat "${tmp_file}"
  # Ensure separation from any preserved user content.
  echo ""
  echo "${begin_marker}"
  cat <<EOF
allprojects {
    repositories {
        maven {
            url = uri('${registry_url}')
            credentials(PasswordCredentials) {
                // Password is read at runtime from the env var CORE exported;
                // the credential is never written to this file. PasswordCredentials
                // sends HTTP Basic by default, which participates in the proxy's
                // Basic realm="vanguard" 401 challenge-response.
                username = "token"
                password = System.getenv("UPWARDEN_CREDENTIAL")
            }
        }
    }
}
EOF
  echo "${end_marker}"
} > "${init_file}"

# --- Rule 5: exactly one non-secret human log line. -------------------------
echo "[setup-upwarden] gradle: wrote ${init_file} -> maven repo ${registry_host} (HTTP Basic via PasswordCredentials, credential read from env at runtime)"
