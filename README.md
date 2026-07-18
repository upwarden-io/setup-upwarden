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
OIDC-aware, so Upwarden mints a short-lived, per-run credential from your CI's
GitHub OIDC identity automatically. Drop in one `uses:` step and `npm ci` /
`pip install` / `mvn` just work — every request flows through the Upwarden
proxy, authenticated and attributed to the workflow that made it.

It is a **composite action** — the `action.yml` (plus the embedded, auditable
`bash` writers) *is* the artifact. There is no compiled or bundled JavaScript to
trust: the entire behavior is readable in the repository.

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
  - uses: upwarden-io/setup-upwarden@v2
    with:
      tool: npm          # see the full list of supported tools below
  - run: npm ci          # flows through npm.pkg.upwarden.io, authenticated
```

No `vk_` secret to store or rotate — the tenant is derived from your CI's signed
GitHub OIDC identity, and the action mints a short-lived, run-scoped credential
for the fetch. Grant `id-token: write` at the **job** level, only on the jobs
that authenticate.

> **Off GitHub, or no OIDC?** Use **static** mode with a standing Upwarden key
> (`vk_`) used directly as the registry credential — see
> [Auth modes](#auth-modes). Store the key as a `secrets.*` value; never inline
> it.

---

## Supported tools

Name the concrete package **manager** with `tool:`; the action derives the wire
protocol, the default registry host, and the base URL from it.

**Native and supported today (9):**

| `tool:` value | Manager | Credential file / mechanism |
|---|---|---|
| `npm` | npm | `.npmrc` |
| `pnpm` | pnpm | `.npmrc` |
| `yarn` | Yarn (berry) | `.npmrc` |
| `yarn-classic` | Yarn 1.x | `.npmrc` |
| `pip` | pip | `PIP_INDEX_URL` (job env) |
| `uv` | uv | index env vars |
| `poetry` | Poetry | Poetry config |
| `maven` | Maven | `~/.m2/settings.xml` (HTTP Basic) |
| `gradle` | Gradle | `~/.gradle/init.gradle` (HTTP Basic) |

**Experimental / pending (4)** — authored, but **not yet verified against a live
production endpoint**. Wire them up and report back, but don't depend on them for
a production pipeline yet:

| `tool:` value | Manager |
|---|---|
| `cargo` | Cargo (crates) |
| `go` | Go modules |
| `nuget` | NuGet |
| `bundler` | Bundler (RubyGems) |

`tool: none` is an exchange-only escape hatch: it acquires a credential and
exports it to the job environment, writing no per-tool config file.

---

## Pinning & verification

`setup-upwarden` handles registry credentials — treat it as a trust boundary and
pin it deliberately.

**Pin to a full commit SHA** for supply-chain-strict pipelines (immutable by
construction, independent of any tag):

```yaml
- uses: upwarden-io/setup-upwarden@0000000000000000000000000000000000000000  # v2.0.0
```

Or pin an **immutable released version** (`@v2.0.0`) — each release is frozen:
its `vX.Y.Z` tag and release cannot be moved or overwritten once published, so it
cannot be silently re-pointed. The moving **`@v2`** major tag auto-picks
non-breaking fixes and is fine for most consumers.

### How releases are verified and frozen

What is true and verifiable **today**:

- **GitHub-Verified release commit.** Each `vX.Y.Z` tag points at a commit
  created through GitHub (a PR merge / release cut on the platform), which GitHub
  signs server-side with its **web-flow** key. That commit carries GitHub's green
  **Verified** badge — you can confirm it in the commit's header on github.com.
- **Immutable releases.** Once published, a `vX.Y.Z` tag and its release are
  **frozen** — they cannot be moved or overwritten. A pinned version cannot be
  silently re-pointed underneath you.
- **Domain-verified publisher.** The publishing organization's identity is
  domain-attested to `upwarden.io`.

Combined with **pinning by full commit SHA or the immutable `vX.Y.Z` tag** (the
strongest control you have), that gives you a **reproducible, tamper-evident
reference today** — every consumer resolves to exactly the same bytes, and any
tampering with a published version is detectable.

---

## Auth modes

Two customer-facing modes. **keyless** is the default.

### Keyless (recommended, default)

**OIDC-only — no stored secret.** Your CI's GitHub OIDC identity is exchanged for
a **short-lived, per-run credential**, and the tenant is resolved from your
signed repo identity via a one-time org-ownership binding. There is nothing to
store or rotate. Requires `id-token: write` on the job (to mint the OIDC token)
plus `contents: read` (your checkout).

```yaml
# Keyless — the default; no `mode:` needed.
- uses: upwarden-io/setup-upwarden@v2
  with:
    tool: npm
