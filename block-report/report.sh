#!/usr/bin/env bash
# ==============================================================================
# block-report/report.sh — run-end blocked-dependency digest for setup-upwarden.
#
# When the Upwarden firewall correctly blocks a dependency (a true-positive CVE
# or policy catch), the rich detail rides in the proxy's 403 JSON body — which
# package-manager clients DISCARD. maven hides even the 403 reason-phrase at
# default verbosity, so a maven dev sees only "could not be resolved", which
# reads as a flaky registry. This script queries the run-end report the engine
# exposes and prints a compact, human digest of exactly what THIS run had
# blocked (advisory id + severity + why + remediation), plus a Markdown summary
# on the job-summary page.
#
# CONTRACT (engine-owned): GET /api/v1/admin/orgs/{slug}/runs/{run_id}/blocked
#   response_version: upwarden.ci-run-blocked/v1
#   gate: oidc:r (a tenant RBAC cap — members_basic+, NOT super-admin). The run's
#   own vke_ is a PROXY credential and does NOT authenticate the admin API, so
#   this step needs a separate org admin API token (the `token` input).
#
# INVARIANT: this NEVER fails the build (unless fail-on-block=true AND blocks
# were found). The firewall already enforced the block inline; this is
# after-the-fact surfacing, a convenience — never a gate. Any config gap,
# non-200, or transient error degrades to a single informational line.
# ==============================================================================
set -uo pipefail

ORG="${UPWARDEN_REPORT_ORG:-}"
RUN_ID="${UPWARDEN_REPORT_RUN_ID:-}"
API_BASE="${UPWARDEN_REPORT_API_BASE:-}"
TOKEN="${UPWARDEN_REPORT_TOKEN:-}"
FAIL_ON_BLOCK="${UPWARDEN_REPORT_FAIL_ON_BLOCK:-false}"
JOB_SUMMARY="${UPWARDEN_REPORT_JOB_SUMMARY:-true}"
# TEST-ONLY: read this local JSON file instead of calling the API. Harmless
# (only changes WHERE the report JSON comes from; never touches auth/secrets).
FIXTURE="${UPWARDEN_REPORT_FIXTURE:-}"

info() { printf '[upwarden block-report] %s\n' "$1"; }

# Degrade quietly: the report is a convenience, never a gate. Exit 0 so a
# missing token / 404 / transient error never turns a green build red.
degrade() {
  info "$1 — skipping the run-end block report."
  info "(This never fails your build; the firewall already enforced any block inline.)"
  exit 0
}

# Mask the admin token defensively (secrets.* via with: are masked, but a literal
# input is not — never let it surface under set -x or in a URL echo).
[ -n "${TOKEN}" ] && echo "::add-mask::${TOKEN}"

command -v jq >/dev/null 2>&1 || degrade "jq is not available on this runner"

resp="$(mktemp)"; trap 'rm -f "${resp}"' EXIT

if [ -n "${FIXTURE}" ]; then
  cp "${FIXTURE}" "${resp}" || degrade "could not read fixture ${FIXTURE}"
  status=200
else
  [ -n "${ORG}" ]      || degrade "no org slug (set the 'org' input to your Upwarden tenant slug)"
  [ -n "${RUN_ID}" ]   || degrade "no run id"
  [ -n "${API_BASE}" ] || degrade "no api-base"
  [ -n "${TOKEN}" ]    || degrade "no report token (needs an org admin API token with the oidc:r capability)"

  API_BASE="${API_BASE%/}"
  url="${API_BASE}/api/v1/admin/orgs/${ORG}/runs/${RUN_ID}/blocked"
  info "querying the run-end block report (run ${RUN_ID})"
  status="$(curl -sS -o "${resp}" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
    "${url}" 2>/dev/null || echo 000)"
fi

# 404 = the run resolved zero pulls for this tenant (org-fenced, no existence
# oracle) OR truly doesn't exist; 000/5xx = transient. All degrade quietly.
[ "${status}" = "200" ] || degrade "report endpoint returned HTTP ${status}"

jq -e . < "${resp}" >/dev/null 2>&1 || degrade "the report response was not valid JSON"

count="$(jq -r '.run.blocked_count // (.blocked | length) // 0' < "${resp}" 2>/dev/null || echo 0)"
if [ -z "${count}" ] || [ "${count}" = "null" ] || [ "${count}" = "0" ]; then
  info "no dependencies were blocked in this run."
  exit 0
fi

# --- plain-text digest to the job log -----------------------------------------
manifest_url=""
[ -z "${FIXTURE}" ] && manifest_url="${API_BASE}/api/v1/admin/orgs/${ORG}/runs/${RUN_ID}/manifest"

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
' < "${resp}" 2>/dev/null || info "(could not render the detailed digest; see the manifest)"
[ -n "${manifest_url}" ] && echo "  Full manifest: ${manifest_url}"
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
