# Kage — Release Setup

This is a one-time setup to enable **signed, notarized, auto-updating GitHub Releases** for Kage.

The release pipeline (`.github/workflows/main.yml`) already does everything automatically once the
credentials below exist. When you run `make bump-and-release`, CI builds the Release app, signs it
with your Apple Developer ID, notarizes it with Apple, builds a DMG + zip, generates a signed Sparkle
appcast, and publishes a **GitHub Release** on `ninjaappsnet/kage`. The app auto-updates from
`https://github.com/ninjaappsnet/kage/releases/latest/download/appcast.xml`.

**Where do the keys go?** Almost everything lives in **GitHub → repo Settings → Secrets and variables
→ Actions**. The only exceptions: the Sparkle key is generated on your Mac first, and the Sparkle
*public* key is committed into `supacode/Info.plist`.

## Prerequisites

- A paid **Apple Developer Program** membership (team `745BCAQCQ4`). Required for Developer ID signing
  and notarization. (~$99/yr — you already have this from Caustic.)
- [Homebrew](https://brew.sh) on your Mac (for the Sparkle tools).
- Admin access to the `ninjaappsnet/kage` GitHub repo.

---

## Step 1 — Apple "Developer ID Application" certificate

This is the certificate that signs the app so macOS Gatekeeper trusts it.

### 1a. Create the certificate (easiest via Xcode)

1. Xcode → **Settings → Accounts** → select your Apple ID → **Manage Certificates…**
2. Click **+** (bottom-left) → **Developer ID Application**.
3. It appears in the list. Close the dialog.

(Alternative without Xcode: <https://developer.apple.com/account/resources/certificates> → **+** →
*Developer ID Application* → follow the CSR upload steps.)

### 1b. Find its identity name

```bash
security find-identity -v -p codesigning
```
Copy the full name in quotes, e.g. `Developer ID Application: Your Name (745BCAQCQ4)`.
→ this is the secret **`DEVELOPER_ID_IDENTITY`**.

### 1c. Export the certificate as a `.p12`

1. Open **Keychain Access** → **login** keychain → **My Certificates**.
2. Find **Developer ID Application: … (745BCAQCQ4)**, expand it (must include the private key).
3. Right-click → **Export "Developer ID Application…"** → save as `Certificates.p12`.
4. Set an export password when prompted. → this is **`DEVELOPER_ID_CERT_PASSWORD`**.

### 1d. Base64-encode the `.p12` for GitHub

```bash
base64 -i Certificates.p12 | pbcopy
```
The clipboard now holds **`DEVELOPER_ID_CERT_P12`** (paste it as the secret value).

---

## Step 2 — Apple notarization API key

Notarization is Apple scanning your build so it opens without warnings. CI uses an
**App Store Connect API key** (no password / 2FA needed in CI).

1. Go to <https://appstoreconnect.apple.com/access/integrations/api> (Users and Access → **Integrations** → **App Store Connect API**).
2. At the top, copy the **Issuer ID** (a UUID). → secret **`APPLE_NOTARIZATION_ISSUER`**.
3. Click **+** to generate a key → name it `kage-notary` → role **Developer** → **Generate**.
4. Copy the **Key ID** (10 characters). → secret **`APPLE_NOTARIZATION_KEY_ID`**.
5. Click **Download API Key** to get the `AuthKey_XXXXXXXXXX.p8` file. **You can only download it once.**
6. The full text of that `.p8` file (including the `-----BEGIN PRIVATE KEY-----` lines) → secret
   **`APPLE_NOTARIZATION_KEY`**. Copy it with:
   ```bash
   pbcopy < AuthKey_XXXXXXXXXX.p8
   ```

---

## Step 3 — Sparkle update-signing key (EdDSA)

Sparkle signs each update so the installed app trusts it. Kage needs **its own** key (you cannot reuse
supacode's). Generated locally, then split: the **public** key goes in the app, the **private** key
becomes a CI secret.

```bash
brew install sparkle
generate_keys                        # prints your PUBLIC key (a base64 string) — copy it
generate_keys -x kage_sparkle_private.txt   # writes the PRIVATE key to a file
```

- The printed **public** key → goes into `supacode/Info.plist` under `SUPublicEDKey` (see Step 6).
- The contents of `kage_sparkle_private.txt` → secret **`SPARKLE_PRIVATE_KEY`**:
  ```bash
  pbcopy < kage_sparkle_private.txt
  ```
- **Delete the private file afterward** (`rm kage_sparkle_private.txt`). The key also lives in your
  login Keychain as a backup.

> If `brew install sparkle` doesn't provide `generate_keys`, download the Sparkle release tarball from
> <https://github.com/sparkle-project/Sparkle/releases> — `generate_keys` is in its `bin/` folder.

---

## Step 4 — GitHub release token

The pipeline force-moves the `tip` (nightly) tag, which needs a real token (not the default
`GITHUB_TOKEN`) so the push can trigger workflows.

1. <https://github.com/settings/tokens> → **Tokens (classic)** → **Generate new token (classic)**.
2. Scope: **`repo`** (and **`workflow`**). Set a sensible expiry.
3. Generate → copy the token. → secret **`GH_RELEASE_TOKEN`**.

(Fine-grained alternative: a token scoped to `ninjaappsnet/kage` with **Contents: Read and write**.)

---

## Step 5 — Add the secrets to GitHub

Go to **<https://github.com/ninjaappsnet/kage/settings/secrets/actions>** → **New repository secret**,
and add each of these (name → value):

| Secret name | Value (from) |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of `Certificates.p12` (Step 1d) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password (Step 1c) |
| `DEVELOPER_ID_IDENTITY` | `Developer ID Application: … (745BCAQCQ4)` (Step 1b) |
| `KEYCHAIN_PASSWORD` | any passphrase you make up (temp CI keychain) |
| `APPLE_TEAM_ID` | `745BCAQCQ4` |
| `APPLE_NOTARIZATION_ISSUER` | Issuer ID UUID (Step 2) |
| `APPLE_NOTARIZATION_KEY_ID` | Key ID (Step 2) |
| `APPLE_NOTARIZATION_KEY` | contents of the `.p8` (Step 2) |
| `SPARKLE_PRIVATE_KEY` | contents of `kage_sparkle_private.txt` (Step 3) |
| `GH_RELEASE_TOKEN` | the PAT (Step 4) |

> Telemetry (Sentry/PostHog) was stripped from Kage, so **no** `SENTRY_*` / `POSTHOG_*` secrets are needed.

---

## Step 6 — Put the Sparkle public key in the app

Edit `supacode/Info.plist` and replace the `SUPublicEDKey` value with the **public** key printed in
Step 3:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_KAGE_PUBLIC_KEY_HERE</string>
```

Commit it. (The current value is still supacode's key — updates won't verify until you swap it.)

---

## Step 7 — Enable Actions and cut the first release

Actions are currently disabled on the repo (so nothing ran before setup was done). Enable them, then
release:

```bash
gh api -X PUT /repos/ninjaappsnet/kage/actions/permissions -F enabled=true

make bump-and-release VERSION=0.1.0
```

`bump-and-release` bumps `MARKETING_VERSION`, commits, tags `v0.1.0`, and pushes. The push to `main`
triggers CI, which detects the tag at HEAD and publishes a **GitHub Release** with the DMG, zip,
checksums, and signed appcast. Watch it at
<https://github.com/ninjaappsnet/kage/actions>.

---

## What you get

- **Stable releases**: <https://github.com/ninjaappsnet/kage/releases> (every `make bump-and-release`).
- **Nightly (`tip`)**: updated on every push to `main`.
- **Auto-update**: shipped apps check
  `https://github.com/ninjaappsnet/kage/releases/latest/download/appcast.xml` and update themselves.

## Troubleshooting

- **"Developer ID Application identity not found in keychain"** → the `.p12` didn't include the private
  key, or `DEVELOPER_ID_IDENTITY` doesn't match the cert name. Re-export from *My Certificates* (Step 1c).
- **Notarization rejected** → check `APPLE_NOTARIZATION_*` secrets; the API key role must be at least
  *Developer*.
- **Update won't install on users' machines** → `SUPublicEDKey` (Step 6) doesn't match
  `SPARKLE_PRIVATE_KEY`. Regenerate both from the same `generate_keys` run.
- **`/releases/latest/download/appcast.xml` 404s** → no non-prerelease release exists yet; cut one
  stable release (Step 7).

## Security notes

- Secrets are write-only in GitHub; nobody (including you) can read them back — keep local copies safe.
- The `.p12`, `.p8`, and `kage_sparkle_private.txt` are sensitive. Store them in a password manager and
  delete the working copies after uploading.
- Never commit any of these files. (`.gitignore` should cover `*.p12` / `*.p8`; verify before committing.)