```

### Static

A **standing tenant key (`vk_`)** — long-lived until you revoke it — used
**directly** as the registry credential, for CI that can't present a GitHub OIDC
identity (non-GitHub runners, a laptop). Store the `vk_` as a `secrets.*` value;
the action defensively `::add-mask::`es it regardless. No OIDC, no exchange call.

```yaml
# Static — a standing vk_ used directly (works on ANY CI, even off GitHub)
- uses: upwarden-io/setup-upwarden@v2
  with:
    tool: pip
    mode: static
    tenant-vk: ${{ secrets.UPWARDEN_TENANT_VK }}
```

> **Advanced / internal.** `mode:` also accepts `keyed`, an internal bootstrap
> mechanic (an OIDC exchange carrying a `vk_` as the tenant selector). It is not
> a mode consumers pick — use `keyless` or `static`.

---

## Inputs

| input | required | default | description |
|---|---|---|---|
| `tool` | **yes** | — | One of `npm` \| `pnpm` \| `yarn` \| `yarn-classic` \| `pip` \| `uv` \| `poetry` \| `maven` \| `gradle` \| `cargo` \| `go` \| `nuget` \| `bundler` \| `none`. Selects the package manager to configure; the action derives the protocol, default host, and URL. `none` is exchange-only (no file written). |
| `mode` | no | `keyless` | `keyless` (default) \| `static`. (`keyed` is an internal bootstrap mechanic, not a mode to select.) |
| `tenant-vk` | conditional | `""` | The Upwarden tenant key **secret** (`vk_`). Required for `static` (where it *is* the credential); omit for `keyless`. Store as `secrets.*`; never inline it. |
| `registry-host` | no | *per-tool* | Registry/proxy host override. Defaults: npm-family→`npm.pkg.upwarden.io`, pip-family→`pypi.pkg.upwarden.io`, maven/gradle→`maven.pkg.upwarden.io` (see `action.yml` for cargo/go/nuget/bundler). The exchange lives on the **same host** at `/api/v1/ci/exchange`. |
| `unit` | no | *auto* | The per-package unit **NAME** (self-declared metadata; sent as `x-upwarden-ci-unit`). Omit to auto-discover from the manifest. |
| `working-directory` | no | `.` | Directory whose manifest is read to auto-discover `unit` (`package.json` `.name` / `pyproject.toml` name / `pom.xml` `<artifactId>` / `Cargo.toml` name / `go.mod` module) and that the writer targets. |
| `audience` | no | `upwarden.io` | OIDC audience. **Must** be `upwarden.io` — the verifier pins it (`bad_audience` otherwise). Used only in `keyless`. |

## Outputs

| output | description |
|---|---|
| `credential-id` | Public id of the credential, safe to log. For `keyless`: the minted run-scoped credential's `credential_id`. For `static`: a stable, non-reversible fingerprint of the key. Empty if auth did not complete. |
| `registry-host` | The host that was configured (resolved default if you didn't pass one). |
| `registry-url` | The fully-resolved registry base URL the tool was pointed at. |
| `expires-at` | ISO-8601 UTC expiry of the credential (`keyless` run-scoped credential only; empty for `static`, which is standing). |
| `mode` | The auth mode actually used (`keyless` \| `static`). |
| `unit` | The resolved unit name (supplied or auto-discovered; may be empty). |

---

## Per-tool examples

Only `tool:` changes — the auth block is identical (keyless shown; add
`mode: static` + `tenant-vk:` for non-OIDC CI).

<details>
<summary><strong>npm</strong> — writes <code>.npmrc</code></summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: npm }
  - run: npm ci   # → npm.pkg.upwarden.io, authenticated
```

