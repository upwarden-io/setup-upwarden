<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/upwarden-hero-dark.png">
    <img src=".github/upwarden-hero-light.png" alt="Upwarden" width="480">
  </picture>
</p>

<h1 align="center">setup-upwarden</h1>

<p align="center">
  <strong>Keyless OIDC auth for CI — every dependency fetch authenticated, attributed, and policy-enforced, in two lines.</strong>
</p>

<p align="center">
  <a href="https://github.com/marketplace/actions/setup-upwarden"><img src="https://img.shields.io/github/v/release/upwarden-io/setup-upwarden?label=marketplace&color=3DDC97" alt="Marketplace version" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/upwarden-io/setup-upwarden?color=3DDC97" alt="License" /></a>
</p>

---

**Keyless OIDC — no stored registry credentials.** Package managers aren't
OIDC-aware, so Upwarden mints a short-lived, per-run token from your CI OIDC
identity automatically. Drop in one `uses:` step and `npm ci` / `pip install` /
`mvn` just work — every request flows through the Upwarden proxy, authenticated
and attributed to the workflow that made it.

It is a **composite action** — the `action.yml` (plus the embedded, auditable
`bash`) *is* the artifact. There is no compiled or bundled JavaScript to trust:
the entire behavior is readable in one file.

---

## The gap it closes

In most CI pipelines, dependency fetches are **unauthenticated and
unattributed** — `npm ci` and `pip install` pull from public registries with no
identity on the request and no record of which workflow pulled what. That is an
unguarded door in your software supply chain: nothing proves a fetch came from
*your* build, and nothing lets you enforce policy on what your builds are
allowed to pull. `setup-upwarden` closes that door — it routes every fetch
through the Upwarden proxy under your CI's own OIDC identity, so each request is
**authenticated, attributed, and policy-enforced**.

---

## Quick start

Keyless is the default. Grant the job the two least-privilege permissions an
OIDC exchange needs, add one step, and install as usual:

```yaml
permissions:
  contents: read       # checkout
  id-token: write      # lets the job mint its GitHub OIDC token

steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v1
    with:
      ecosystem: npm     # npm | pip | maven
  - run: npm ci          # flows through npm.pkg.upwarden.io, authenticated
```

No `vk_` secret to store or rotate — the tenant is derived from your CI's signed
OIDC identity, and the action mints a short-lived, run-scoped token for the
fetch. Grant `id-token: write` at the **job** level, only on the jobs that
authenticate.

