#!/usr/bin/env bash
#
# setup-upwarden v2 credential writer — TOOL: maven (Tier C)
#
# Maven has a first-class credential store: ~/.m2/settings.xml. We wire two
# coupled elements into it:
#
#   * a <mirror> (id=upwarden, mirrorOf=central, url=<UPWARDEN_REGISTRY_URL>)
#     so every `central` lookup is redirected at the upwarden registry, and
#   * a <server> (id=upwarden) carrying an Authorization: Bearer header.
#
# Maven matches a <server> to a repository/mirror by ID, so the server id MUST
# equal the mirror id — hence both are the literal string "upwarden".
#
# Tier C, Rule 2: we NEVER write the raw credential into settings.xml. Instead
# the header value is the LITERAL string  Bearer ${env.UPWARDEN_CREDENTIAL}  —
# Maven interpolates ${env.X} against the process environment at resolve time,
# so the on-disk file only ever holds an environment REFERENCE, not the token.
# The real token lives only in the job env (exported+masked by CORE).
#
# Inputs (all via env, exported by CORE before this writer runs):
#   UPWARDEN_CREDENTIAL          registry credential (masked; NOT written to disk)
#   UPWARDEN_REGISTRY_HOST       e.g. maven.pkg.upwarden.io   (informational)
#   UPWARDEN_REGISTRY_URL        full resolved URL -> the mirror url
#   UPWARDEN_TOOL                "maven"
#   UPWARDEN_UNIT                optional; unused by this tool
#   UPWARDEN_WORKING_DIRECTORY   optional; unused (settings.xml is per-user, in $HOME)
#
set -euo pipefail

# The env-var name whose *reference* (not value) we bake into the header. Kept
# as a variable so the literal "${env.…}" placeholder can be embedded verbatim
# without shell expansion (single quotes below), while staying in one place.
CRED_ENV_NAME="UPWARDEN_CREDENTIAL"
MANAGED_ID="upwarden"   # shared id for BOTH the mirror and the server (must match)

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------
# Rule 1: fail loud if CORE handed us no credential. We do not embed the value,
# but an empty credential means the job is misconfigured — refuse rather than
# wire a header that resolves to nothing at build time.
if [ -z "${UPWARDEN_CREDENTIAL:-}" ]; then
  echo "setup-upwarden(maven): UPWARDEN_CREDENTIAL is empty; refusing to wire Maven auth (did CORE run?)." >&2
  exit 1
fi

if [ -z "${UPWARDEN_REGISTRY_URL:-}" ]; then
  echo "setup-upwarden(maven): UPWARDEN_REGISTRY_URL is empty; cannot point the mirror anywhere." >&2
  exit 1
fi

# Real XML surgery (merge without clobbering) needs a real parser. Regex/sed on
# XML is the classic footgun (duplicate <mirrors> containers, dropped nodes),
# so we require python3 — present on every GitHub-hosted runner — and fail
# clearly if it is absent rather than shipping a fragile text mangle.
if ! command -v python3 >/dev/null 2>&1; then
  echo "setup-upwarden(maven): python3 not found; needed to safely merge settings.xml." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Locate (and ensure the dir for) the per-user settings.xml
# ---------------------------------------------------------------------------
M2_DIR="${HOME}/.m2"
SETTINGS_PATH="${M2_DIR}/settings.xml"
mkdir -p "$M2_DIR"

# ---------------------------------------------------------------------------
# 3. Merge — done in python for correct, namespace-aware XML handling.
# ---------------------------------------------------------------------------
# Rule 3 (transform-mask) is N/A here: we write NO credential-derived value to
# disk, so there is nothing new to ::add-mask::. The header holds only the
# literal placeholder below.
#
# We pass the placeholder value in via env (AUTH_HEADER_VALUE) so the shell
# never expands it and the python string stays clean. Single quotes keep
# ${env.…} literal.
export UPWARDEN_SETTINGS_PATH="$SETTINGS_PATH"
export UPWARDEN_MANAGED_ID="$MANAGED_ID"
export UPWARDEN_MIRROR_URL="$UPWARDEN_REGISTRY_URL"
export UPWARDEN_AUTH_HEADER_VALUE='Bearer ${env.'"$CRED_ENV_NAME"'}'

python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

SETTINGS = "http://maven.apache.org/SETTINGS/1.0.0"

