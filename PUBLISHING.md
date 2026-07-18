# Publishing & hardening `upwarden-io/setup-upwarden`

Maintainer runbook for releasing this action publicly, securely, and reproducibly.
`setup-upwarden` is a **composite** action: `action.yml` + embedded bash is the
entire artifact — there is no build/bundle step, so the trust surface is the shell
you can read in `action.yml`. Security-review it on every release.

Every GitHub-feature claim below is grounded against current GitHub docs (URLs
inline). **Steps that a human / DNS / UI must perform — i.e. that cannot be driven
by `gh`/`git` alone — are collected in [§5](#5-human--dns--ui-checklist).**

---

## 0. Release invariants (read once)

- Consumers pin `@v2` (moving major) or a specific `@v2.0.0` / `@<sha>` (immutable).
- **Immutable releases** (repo setting, GA Oct 2025) freeze a *release* and its
  attached tag so `v2.0.0` can never be re-pointed or overwritten. The moving
  **`v2`** tag is a *plain git tag with no release attached*, so it stays movable.
  That is the whole trick — see
  <https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases>.
- Never force-move a tag that is attached to a release. Only ever force-move the
  moving major tag (`v2`).
- Cut releases from `main` at a green commit that passed CI (`.github/workflows`
  lint + a real end-to-end exchange smoke).
- **The strongest supply-chain control a consumer has is pinning** — by full
  commit SHA, or by an immutable `vX.Y.Z` tag. Everything below exists to make
  those pins trustworthy: a signed, frozen tag from a domain-verified publisher.

---

## 1. Versioning — cut `vX.Y.Z`, retarget the major tag

### 1.1 The consumer contract

| Consumer pins | Gets | Who it's for |
|---|---|---|
| `@v2` | latest `v2.*.*` (moving tag, retargeted each release) | most users — auto-picks non-breaking fixes |
| `@v2.0.0` | that exact immutable release forever | reproducible / release-pinned builds |
| `@<full-sha>` | that exact tree, tamper-proof by construction | supply-chain-strict consumers |

Breaking change (renamed input, changed default host, `keyless` semantics that
alter behavior) → bump **major**, publish `@v3`, keep `@v2` alive and frozen for
existing users. This is the `google-github-actions/auth@v2` convention.

### 1.2 Cut an immutable patch/minor release

```bash
# from a green main
git switch main && git pull --ff-only

# 1. bump the version and update any version references (README examples, badges,
#    action metadata) in the same commit that CI goes green on.

# 2. annotated, SIGNED tag (see §2 for how signing is set up)
git tag -s v2.0.1 -m "setup-upwarden v2.0.1"
git push origin v2.0.1

# 3. create the GitHub Release on that tag (this is what makes it "immutable"
#    once the repo setting is on). gh CLI is fine here:
gh release create v2.0.1 \
  --title "v2.0.1" \
  --notes "…changelog…" \
  --verify-tag
```

With **Immutable releases** enabled (§5), the published release + its `v2.0.1`
tag become unmodifiable — they cannot be moved or overwritten once published, so
a pinned version can never be silently re-pointed underneath a consumer. Docs:
<https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases>

### 1.3 Retarget the moving major tag

The major tag (`v2`) must **not** be attached to a release (keep releases on
`vX.Y.Z` only). Move it to the new patch after each release:

```bash
git tag -f v2 v2.0.1^{}     # point v2 at the same commit as v2.0.1
git push -f origin refs/tags/v2
```

`git tag -f` + `git push -f` is the exact mechanism GitHub documents for major-tag
management (same page as above). Prefer signing the moving tag too (`git tag -s -f`).

> Optional automation: `actions/publish-action`
> (<https://github.com/actions/publish-action>) will retag the major from a release
> workflow. It is convenience only — the two `git` commands above are the source of
> truth and are what you run if anything is off.

---

## 2. Signed release tags (GPG)

Sign every `vX.Y.Z` release tag so the public sees GitHub's green **Verified**
badge on the tag/release — the trust signal customers actually look at on a
security-sensitive auth action. GitHub lights the badge for GPG keys registered
on the signing account.

Prerequisites (one-time, per signing identity):

```bash
# 1. generate a key (ed25519 or rsa4096) whose UID email is a VERIFIED email on
#    the GitHub account that will sign releases (e.g. david@upwarden.io).
gpg --full-generate-key

# 2. export the public key
gpg --armor --export <KEY_ID>

# 3. register it on the account:
#    UI: Settings ▸ SSH and GPG keys ▸ New GPG key  — OR —
gh api -X POST /user/gpg_keys -f armored_public_key="$(gpg --armor --export <KEY_ID>)"

# 4. tell git to sign tags with it
git config user.signingkey <KEY_ID>
git config tag.gpgSign true          # sign all tags by default
```

Docs: adding a GPG key to your account —
<https://docs.github.com/en/authentication/managing-commit-signature-verification/adding-a-gpg-key-to-your-github-account>
; signing a tag — `git tag -s`
<https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-tags>.

> **Signing-identity decision (human):** commits in this repo are authored by the
> `upwarden-io-...[bot]` GitHub App identity, but a **GitHub App/bot cannot hold a
> GPG key**. Release *tags* must therefore be signed by a real maintainer account
> whose email is verified on GitHub (e.g. `david@upwarden.io`). Decide and document
> who the release-signer is. This is the one identity step `gh`/`git` alone can't
> settle — it needs a human key on a human account.

Together with **immutable releases** (§0/§1) and the **domain-verified publisher
org** (§4), a signed, frozen `vX.Y.Z` tag gives consumers a reproducible,
tamper-evident reference today: every consumer resolves to exactly the same bytes,
and any tampering with a published version is detectable. Point consumers at
full-SHA or immutable `vX.Y.Z` pinning as the strongest control (§0).

---

## 3. Marketplace listing (UI-only)

Requirements (all already satisfied by this repo except where noted):

- **Public** repository. ✓ (this repo is intended public)
- A **single** `action.yml` at the **repo root**. ✓
- A **unique action name** not colliding with an existing user/org/marketplace
  category. `name: "Setup Upwarden"` — verify uniqueness at publish time.
- **`branding.icon` + `branding.color`** in `action.yml`. ✓ (`package` / `purple`)
- The publishing account has **two-factor authentication** enabled, and has
  **accepted the GitHub Marketplace Developer Agreement**.

Publishing flow (UI — no `gh`/API path exists):

1. Open `action.yml` in the repo on github.com → a banner offers **"Publish this
   Action to the GitHub Marketplace"** → **Draft a release**.
2. On the release draft, tick **"Publish this Action to the GitHub Marketplace"**,
   accept the Developer Agreement if prompted, pick a primary + secondary category.
3. Choose the release tag (`v2.0.1`), publish.

Docs:
<https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publishing-actions-in-github-marketplace>.
Publishing to Marketplace is **UI-only** — the toggle is on the release page and is
not exposed via the REST API or `gh`. (A `gh release create` publishes the release
but does **not** flip the Marketplace toggle; that checkbox is a manual UI step.)

---

## 4. Domain verification for the `upwarden-io` org (UI + DNS)

Verifying `upwarden.io` gives the org a **Verified** badge on its profile and is the
identity signal that says "this org really is Upwarden" next to a security action —
i.e. the publisher identity is **domain-verified**.

Flow (UI-only in GitHub; the DNS half is ours to add):

1. github.com → org **`upwarden-io`** → **Settings** → Security → **"Verified and
   approved domains"** → **Add a domain** → `upwarden.io`.
2. GitHub issues a **DNS TXT challenge**. The record name is of the form
   **`_github-challenge-upwarden-io.upwarden.io`** with a one-time **code** value
   GitHub shows you (host label `_github-challenge-<org>`; exact code is generated
   per request — copy it from the GitHub UI).
3. Add that TXT record in **GCP Cloud DNS** (Upwarden controls `upwarden.io` DNS
   there, so this is fully in our hands — no third-party registrar dependency):

   ```bash
   # replace ZONE and the CODE value GitHub shows you
   gcloud dns record-sets create _github-challenge-upwarden-io.upwarden.io. \
     --zone=<upwarden-io-zone> --type=TXT --ttl=300 \
     --rrdatas='"<code-from-github-ui>"'
   ```

4. Wait for propagation (GitHub allows **up to 72h**; Cloud DNS at TTL 300 is
   usually minutes). Confirm from the authoritative NS:

   ```bash
   dig _github-challenge-upwarden-io.upwarden.io +nostats +nocomments +nocmd TXT
   ```

5. Back in GitHub: the domain's dropdown → **Continue verifying** → **Verify**.
6. After it verifies you may delete the TXT record (optional).

Docs:
<https://docs.github.com/en/organizations/managing-organization-settings/verifying-or-approving-a-domain-for-your-organization>.
There is **no API** for domain verification — the add/verify steps are UI-only; only
the DNS record itself is scriptable (via `gcloud`).

---

## 5. Human / DNS / UI checklist

Everything the main loop **cannot** do with `gh`/`git` alone:

- **[Human decision] Release-signing identity.** A GitHub App/bot can't hold a GPG
  key. Pick the maintainer account (e.g. `david@upwarden.io`) that signs release
  tags, and register its GPG public key on that account (UI: *Settings ▸ SSH and GPG
  keys*, or `gh api /user/gpg_keys` **run as that human's token**, not the bot).
- **[UI] Enable "Immutable releases"** on the repo (repo Settings → General/Releases
  checkbox) so every `vX.Y.Z` release and its tag become unmodifiable.
- **[UI + agreement] Marketplace listing.** Tick "Publish this Action to the GitHub
  Marketplace" on the release page; accept the **Marketplace Developer Agreement**;
  ensure the publishing account has **2FA** on. No API/`gh` path.
- **[UI] Org domain verification — add + verify.** Org Settings → Security → Verified
  and approved domains → Add `upwarden.io` → later **Continue verifying → Verify**.
  UI-only, no API.
- **[DNS] Add the `_github-challenge-upwarden-io` TXT record** in GCP Cloud DNS with
  the exact code from the GitHub UI. Scriptable via `gcloud`, but the **code value is
  minted by GitHub in the UI**, so it can't be fully pre-automated.
- **[UI, per major] Branding/name uniqueness check** at first Marketplace publish
  (name `"Setup Upwarden"` must not collide with an existing listing).
