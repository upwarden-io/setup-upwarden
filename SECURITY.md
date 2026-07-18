# Security Policy

`setup-upwarden` is a **credential-handling GitHub Action**. It receives your
Upwarden tenant key (`vk_`), mints GitHub OIDC tokens, and exchanges them for
short-lived registry credentials (`vke_`). We hold it to the security bar that
implies. This document tells you how to report a problem, which versions we
support, the threat model we design against, and how to consume the action
safely.

---

## Reporting a vulnerability

**Please report privately — do not open a public issue, PR, or discussion for a
suspected vulnerability.** Public disclosure before a fix puts every consumer of
this action at risk.

Two private channels, either is fine:

1. **GitHub Private Vulnerability Reporting (preferred).**
   Go to the **[Security tab](https://github.com/upwarden-io/setup-upwarden/security)**
   → **Report a vulnerability**. This opens a private advisory thread scoped to
   this repository, visible only to you and the maintainers.
2. **Email:** **security@upwarden.io**. If you want to encrypt, ask in a first
   (content-free) mail and we will share a key.

### What to include

- The affected version(s) / tag / commit SHA, the `tool:` (e.g. `npm` / `pip` /
  `maven`), and the mode (`keyless` / `static`) involved.
- A concrete description of the impact — **especially anything that could expose,
  log, or exfiltrate a `vk_`, a `vke_`, or a GitHub OIDC token**, or cause the
  action to authenticate against a host other than the intended registry.
- A minimal reproduction (a workflow snippet, the runner OS, and the observed vs.
  expected behavior). Redact any real secrets from logs before sending.
- Any suggested remediation, if you have one.

### What to expect from us

- **Acknowledgement within 2 business days** (Europe/Berlin) that we received the
  report.
- An initial assessment and severity triage within **5 business days**.
- Regular status updates on the advisory thread until resolution.
- **Coordinated disclosure.** We fix privately, publish a patched release and a
  **GitHub Security Advisory** (with a CVE where warranted), and credit you in the
  advisory unless you ask to remain anonymous. We aim to disclose within **90
  days**, sooner for actively exploited issues, and will agree a timeline with you.

### Out of scope / not a vulnerability here

Report these to the owning surface, not this repo:

- Issues in the **Upwarden platform / exchange endpoint** (`/api/v1/ci/exchange`),
  the registry proxies (`*.pkg.upwarden.io`), or `vk_`/`vke_` issuance policy →
  **security@upwarden.io** directly (they are not this action's code).
- Issues in **GitHub Actions**, the OIDC provider, or the runner → GitHub.
- A leaked `vk_` **because you inlined it in a workflow instead of using a
  secret** — rotate the key in the Upwarden console; that is a usage error the
  action cannot prevent (see "Consumer responsibilities" below). We still want to
  hear about it if the action itself caused the leak.

---

## Supported versions

We support the **latest minor release of each active major** with security fixes.
Consumers pinned to the moving major tag (`@v2`) receive fixes automatically on
their next run; consumers pinned to a SHA or an immutable `vX.Y.Z` must bump.

| Version           | Supported          | Notes                                                        |
| ----------------- | ------------------ | ------------------------------------------------------------ |
| `v2` (latest `2.x`) | :white_check_mark: | **Current stable major.** Security fixes land here.          |
| `1.x`             | :warning:          | Superseded by `v2` (renamed `ecosystem`→`tool`, `@v1`→`@v2`). Receives **security** fixes only, for a documented deprecation window; upgrade to `v2` for features. |
| `< v1` / pre-release | :x:             | Unsupported. Do not use in production.                       |

When a future `v3` ships (a breaking change — e.g. renamed inputs, changed
default host, or `keyless` semantics), the prior major continues to receive
**security** fixes for a documented deprecation window announced in the release
notes; new features go to the current major only.

---

## Threat model

### What the action handles (assets)

| Asset | Sensitivity | Where it lives |
| --- | --- | --- |
| Tenant key `vk_` | **Secret.** Standing (long-lived until revoked); the direct credential in `static`. | Supplied via `with: tenant-vk:` from a GitHub secret; in memory during the step; referenced from the registry credential file **only in `static`** (as an `${env}` reference, not the literal). |
| GitHub OIDC JWT (`aud=upwarden.io`) | **Secret**, short-lived (minutes). Proves repo identity. | Minted in-step from `ACTIONS_ID_TOKEN_REQUEST_*`; sent once as `x-upwarden-ci-oidc`; never persisted. |
| Ephemeral credential `vke_` | **Secret**, short-lived (~6h). The registry credential in `keyless`. | Returned by the exchange; exported to the job environment as `UPWARDEN_CREDENTIAL`; referenced (not embedded) by the tool config; masked in logs. |
| Unit name | **Non-secret metadata.** Self-declared package label (`x-upwarden-ci-unit`). | Read from the manifest; safe to log. |

### Trust boundaries & the security model

- **WHO is always signed.** The security boundary is either the GitHub-signed
  OIDC JWT (`repository_id` / `repository_owner_id`, verified server-side against
  an `oidc_trust_binding`) or possession of the `vk_`. The action never asserts
  identity on its own — it only carries signed material to the exchange.
- **WHICH unit is untrusted metadata.** The unit name is self-declared and used
  for attribution only. It is **not** a security control: minting a token already
  requires repo control, so the worst case is a self-mislabel *inside an
  already-owned repo* — never a cross-tenant crossing.
- **Egress is pinned.** In `keyless` the action talks only to the resolved
  `registry-host` (default `*.pkg.upwarden.io`) at `/api/v1/ci/exchange`, over
  HTTPS. The OIDC `audience` is pinned to `upwarden.io` and rejected server-side
  otherwise (`bad_audience`). In `static` there is no exchange call at all.

### Defenses this action implements

- **Aggressive secret masking.** Every secret — the `vk_`, the minted OIDC JWT,
  the `vke_`, and the percent-encoded pip index URL that embeds the credential —
  is `::add-mask::`ed before any subsequent log line can surface it, including a
  defensive mask of a literally-supplied `tenant-vk` (which GitHub does *not*
  auto-mask, unlike `secrets.*`).
- **No long-lived secret persisted to disk.** The credential lives only in a
  short-lived, masked, job-scoped environment variable (`UPWARDEN_CREDENTIAL`).
  The on-disk config files the writers produce (`.npmrc`, `settings.xml`,
  `init.gradle`, …) carry only an `${env}` **reference** — resolved by the tool
  at install/build time — never a literal token. (For pip, the credential rides
  in the `PIP_INDEX_URL` job-env value, still never a file on disk.)
- **Fail-closed exchange.** A non-200 exchange aborts the step with a specific,
  non-secret-leaking error; the action never falls back to an unauthenticated or
  wrong-host registry.
- **Raw credential is never an action output.** The credential is passed to the
  per-tool writer only through the job environment; only non-secret metadata
  (`credential-id`, `expires-at`, …) is exposed as an output.
- **Least privilege by construction.** `static` needs **no** `permissions:` at
  all (no OIDC). `keyless` needs only `id-token: write` (+ your job's own
  `contents: read`) — the action requests nothing broader.
- **Composite = auditable.** This is a composite action: the `action.yml` shell
  and its per-tool writer scripts **are** the artifact. There is no
  bundled/minified JavaScript hiding behavior — the entire trust surface is
  readable in the repository.

### Residual risks the consumer owns

The action cannot defend against these — you must:

- **Never inline a `vk_`.** Always pass it from a GitHub **secret**. A secret
  printed by *your other steps*, or exposed to untrusted PR code, is outside this
  action's control.
- **Guard `pull_request_target` / forked-PR workflows.** Do not expose
  `tenant-vk` or `id-token: write` to workflows that run untrusted PR code.
- **Pin the action** (see below) so a compromised upstream tag cannot alter what
  runs in your pipeline.

---

## Consumer responsibilities — how to use this action safely

### 1. Pin the action

Pick a pinning strategy deliberately — this is the single highest-leverage
control you have:

- **Strongest — pin to a full commit SHA** (immutable, supply-chain-strict):

  ```yaml
  - uses: upwarden-io/setup-upwarden@<40-char-sha>   # e.g. from a v2.0.0 release
  ```

- **Strong — pin to an immutable released version.** Each release is an
  **immutable release**: the `vX.Y.Z` tag **cannot be moved or overwritten** once
  published, so `@v2.0.0` is as stable as a SHA while staying readable:

  ```yaml
  - uses: upwarden-io/setup-upwarden@v2.0.0
  ```

- **Convenient — pin to the moving major** (`@v2`). You get security fixes
  automatically, at the cost of trusting that the `v2` tag is retargeted only to
  vetted releases. Fine for most consumers; combine with Dependabot to graduate
  to SHA pins over time.

We recommend **SHA or immutable `vX.Y.Z`** for anything that publishes packages
or touches production credentials.

### 2. Verify what you run

Each release is an **immutable release**: its `vX.Y.Z` tag and release are frozen
and **cannot be re-pointed or overwritten** once published. The release commit
each tag points at is created through GitHub and **signed server-side by GitHub's
web-flow key** — it carries the green **Verified** badge on github.com — and the
publisher organization's identity is **domain-verified** to `upwarden.io`.
Combined with **pinning by full commit SHA or the immutable `vX.Y.Z` tag**
(above), that gives a reproducible, tamper-evident reference today: every
consumer resolves to the same bytes, and any tampering with a published version
is detectable.

### 3. Grant least privilege

```yaml
permissions:
  contents: read
  id-token: write     # ONLY for keyless. Omit entirely for static.
```

Set permissions at the **job** level, not the workflow level, and grant
`id-token: write` only to the jobs that actually authenticate.

### 4. Rotate on suspicion

If you believe a `vk_` was exposed, rotate it in the Upwarden console
immediately. `vke_` credentials are short-lived and expire on their own, but
rotate the standing `vk_` if it may be compromised.

---

## Security-relevant configuration for this repository

To make the above guarantees real, the repository is configured with:

- **Private vulnerability reporting** enabled (the Security-tab reporting flow).
  *(Org/repo setting — enabled in repo settings.)*
- **Immutable releases** (repo setting): non-movable, non-overwritable version
  tags today. *(Requires a GitHub Release per version.)*
- **GitHub-Verified release commits.** Releases are cut on commits created
  through GitHub, which signs them server-side with its web-flow key (green
  **Verified** badge). *(No maintainer-held signing key is involved.)*
- **Branch protection** on the default branch: required review (see
  `CODEOWNERS`), required status checks, and no force-pushes.
- **Verified organization domain** (`upwarden.io`), so the publisher identity is
  domain-attested. *(Org setting — requires a DNS TXT record.)*

If any of these appears **not** to be in effect on a release you are consuming,
treat it as a finding and report it via the channels above.