path       = os.environ["UPWARDEN_SETTINGS_PATH"]
managed_id = os.environ["UPWARDEN_MANAGED_ID"]
mirror_url = os.environ["UPWARDEN_MIRROR_URL"]
auth_value = os.environ["UPWARDEN_AUTH_HEADER_VALUE"]  # literal "Bearer ${env.UPWARDEN_CREDENTIAL}"

# --- Parse an existing file, or start a fresh <settings> tree ----------------
# Preserve user comments on merge (insert_comments, py3.8+) so we don't silently
# eat annotations in a hand-maintained settings.xml.
def new_root():
    return ET.Element("{%s}settings" % SETTINGS)

ns = SETTINGS  # default namespace we emit under
root = None
if os.path.isfile(path) and os.path.getsize(path) > 0:
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        tree = ET.parse(path, parser=parser)
        root = tree.getroot()
        # Honor whatever namespace the existing root actually uses (could be the
        # canonical SETTINGS ns, a versioned one, or none) so our lookups and
        # appends land in the right place instead of creating a parallel tree.
        if root.tag.startswith("{"):
            ns = root.tag[1:].split("}", 1)[0]
        else:
            ns = ""  # unnamespaced document — match it
    except ET.ParseError as e:
        print("setup-upwarden(maven): existing settings.xml is not valid XML: %s" % e,
              file=sys.stderr)
        sys.exit(1)
else:
    root = new_root()

def q(tag):
    """Namespace-qualified tag matching the document's namespace."""
    return "{%s}%s" % (ns, tag) if ns else tag

def get_or_make(parent, tag):
    el = parent.find(q(tag))
    if el is None:
        el = ET.SubElement(parent, q(tag))
    return el

def id_text(el):
    idel = el.find(q("id"))
    return idel.text.strip() if idel is not None and idel.text else None

# --- Idempotency: drop any prior upwarden-managed mirror/server by id --------
# This makes re-runs clean and lets us keep every OTHER mirror/server the user
# defined. We only ever remove entries whose <id> equals our managed id.
def strip_managed(container_tag, child_tag):
    container = root.find(q(container_tag))
    if container is None:
        return
    for child in list(container.findall(q(child_tag))):
        if id_text(child) == managed_id:
            container.remove(child)

strip_managed("mirrors", "mirror")
strip_managed("servers", "server")

# --- Add fresh <mirror> ------------------------------------------------------
mirrors = get_or_make(root, "mirrors")
mirror = ET.SubElement(mirrors, q("mirror"))
ET.SubElement(mirror, q("id")).text = managed_id
ET.SubElement(mirror, q("name")).text = "upwarden registry (setup-upwarden)"
ET.SubElement(mirror, q("url")).text = mirror_url
ET.SubElement(mirror, q("mirrorOf")).text = "central"

# --- Add fresh <server> whose header carries the env REFERENCE ---------------
servers = get_or_make(root, "servers")
server = ET.SubElement(servers, q("server"))
ET.SubElement(server, q("id")).text = managed_id
configuration = ET.SubElement(server, q("configuration"))
http_headers = ET.SubElement(configuration, q("httpHeaders"))
prop = ET.SubElement(http_headers, q("property"))
ET.SubElement(prop, q("name")).text = "Authorization"
# The ONLY place the credential is referenced: a literal ${env.…} placeholder
# that Maven resolves at runtime. No token bytes are ever written to disk.
ET.SubElement(prop, q("value")).text = auth_value

# --- Serialize ---------------------------------------------------------------
# Register the default namespace with an empty prefix so the output stays
# ns-clean (<settings> …) instead of sprouting ns0: prefixes.
if ns:
    ET.register_namespace("", ns)

out = ET.ElementTree(root)
try:
    ET.indent(out)  # py3.9+; pretty-print is cosmetic, ignore if unavailable
except AttributeError:
    pass

out.write(path, encoding="utf-8", xml_declaration=True)
PY

# ---------------------------------------------------------------------------
# 4. One non-secret human log line
# ---------------------------------------------------------------------------
echo "setup-upwarden(maven): wired ${SETTINGS_PATH} — mirror+server id=${MANAGED_ID} (mirrorOf=central -> ${UPWARDEN_REGISTRY_URL}); Authorization resolves from \${env.${CRED_ENV_NAME}} at build time (no token on disk)."
