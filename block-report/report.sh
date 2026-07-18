#!/usr/bin/env bash
# ==============================================================================
# block-report/report.sh — run-end blocked-dependency digest for setup-upwarden.
#
# When the Upwarden firewall correctly blocks a dependency (a true-positive CVE
# or policy catch), the rich detail rides in the proxy's 403 JSON body — which
# package-manager clients DISCARD. maven hides even the 403 reason-phrase at
# default verbosity, so a maven dev sees only "could not be resolved", which
# reads as a flaky registry. This script queries the run's OWN blocked report and
# prints a compact, human digest of exactly what THIS run had blocked (advisory
# id + severity + why + remediation), plus a Markdown summary on the
# job-summary page.
#
# CONTRACT (engine-owned): GET /api/v1/ci/run/blocked
#   response_version: upwarden.ci-run-blocked/v1
#   auth: the run's OWN credential (UPWARDEN_CREDENTIAL, the vke_ that
#   setup-upwarden exported to the job env). The route is SELF-SCOPED — the
#   credential identifies the tenant + ci_run_id and the read is confined to
#   THIS run only. No admin token, no org slug, no run id. A missing/expired
#   credential returns 401 {reason:vke_credential_required}.
#
# INVARIANT: this NEVER fails the build (unless fail-on-block=true AND blocks
# were found). The firewall already enforced the block inline; this is
# after-the-fact surfacing, a convenience — never a gate. No credential, a
# non-200, or any transient error degrades to a single informational line.
# ==============================================================================
set -uo pipefail

CRED="${UPWARDEN_CREDENTIAL:-}"
API_BASE="${UPWARDEN_REPORT_API_BASE:-}"
FAIL_ON_BLOCK="${UPWARDEN_REPORT_FAIL_ON_BLOCK:-false}"
JOB_SUMMARY="${UPWARDEN_REPORT_JOB_SUMMARY:-true}"
# TEST-ONLY: read this local JSON file instead of calling the API. Harmless
# (only changes WHERE the report JSON comes from; never touches auth/secrets).
FIXTURE="${UPWARDEN_REPORT_FIXTURE:-}"

info() { printf '[upwarden block-report] %s\n' "$1"; }

# Degrade quietly: the report is a convenience, never a gate. Exit 0 so a
# missing credential / 401 / transient error never turns a green build red.
degrade() {
  info "$1 — skipping the run-end block report."
  info "(This never fails your build; the firewall already enforced any block inline.)"
  exit 0
}

# The credential comes from GITHUB_ENV (already masked by setup-upwarden), but
# mask again defensively so it can never surface under set -x here.
[ -n "${CRED}" ] && echo "::add-mask::${CRED}"

command -v jq >/dev/null 2>&1 || degrade "jq is not available on this runner"

resp="$(mktemp)"; trap 'rm -f "${resp}"' EXIT

if [ -n "${FIXTURE}" ]; then
  cp "${FIXTURE}" "${resp}" || degrade "could not read fixture ${FIXTURE}"
  status=200
else
  [ -n "${CRED}" ]     || degrade "no run credential in the environment (run setup-upwarden before block-report)"
  [ -n "${API_BASE}" ] || degrade "no api-base"

  API_BASE="${API_BASE%/}"
  url="${API_BASE}/api/v1/ci/run/blocked"
  info "querying this run's blocked report via the self-scoped CI route"
  status="$(curl -sS -o "${resp}" -w '%{http_code}' \
    -H "Authorization: Bearer ${CRED}" \
    -H "Accept: application/json" \
    "${url}" 2>/dev/null || echo 000)"
fi

# 401 = credential missing/expired; 404 = no run data; 000/5xx = transient.
# All degrade quietly (never fail the build over a convenience report).
[ "${status}" = "200" ] || degrade "report endpoint returned HTTP ${status}"

jq -e . < "${resp}" >/dev/null 2>&1 || degrade "the report response was not valid JSON"

count="$(jq -r '.run.blocked_count // (.blocked | length) // 0' < "${resp}" 2>/dev/null || echo 0)"
if [ -z "${count}" ] || [ "${count}" = "null" ] || [ "${count}" = "0" ]; then
  info "no dependencies were blocked in this run."
  exit 0
fi

# --- plain-text digest to the job log -----------------------------------------
run_repo="$(jq -r '.run.repository // ""' < "${resp}" 2>/dev/null || echo "")"
run_rid="$(jq -r '.run.run_id // "" | tostring' < "${resp}" 2>/dev/null || echo "")"
run_ref="${run_repo}"
[ -n "${run_rid}" ] && run_ref="${run_ref}$([ -n "${run_ref}" ] && printf ' ')(run ${run_rid})"

echo ""
echo "=================================================================="
echo "  Upwarden blocked ${count} dependency(ies) in this run"
echo "=================================================================="
jq -r '
  .blocked[]
  | "  • \(.package)@\(.version)  (\(.severity), \(.decision)) — \(.reasons | length) reason(s):",
    ( .reasons[]
      | "      - \(.advisory.id // .dimension // "policy") (\(.severity))  \(.why)"
        + ( if (.advisory.url // "") != "" then "\n        " + .advisory.url else "" end )
    ),
    ""
' < "${resp}" 2>/dev/null || info "(could not render the detailed digest)"
[ -n "${run_ref}" ] && echo "  ${run_ref}"
echo ""

# --- Markdown digest to the job-summary page ----------------------------------
if [ "${JOB_SUMMARY}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Upwarden — ${count} blocked dependency(ies) in this run"
    echo ""
    echo "| Package | Version | Severity | Decision | Reasons |"
    echo "|---|---|---|---|---|"
    jq -r '
      .blocked[]
      | "| `\(.package)` | \(.version) | \(.severity) | \(.decision) | "
        + ( [ .reasons[] | "\(.advisory.id // .dimension) (\(.severity))" ] | join("; ") )
        + " |"
    ' < "${resp}" 2>/dev/null
    echo ""
    echo "<details><summary>Advisories &amp; remediation</summary>"
    echo ""
    jq -r '
      .blocked[]
      | "- **\(.package)@\(.version)** (\(.severity), \(.decision))",
        ( .reasons[]
          | "  - \(.advisory.id // .dimension) (\(.severity)) — \(.why)"
            + ( if (.advisory.url // "") != "" then " ([advisory](\(.advisory.url)))" else "" end )
            + ( if (.remediation // "") != "" then "<br>    _\(.remediation)_" else "" end )
        )
    ' < "${resp}" 2>/dev/null
    echo ""
    echo "</details>"
  } >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null && info "wrote a digest to the job-summary page."
fi

# --- opt-in hard fail (default off; the install already failed on the block) ---
if [ "${FAIL_ON_BLOCK}" = "true" ]; then
  echo "::error::[upwarden] ${count} dependency(ies) were blocked in this run (fail-on-block=true)."
  exit 1
fi
exit 0