Writes `registry=https://npm.pkg.upwarden.io/` + `//<host>/:_authToken=${…}`
(Bearer token) + `always-auth=true`. The `_authToken` line carries the literal
`${UPWARDEN_CREDENTIAL}` reference, which npm resolves from the environment at
install time — the token never lands on disk.
</details>

<details>
<summary><strong>yarn</strong> — writes <code>.npmrc</code></summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: yarn }   # or yarn-classic for Yarn 1.x
  - run: yarn install   # → npm.pkg.upwarden.io, authenticated
```

`yarn`, `yarn-classic`, and `pnpm` share the npm protocol and `.npmrc` shape
(Bearer `_authToken`, resolved from the environment at install time).
</details>

<details>
<summary><strong>pip / uv</strong> — sets <code>PIP_INDEX_URL</code> (and uv index env)</summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: pip }   # or tool: uv
  - run: pip install -r requirements.txt   # → pypi.pkg.upwarden.io
```

HTTP Basic — the credential rides in the **password** slot of the index URL
(`https://__token__:<cred>@<host>/simple/`), exported into the job environment
(`PIP_INDEX_URL`), never written to a file on disk. Use `tool: uv` for uv.
</details>

<details>
<summary><strong>maven</strong> — writes <code>~/.m2/settings.xml</code> (HTTP Basic)</summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: maven }
  - run: mvn -B verify   # → maven.pkg.upwarden.io
```

A `<mirror mirrorOf="central">` forces every fetch through
`https://maven.pkg.upwarden.io/maven2`; the matching `<server>` supplies the
credential as **HTTP Basic** — username `token`, and the password is the literal
`${env.UPWARDEN_CREDENTIAL}` placeholder that Maven resolves from the environment
at build time (no token bytes on disk). The proxy challenges Maven clients with
`WWW-Authenticate: Basic`, so Basic — not a pre-set Bearer header — is the
idiomatic form.
</details>

<details>
<summary><strong>gradle</strong> — writes <code>~/.gradle/init.gradle</code> (HTTP Basic)</summary>

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: gradle }
  - run: ./gradlew build   # → maven.pkg.upwarden.io
```

Writes a global `init.gradle` that points `allprojects` at the Upwarden maven
repo and authenticates with **HTTP Basic** via `PasswordCredentials` (username
`token`, password read at runtime from `System.getenv("UPWARDEN_CREDENTIAL")`).
The init script never embeds the token.
</details>

---

## Run-end block report (`block-report`)

When Upwarden **correctly blocks** a dependency (a CVE or policy catch), the rich
detail rides in the proxy's 403 body — which package-manager clients discard.
For npm/pnpm/yarn the block reason still reaches you inline (the 403
reason-phrase + the `x-upwarden-block` header). **Maven hides even that** at
default verbosity — you see only *"could not be resolved"*, which reads like a
flaky registry. So an out-of-band, run-end digest is the channel that reaches a
maven developer.

`block-report` is a **separate, opt-in step** you add at the **end** of a job. It
queries the run's blocked set and prints a compact digest — advisory id +
severity + why + remediation — to the log and the job-summary page.

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: actions/checkout@v4
  - uses: upwarden-io/setup-upwarden@v2
    with: { tool: maven }
  - run: mvn -B verify

  # Run-end digest of anything Upwarden blocked in this run.
  - uses: upwarden-io/setup-upwarden/block-report@v2
    if: always()          # run even when a block failed the build above
    with:
      org: your-org-slug
      token: ${{ secrets.UPWARDEN_ADMIN_TOKEN }}
```

**When to add it**

- **maven / gradle — recommended.** These clients suppress the inline reason, so
  this is the only channel that explains a blocked build.
