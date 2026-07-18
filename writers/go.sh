#!/usr/bin/env bash
#
# setup-upwarden v2 — per-tool credential writer: go (Go modules / GOPROXY)
#
# TIER A, PENDING-LIVENESS. Wires the Go toolchain to the Upwarden module
# proxy for THIS job by appending env vars to $GITHUB_ENV and installing a
# tiny, NON-SECRET GOAUTH helper that reads the bearer token from the
# environment at runtime (the token value is never written to disk).
#
# Requires Go 1.24+ (the GOAUTH "command" form landed in 1.24). Older Go
# needs a ~/.netrc, which is explicitly OUT OF SCOPE here.
#
# Inputs (from env, exported by the v2 core before any writer runs):
#   UPWARDEN_CREDENTIAL     registry credential (vke_ today / OIDC JWT soon;
#                           already ::add-mask::ed by the core)
#   UPWARDEN_REGISTRY_HOST  e.g. go.pkg.upwarden.io
#   UPWARDEN_REGISTRY_URL   full resolved proxy URL for this protocol
#   UPWARDEN_TOOL           "go"
#   UPWARDEN_UNIT           optional; unused for go (env is job-global)
#   UPWARDEN_WORKING_DIRECTORY  optional; unused for go (env is job-global)
#   GITHUB_ENV              path to the job env file we append to (Tier A)

set -euo pipefail

# --- Rule 1: fail loudly if we have no credential -----------------------------
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "setup-upwarden[go]: UPWARDEN_CREDENTIAL is empty — cannot wire the Go proxy." >&2
  exit 1
fi
if [ -z "${UPWARDEN_REGISTRY_HOST:-}" ]; then
  echo "setup-upwarden[go]: UPWARDEN_REGISTRY_HOST is empty." >&2
  exit 1
fi
if [ -z "${UPWARDEN_REGISTRY_URL:-}" ]; then
  echo "setup-upwarden[go]: UPWARDEN_REGISTRY_URL is empty." >&2
  exit 1
fi
if [ -z "${GITHUB_ENV:-}" ]; then
  echo "setup-upwarden[go]: GITHUB_ENV is not set — must run inside GitHub Actions." >&2
  exit 1
fi

# --- Go 1.24+ gate ------------------------------------------------------------
# The GOAUTH command protocol we rely on is a Go 1.24 feature. If the go
# binary is present we hard-fail on anything older (the .netrc fallback is out
# of scope). If go is not on PATH yet (e.g. setup-go runs after us), we can't
# check — the env we write will simply apply once go runs.
if command -v go >/dev/null 2>&1; then
  # "go version go1.24.3 linux/amd64" -> 1.24.3
  go_ver="$(go version | awk '{print $3}' | sed 's/^go//')"
  go_major="${go_ver%%.*}"
  go_rest="${go_ver#*.}"
  go_minor="${go_rest%%.*}"
  if [ "${go_major:-0}" -lt 1 ] || { [ "${go_major:-0}" -eq 1 ] && [ "${go_minor:-0}" -lt 24 ]; }; then
    echo "setup-upwarden[go]: found Go ${go_ver}, but Tier A requires Go 1.24+ (GOAUTH command form). Older Go needs ~/.netrc, which is out of scope." >&2
    exit 1
  fi
fi

# --- Install the non-secret GOAUTH helper -------------------------------------
# GOAUTH's "command" form: go runs this program and reads a credential set from
# its stdout. Per `go help goauth` (Go 1.24), the output grammar is:
#
#   Response      = { CredentialSet } .
#   CredentialSet = URLLine { URLLine } BlankLine { HeaderLine } BlankLine .
#   URLLine       = /* URL that starts with "https://" */ '\n' .
#   HeaderLine    = /* HTTP Request header */ '\n' .
#   BlankLine     = '\n' .
#
# So: one https:// prefix line, a blank line, the Authorization header, a
# trailing blank line. go invokes the command with no args before the first
# fetch and (on a 4xx) again with the URL as an arg + the HTTP response on
# stdin; we ignore both and unconditionally emit the bearer for our host.
#
# The helper is NOT a secret: it contains only the host (public) and a *read*
# of $UPWARDEN_CREDENTIAL from the environment at runtime. The token value is
# never materialised on disk (Rule 2).
helper_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
helper_path="${helper_dir}/upwarden-goauth.sh"
mkdir -p "$helper_dir"

