# `setup-upwarden`

**Authenticate a GitHub Actions job to an [Upwarden](https://upwarden.io)
package registry (npm / pip / maven) in two lines.**

This is the Upwarden equivalent of
[`google-github-actions/auth`](https://github.com/google-github-actions/auth):
it replaces a hand-rolled *"mint a GitHub OIDC token → `curl` the exchange →
write `.npmrc`"* dance with a single `uses:` step. After it runs, `npm ci` /
`pip install` / `mvn` just work — every request flows through the Upwarden proxy,
authenticated and attributed.

```yaml
- uses: upwarden-io/setup-upwarden@v1
  with:
    ecosystem: npm
    tenant-vk: ${{ secrets.UPWARDEN_TENANT_VK }}
- run: npm ci   # flows through npm.pkg.upwarden.io, authenticated
```

It is a **composite action** — the `action.yml` (plus the embedded, auditable
`bash`) *is* the artifact. There is no compiled/bundled JavaScript to trust.

---

## Table of contents

- [Quick start](#quick-start) — 2-line snippet per auth mode and per ecosystem
- [Auth modes](#auth-modes) — `static` / `keyed` / `keyless`
- [Inputs](#inputs) · [Outputs](#outputs)
- [What it writes, per ecosystem](#what-it-writes-per-ecosystem)
- [Security](#security) — pinning, provenance, least-privilege
- [Versioning](#versioning) — `@v1` moving vs pinned `@vX.Y.Z` vs `@<sha>`
- [How this maps to GCP](#how-this-maps-to-gcp-google-github-actionsauth)
- [SECURITY.md](./SECURITY.md) · [PUBLISHING.md](./PUBLISHING.md)

---

## Quick start

Every call needs `ecosystem:`. The `mode:` is **auto-detected** if you omit it
(see [Auth modes](#auth-modes)). Below is the minimal 2-line customer snippet for
each mode, and the one-line-different variant for each ecosystem.

### By auth mode

| mode | snippet | needs `id-token: write`? |
|---|---|---|
| `static` | `ecosystem:` + `mode: static` + `tenant-vk:` | no |
| `keyed` | `ecosystem:` + `mode: keyed` + `tenant-vk:` | **yes** |
| `keyless` *(coming)* | `ecosystem:` + `mode: keyless` (no `tenant-vk`) | **yes** |

```yaml
# static — a long-lived vk_ used directly (works on ANY CI, even off GitHub)
- uses: upwarden-io/setup-upwarden@v1
  with:
    ecosystem: pip
    mode: static
    tenant-vk: ${{ secrets.UPWARDEN_TENANT_VK }}
```

```yaml
# keyed — OIDC JWT exchanged WITH a vk_ selector → short-lived vke_ (recommended)
permissions:
  contents: read
  id-token: write            # REQUIRED — lets the job mint the OIDC token
steps:
  - uses: upwarden-io/setup-upwarden@v1
    with:
      ecosystem: npm
      mode: keyed
      tenant-vk: ${{ secrets.UPWARDEN_TENANT_VK }}
```

```yaml
# keyless — OIDC JWT exchanged with NO vk_ (tenant from verified org ownership)
permissions:
  contents: read
  id-token: write
steps:
  - uses: upwarden-io/setup-upwarden@v1
    with:
      ecosystem: maven
      mode: keyless          # no tenant-vk — COMING (see Auth modes)
```

### By ecosystem

Only `ecosystem:` changes; the auth block is identical.

```yaml
- uses: upwarden-io/setup-upwarden@v1        #   npm
  with: { ecosystem: npm,   tenant-vk: '${{ secrets.UPWARDEN_TENANT_VK }}' }
- run: npm ci

- uses: upwarden-io/setup-upwarden@v1        #   pip / uv
  with: { ecosystem: pip,   tenant-vk: '${{ secrets.UPWARDEN_TENANT_VK }}' }
- run: pip install -r requirements.txt

- uses: upwarden-io/setup-upwarden@v1        #   maven
  with: { ecosystem: maven, tenant-vk: '${{ secrets.UPWARDEN_TENANT_VK }}' }
- run: mvn -B verify
```

> Store `tenant-vk` as a **repository or organization secret** (`secrets.*`).
> Never inline a `vk_` literal — a literal is not masked by the runner.

---

## Auth modes

Three modes, using the exact labels the Upwarden platform defines. Omit `mode:`
to auto-detect: **`keyless`** when no `tenant-vk` is supplied → **`keyed`** when a
`tenant-vk` is supplied *and* the job has `id-token: write` → **`static`**
otherwise.

### `static` (Mode A) — the vk_ *is* the credential

A long-lived `vk_` is used **directly** as the registry credential (HTTP Basic /
Bearer). No OIDC, no exchange, no network round-trip to mint. The lowest-friction
on-ramp; the only mode that works **off** GitHub Actions (any CI, a laptop).

### `keyed` (Mode B) — OIDC JWT **+** vk_ selector → short-lived `vke_`

A GitHub OIDC token (`aud=upwarden.io`) is exchanged at
`POST /api/v1/ci/exchange` **with** the `vk_` sent as `Authorization: Bearer`
(the *tenant selector*) and the JWT in `x-upwarden-ci-oidc`. Engine verifies the
JWT against an `oidc_trust_binding` and returns a **short-lived (~6h) `vke_`**
used as the registry credential. This is what Upwarden dogfoods in its own CI and
the recommended mode for GitHub-hosted builds.

> **Terminology trap.** Upwarden's marketing phrase *"keyless OIDC"* refers to
> the **ephemeral `vke_`** you get out of Mode B — it **still sends a `vk_`** as
> the tenant selector. Mode B is *not* "no key".

### `keyless` (Mode C) — OIDC JWT with **no** vk_ — **(coming)**

The same exchange with **no `vk_` at all**; the tenant is derived purely from the
GitHub-signed `repository_owner_id` via `verified_org_ownership`. No repo secret
to store or rotate — true keyless federation, the direct analogue of GCP Workload
Identity Federation.

> ⚠️ **Mode C is being built.** It depends on an engine capability
> (`verified_org_ownership`) whose flag is **currently OFF**; a no-`vk_` exchange
> is rejected until it ships. The action implements the full path today and marks
> the engine-dependent points **(engine channel in build)**. Use `keyed` with a
> `tenant-vk` until Mode C is live.

---

## Inputs

| input | required | default | description |
|---|---|---|---|
| `ecosystem` | **yes** | — | `npm` \| `pip` \| `maven`. Selects the credential file written and the default host. |
| `mode` | no | *auto* | `static` \| `keyed` \| `keyless`. **Auto-detect:** `keyless` if no `tenant-vk`; else `keyed` if the job has `id-token: write`; else `static`. |
| `tenant-vk` | conditional | `""` | The tenant `vk_` **secret**. Required for `static` + `keyed`; omit for `keyless`. In `static` it *is* the credential; in `keyed` it is the `Authorization: Bearer` tenant selector. |
| `registry-host` | no | *per-ecosystem* | Registry/proxy host. Defaults: npm→`npm.pkg.upwarden.io`, pip→`pypi.pkg.upwarden.io`, maven→`maven.pkg.upwarden.io`. The exchange lives on the **same host** at `/api/v1/ci/exchange`. |
| `unit` | no | *auto* | The per-package unit **NAME** (self-declared metadata; sent as `x-upwarden-ci-unit`). Omit to auto-discover from the manifest. |
| `working-directory` | no | `.` | Directory whose manifest is read to auto-discover `unit` (`package.json` `.name` / `pyproject.toml` `[project].name` / `pom.xml` `<artifactId>`). |
| `audience` | no | `upwarden.io` | OIDC audience. **Must** be `upwarden.io` — the verifier pins it (`bad_audience` otherwise). Used only in `keyed`/`keyless`. |

## Outputs

| output | description |
|---|---|
| `credential-id` | Public id of the credential, safe to log. For `keyed`/`keyless`: the minted `vke_` `credential_id`. For `static`: a stable, non-reversible fingerprint of the `vk_`. Empty if auth did not complete. |
| `registry-configured` | `'true'` once the ecosystem's credential file/env is written and the job can install/publish through the proxy; `'false'` otherwise. |
| `mode` | The auth mode actually used (`static` \| `keyed` \| `keyless`). Handy when you rely on auto-detect. |
| `registry-host` | The host that was configured (resolved default if you didn't pass one). |
| `expires-at` | ISO-8601 UTC expiry of the credential (`keyed`/`keyless` `vke_` only; empty for `static`, which is long-lived). |

---

## What it writes, per ecosystem

The action resolves a **credential** (the `vk_` directly, or the exchanged
`vke_`), then writes it in the shape each package manager expects. Secrets are
never written to disk in plaintext where avoidable — tokens are passed via
`$GITHUB_ENV` and referenced by variable.

| ecosystem | file written | how the credential is presented |
|---|---|---|
| `npm` | `~/.npmrc` | `registry=https://<host>/` + `//<host>/:_authToken=${…}` (Bearer) + `always-auth=true`. The token is injected via env, so it never lands on disk. |
| `pip` | `~/.config/pip/pip.conf` **and** `PIP_INDEX_URL` / `UV_INDEX_UPWARDEN_*` env | HTTP Basic — the credential rides in the **password** slot of the index URL (`https://token:<cred>@<host>/simple/`). Works for both `pip` and `uv`. |
| `maven` | `~/.m2/settings.xml` | `<mirror mirrorOf="*">` forces every fetch through `https://<host>/maven2`; the matching `<server>` supplies the credential as an `Authorization: Bearer` httpHeader. |

In `keyed`/`keyless` the action first mints the GitHub OIDC token, POSTs it to
`/api/v1/ci/exchange`, receives the run-scoped `vke_`, masks it, and *then*
writes it as above. Every secret (`vk_`, the JWT, the `vke_`) is `::add-mask::`ed
before it can appear in any log line.

---

## Security

`setup-upwarden` handles registry credentials, so treat it as a trust boundary.

**Pin the action.** In order of increasing strictness:

- **`@v1`** — moving major tag. Gets patches automatically. Fine for most, but a
  moving tag is mutable — trust follows whoever can move it.
- **`@v1.2.3`** — an immutable published version. Upwarden publishes each release
  as an **immutable action package** (OCI on GHCR) with **Sigstore provenance**,
  so a pinned `vX.Y.Z` cannot be silently re-pointed once published.
- **`@<full-40-char-commit-sha>`** — supply-chain-strict pin. Immutable by
  construction and independent of any tag. **Recommended for security-sensitive
  pipelines.**

```yaml
# strict pin (recommended for regulated / high-value pipelines):
- uses: upwarden-io/setup-upwarden@0000000000000000000000000000000000000000
```

**Verify provenance.** Released versions carry a Sigstore attestation. Consumers
can verify with the GitHub CLI:

```bash
gh attestation verify --owner upwarden-io <artifact-or-image-ref>
```

**Least privilege.** Grant only what the mode needs:

```yaml
permissions:
  contents: read       # checkout
  id-token: write      # ONLY for keyed / keyless — omit entirely for static
```

**Secret hygiene.** Store the `vk_` as a `secrets.*` value (never a literal);
the action defensively `::add-mask::`s it anyway. The `keyed`/`keyless` `vke_` is
short-lived (~6h) and run-scoped, which is why keyed is preferred over static.

Full trust model, reporting a vulnerability, and the audited shell surface:
**[SECURITY.md](./SECURITY.md)**.

---

## Versioning

Upwarden follows the same convention as `actions/*` and
`google-github-actions/*`:

| you write | you get | when to use |
|---|---|---|
| `@v1` | the newest `v1.x.y`, auto-updated (moving tag) | default; you want non-breaking fixes automatically |
| `@v1.2.3` | that exact release (immutable package + Sigstore provenance) | you want reproducible builds with a friendly version |
| `@<sha>` | that exact commit, forever | supply-chain-strict; trust nothing mutable |

- Releases are cut as `v1.0.0`, `v1.1.0`, … Each is an **immutable, signed**
  version; the moving **`v1`** tag is retargeted to the newest compatible one.
- Because this is a composite action, there is **no build step** — the
  `action.yml` is the whole artifact, so a version is exactly the reviewable
  source at that tag.
- **Breaking changes** (renamed inputs, changed default host, `keyless`
  semantics) bump the **major** and move consumers to `@v2`; `@v1` stays alive
  for existing users.

The full release + signing + provenance process (immutable-action publish,
signed git tags, immutable releases, branch protection) is documented in
**[PUBLISHING.md](./PUBLISHING.md)**.

---

## How this maps to GCP (`google-github-actions/auth`)

The mental model transfers 1:1 from Google's auth action:

| concept | GCP `google-github-actions/auth` | Upwarden `setup-upwarden` |
|---|---|---|
| identity federation | Workload Identity Federation: GitHub OIDC → GCP, **no key** | `keyless` — GitHub OIDC → tenant via `verified_org_ownership`, **no `vk_`** *(coming)* |
| keyed / selector | WIF **+ SA impersonation** (`service_account:`) | `keyed` — OIDC **+ `vk_` tenant selector** → `vke_` |
| static long-lived key | `credentials_json:` (a downloaded SA key — discouraged) | `static` — a long-lived `vk_` used directly (the "any-CI" on-ramp) |
| audience pin | `audience:` (default the WIF provider) | `audience:` — pinned to `upwarden.io` |
| what you get out | short-lived **access token** | short-lived **`vke_`** written as the registry credential; `credential-id` output |
| the OIDC mint | `id-token: write` on the job | `id-token: write` on the job (same requirement) |
| downstream step | later `gcloud` / `setup-gcloud` steps just work | later `npm` / `pip` / `mvn` steps just work |

The through-line: **prefer keyless federation, fall back to a keyed selector,
keep a static long-lived key only as the lowest-friction escape hatch** — the
same posture Google's action nudges you toward, applied to Upwarden's package
registry instead of GCP APIs.

---

## License & support

- License: see [LICENSE](./LICENSE).
- Security policy / disclosure: [SECURITY.md](./SECURITY.md).
- Issues & feature requests: this repository's issue tracker.
- Docs: <https://upwarden.io>