- **every other ecosystem — optional.** The inline 403 reason-phrase +
  `x-upwarden-block` header already surface the reason at the point of failure.
  Add it only if you want a consolidated run-end summary.

Adding the step (or not), per job, **is** the toggle — there is no ecosystem-wide
switch to reason about.

**Why a separate step** — the block set only exists *after* your install runs, so
the report must execute at job end. `setup-upwarden` is a composite action, and
composite actions cannot register a `post:` step (only JavaScript actions can,
and v2 ships **no** bundled `node_modules` on purpose). A thin, opt-in step keeps
that guarantee intact.

**Auth** — the report is an admin API read (gated by the `oidc:r` tenant
capability). The run's own registry credential is a *proxy* credential and does
**not** authenticate the admin API, so this step needs a separate **org admin API
token** (role `members_basic`+) stored as a secret. It never fails your build: a
missing token, a 404, or any transient error degrades to a single informational
line (opt into a hard fail with `fail-on-block: true`).

| Input | Default | Notes |
| --- | --- | --- |
| `org` | — (required) | Your Upwarden org/tenant slug. Non-secret. |
| `token` | — (required) | Org admin API token with `oidc:r`. Store as a secret. |
| `api-base` | `https://app.upwarden.io` | Override only on a non-default deployment. |
| `run-id` | `${{ github.run_id }}` | The `ci_run_id`; the exchange stamps the GitHub run id. |
| `fail-on-block` | `false` | `true` → step exits non-zero if the run had blocks. |
| `job-summary` | `true` | Also write a Markdown table to the job-summary page. |

---

## How it works

1. **Resolve.** The action derives the wire protocol, default registry host, and
   base URL from `tool:`, and resolves the self-declared unit name. No secrets,
   no network.
2. **Authenticate.** In `keyless` it mints your job's **GitHub OIDC token** and
   exchanges it at `https://<registry-host>/api/v1/ci/exchange`, receiving a
   **short-lived, run-scoped** registry credential. In `static` your `vk_` *is*
   the credential (no OIDC, no exchange). The exchange is **fail-closed** — any
   non-200 aborts the step; it never falls back to an unauthenticated or
   wrong-host registry.
3. **Write.** A per-tool writer materialises the credential in the exact shape
   each package manager expects (`.npmrc` / `PIP_INDEX_URL` / `settings.xml` /
   `init.gradle` / …), so downstream `npm` / `pip` / `mvn` / `gradle` steps "just
   work" through the Upwarden proxy.

Every secret — the `vk_`, the minted OIDC token, the run-scoped credential — is
`::add-mask::`ed before any subsequent log line can surface it. **No long-lived
secret is persisted to disk:** the credential lives only in a short-lived,
masked, job-scoped environment variable (`UPWARDEN_CREDENTIAL`); the on-disk
config files (`.npmrc`, `settings.xml`, `init.gradle`, …) carry only an `${env}`
reference, never a literal token. Because this is a **composite action, there is
no bundled JavaScript** — the whole trust surface is readable shell. Full docs at
**[upwarden.io](https://upwarden.io)**.

---

## Trust & security

- **Immutable releases.** Each `vX.Y.Z` is published as a frozen release —
  non-movable, non-overwritable once published — so a pinned version can't be
  silently re-pointed. See [How releases are verified and frozen](#how-releases-are-verified-and-frozen).
- **GitHub-Verified release commits** (signed server-side by GitHub's web-flow
  key; green **Verified** badge) from a **domain-verified** publisher org
  (`upwarden.io`), consumed via **SHA / immutable-`vX.Y.Z` pinning**.
- **Least privilege by construction.** Keyless needs only `id-token: write` +
  `contents: read`; `static` needs no OIDC permissions at all.
- **Auditable — no bundled JS.** The composite `action.yml` and its shell writers
  *are* the artifact.
- **Supported versions & disclosure policy:** **[SECURITY.md](./SECURITY.md)**.
  Report vulnerabilities privately via the Security tab or
  `security@upwarden.io` — never a public issue.
- **Release process:** **[PUBLISHING.md](./PUBLISHING.md)**.

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