# FOOTGUN: GOAUTH is a semicolon-separated list whose commands are split on
# whitespace with NO quoting support (strings.Fields in cmd/go). A helper path
# containing a space would be parsed as two args and break auth. Guard for it.
case "$helper_path" in
  *[[:space:]]*)
    echo "setup-upwarden[go]: helper path '${helper_path}' contains whitespace; GOAUTH cannot reference it (no quoting in GOAUTH parsing). Set RUNNER_TEMP/TMPDIR to a space-free path." >&2
    exit 1
    ;;
esac

# Write the helper. Single-quoted heredoc so NOTHING here is expanded at write
# time; the host is injected as a literal on a separate, controlled line.
{
  printf '%s\n' '#!/usr/bin/env sh'
  printf '%s\n' '# setup-upwarden GOAUTH helper (non-secret). Reads the bearer token from'
  printf '%s\n' '# the environment at runtime and prints a Go 1.24 GOAUTH credential set.'
  printf '%s\n' 'set -eu'
  # Host baked in as a literal (public value); %s is the only substitution.
  printf 'UPWARDEN_REGISTRY_HOST=%s\n' "$UPWARDEN_REGISTRY_HOST"
  printf '%s\n' ': "${UPWARDEN_CREDENTIAL:?setup-upwarden GOAUTH helper: UPWARDEN_CREDENTIAL not in environment}"'
  # URL-prefix line, blank line, Authorization header, trailing blank line.
  # No trailing slash on the prefix: Go 1.24's GOAUTH prefix matcher is broken
  # for trailing-slash prefixes (golang/go#71889) — 'https://host/' fails to
  # match 'https://host/<module>/@v/...' so no Authorization header attaches and
  # every fetch 401s. The no-slash form matches on all Go versions.
  printf '%s\n' 'printf '\''https://%s\n\nAuthorization: Bearer %s\n\n'\'' "$UPWARDEN_REGISTRY_HOST" "$UPWARDEN_CREDENTIAL"'
} > "$helper_path"
chmod 0755 "$helper_path"

# --- Merge our vars into $GITHUB_ENV (Rule 4: idempotent) ---------------------
# Strip any prior upwarden-managed simple assignments for these keys, keep the
# rest of the user's env file intact, then append our fresh values.
tmp_env="$(mktemp)"
if [ -f "$GITHUB_ENV" ]; then
  grep -Ev '^(GOPROXY|GONOSUMDB|GOAUTH)=' "$GITHUB_ENV" > "$tmp_env" || true
fi
{
  # Proxy first, then fall through to direct VCS for anything the proxy 404s.
  printf 'GOPROXY=%s,direct\n' "$UPWARDEN_REGISTRY_URL"
  # A proxy re-serving public modules won't match the public sum DB, so exempt
  # our host from checksum-DB verification (per spec; GONOSUMDB).
  # TODO(devops): GONOSUMDB matches MODULE-PATH prefixes, not hosts. Confirm with engine whether the proxy serves modules under its own namespace (then host is correct) or re-serves foreign paths (then per-module globs / GOSUMDB handling needed). Tracked as an RFC open item.
  printf 'GONOSUMDB=%s\n' "$UPWARDEN_REGISTRY_HOST"
  # Invoke the helper via /bin/sh so we don't depend on the exec bit / a
  # non-noexec temp mount. No token appears here — only the helper path.
  printf 'GOAUTH=/bin/sh %s\n' "$helper_path"
} >> "$tmp_env"
mv "$tmp_env" "$GITHUB_ENV"

# NOTE on Rule 3 (transform → ::add-mask::): we deliberately do NOT embed the
# token in GOPROXY's URL (which would require percent-encoding + re-masking the
# transformed value). The token is passed only as a verbatim Bearer header by
# the helper, so no new secret form is created and no extra mask is needed.

# --- Rule 5: exactly one non-secret human log line ----------------------------
echo "setup-upwarden[go]: wired GOPROXY -> ${UPWARDEN_REGISTRY_URL} (,direct) with GOAUTH Bearer for ${UPWARDEN_REGISTRY_HOST}; GONOSUMDB exempts it from the checksum DB. [Go 1.24+; pending-liveness]"