> **Off GitHub, or no OIDC?** Use **Static** mode with an Upwarden key used
> directly as the registry credential — see [Auth modes](#auth-modes). Store the
> key as a `secrets.*` value; never inline it.

---

## Pinning & verification

`setup-upwarden` handles registry credentials — treat it as a trust boundary and
pin it deliberately.

**Pin to a full commit SHA** for supply-chain-strict pipelines (immutable by
construction, independent of any tag):

```yaml
- uses: upwarden-io/setup-upwarden@0000000000000000000000000000000000000000  # v1.0.0
```

Or pin an **immutable released version** (`@v1.0.0`) — each release is frozen:
its `vX.Y.Z` tag and release cannot be moved or overwritten once published, so it
cannot be silently re-pointed. The moving **`@v1`** major tag auto-picks
non-breaking fixes and is fine for most consumers.

### Verify this release

Each release is an **immutable release** — its `vX.Y.Z` tag and release are frozen
and cannot be moved or overwritten once published. Combined with SHA-pinning, that
gives you a **reproducible, tamper-evident reference today**.

**Coming:** OCI-published **Sigstore build-provenance** attestations, verifiable
with `gh attestation verify`. This is **not yet available** — pin by full commit
SHA or by immutable tag until it ships.

---

## Auth modes

Two modes. Omit `mode:` to auto-detect: **Keyless** when no key is supplied and
the job can mint an OIDC token → **Static** otherwise.

### Keyless (recommended, primary)

**OIDC-only — no stored secret.** Your CI's GitHub OIDC identity is exchanged for
a **short-lived, per-run credential**, and the tenant is resolved from your signed
repo identity. There is nothing to store or rotate. Requires `id-token: write` on
the job (to mint the OIDC token) plus `contents: read` (your checkout).

Under the hood, keyless installs consume an **ephemeral per-run token (`vke`)**
that npm / pip / maven read as the registry credential — because those package
managers aren't OIDC-aware. That token is an internal detail of the data plane,
not a mode you configure.

### Static

A **long-lived tenant key (`vk`)** used **directly** as the registry credential —
for CI that can't present a GitHub OIDC identity (non-GitHub runners, a laptop).
Store the `vk` as a `secrets.*` value; the action defensively `::add-mask::`es it
regardless.

```yaml
# Static — a vk used directly (works on ANY CI, even off GitHub)
- uses: upwarden-io/setup-upwarden@v1
  with:
    ecosystem: pip
    mode: static
    tenant-vk: ${{ secrets.UPWARDEN_TENANT_VK }}
```

> **There is no separate "keyed" mode.** A `vk` passed alongside OIDC is a
> **single-use provisioning artifact**, not a standing credential — keyless OIDC
> is the credential model going forward.

---

## Inputs

| input | required | default | description |
|---|---|---|---|
| `ecosystem` | **yes** | — | `npm` \| `pip` \| `maven`. Selects the credential file written and the default host. |
| `mode` | no | *auto* | `keyless` \| `static`. **Auto-detect:** `keyless` when no key is supplied and the job can mint an OIDC token; else `static`. |
| `tenant-vk` | conditional | `""` | The Upwarden tenant key **secret**. Required for `static` (where it *is* the credential); omit for `keyless`. Store as `secrets.*`; never inline it. |
| `registry-host` | no | *per-ecosystem* | Registry/proxy host. Defaults: npm→`npm.pkg.upwarden.io`, pip→`pypi.pkg.upwarden.io`, maven→`maven.pkg.upwarden.io`. The exchange lives on the **same host** at `/api/v1/ci/exchange`. |
| `unit` | no | *auto* | The per-package unit **NAME** (self-declared metadata; sent as `x-upwarden-ci-unit`). Omit to auto-discover from the manifest. |
| `working-directory` | no | `.` | Directory whose manifest is read to auto-discover `unit` (`package.json` `.name` / `pyproject.toml` `[project].name` / `pom.xml` `<artifactId>`). |
| `audience` | no | `upwarden.io` | OIDC audience. **Must** be `upwarden.io` — the verifier pins it (`bad_audience` otherwise). Used only in `keyless`. |

## Outputs

| output | description |
|---|---|
| `credential-id` | Public id of the credential, safe to log. For `keyless`: the minted run-scoped credential's `credential_id`. For `static`: a stable, non-reversible fingerprint of the key. Empty if auth did not complete. |
| `registry-configured` | `'true'` once the ecosystem's credential file/env is written and the job can install/publish through the proxy; `'false'` otherwise. |
| `mode` | The auth mode actually used (`keyless` \| `static`). Handy when you rely on auto-detect. |
| `registry-host` | The host that was configured (resolved default if you didn't pass one). |
| `expires-at` | ISO-8601 UTC expiry of the credential (`keyless` run-scoped token only; empty for `static`, which is long-lived). |

---

## Per-ecosystem examples

Only `ecosystem:` changes — the auth block is identical (keyless shown; add
`mode: static` + `tenant-vk:` for non-OIDC CI).

<details>
<summary><strong>npm</strong> — writes <code>~/.npmrc</code></summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v1
    with: { ecosystem: npm }
  - run: npm ci   # → npm.pkg.upwarden.io, authenticated
```

Writes `registry=https://npm.pkg.upwarden.io/` + `//<host>/:_authToken=${…}`
(Bearer) + `always-auth=true`. The token is injected via env, so it never lands
on disk.
</details>

<details>
<summary><strong>pip / uv</strong> — writes <code>~/.config/pip/pip.conf</code> + <code>UV_INDEX_*</code></summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v1
    with: { ecosystem: pip }
  - run: pip install -r requirements.txt   # → pypi.pkg.upwarden.io
```

HTTP Basic — the credential rides in the **password** slot of the index URL
(`https://token:<cred>@<host>/simple/`). Works for both `pip` and `uv`.
</details>

<details>
<summary><strong>maven</strong> — writes <code>~/.m2/settings.xml</code></summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v1
    with: { ecosystem: maven }
  - run: mvn -B verify   # → maven.pkg.upwarden.io
```

A `<mirror mirrorOf="*">` forces every fetch through
`https://maven.pkg.upwarden.io/maven2`; the matching `<server>` supplies the
credential as an `Authorization: Bearer` httpHeader.
</details>

---

## How it works

1. The action mints your job's **GitHub OIDC token** (keyless) — or takes your
   key directly (static).
2. It exchanges the OIDC token at `https://<registry-host>/api/v1/ci/exchange`,
   receiving a **short-lived, run-scoped** registry credential.
3. It writes that credential in the exact shape each package manager expects
   (`.npmrc` / `pip.conf` / `settings.xml`), so downstream `npm` / `pip` / `mvn`
   steps "just work" through the Upwarden proxy.

Every secret — the key, the minted OIDC token, the run-scoped credential — is
`::add-mask::`ed before any subsequent log line can surface it. Because this is
a **composite action, there is no bundled JavaScript** — the whole trust surface
is the readable shell in `action.yml`. Full docs at
**[upwarden.io](https://upwarden.io)**.

---

## Trust & security

- **Immutable releases.** Each `vX.Y.Z` is published as an immutable action
  package — frozen once published, so a pinned version can't be silently
  re-pointed. See [Verify this release](#verify-this-release). (Sigstore
  build-provenance attestations are coming — not yet available.)
- **Least privilege by construction.** Keyless needs only `id-token: write` +
  `contents: read`; `static` needs no OIDC permissions at all.
- **Auditable — no bundled JS.** The composite `action.yml` *is* the artifact.
- **Supported versions & disclosure policy:** **[SECURITY.md](./SECURITY.md)**.
  Report vulnerabilities privately via the Security tab or
  `security@upwarden.io` — never a public issue.
- **Release, signing & provenance process:** **[PUBLISHING.md](./PUBLISHING.md)**.

---

## Get started with Upwarden

- **Site & product:** **[upwarden.io](https://upwarden.io)**
- **Create a tenant / sign in to the console:**
  **[upwarden.io](https://upwarden.io)** → sign up
- **Docs & quickstart:** **[upwarden.io](https://upwarden.io)**

**Next step:** add the [Quick start](#quick-start) step to one workflow, run it,
and watch the authenticated, attributed fetches show up in your Upwarden
dashboard.

---

## License

See **[LICENSE](./LICENSE)**.
