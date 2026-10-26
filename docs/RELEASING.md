# Preparing a Mac release

SkyEye is an early developer preview with a public source repository.
Review each package before you publish a release. Public source does not mean that
a package is signed or notarized.

## Verify

```bash
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests -v
./scripts/package.sh
```

The package script builds an arm64 app for Apple Silicon Macs, verifies
the signatures, and writes a DMG, app ZIP, and SHA-256 checksums under `build/`.
Intel Macs are not supported.
The DMG includes an Applications shortcut for drag-and-drop installation. No service
definitions, logs, local settings, or development files are copied into the app.

Local packages and CI artifacts are ad-hoc signed developer previews. They are not
notarized. macOS may block downloaded copies. A successful build or a passing CI run
does not mean a package is ready for general download.

## Sign and notarize

A smooth public download requires an Apple Developer Program membership, a Developer ID
Application certificate installed in the signing Mac's keychain, and a notarization
credential profile created with `xcrun notarytool store-credentials`.

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="skyeye-notary" \
./scripts/package.sh
```

The script signs each executable with the hardened runtime, notarizes and staples
the app, packages it, and notarizes and staples the DMG. Never commit a certificate,
private key, app-specific password, or notarization credential to Git.

## Publish from GitHub

[Release Please](https://github.com/googleapis/release-please) maintains the release
PR, version files, changelog, and GitHub tag. The pinned action is configured in
`.github/workflows/release-please.yml` and `release-please-config.json`.

Before the first run, enable **Settings → Actions → General → Workflow permissions →
Allow GitHub Actions to create and approve pull requests**. The workflow uses the
built-in `GITHUB_TOKEN`; it does not approve or merge its own PRs.

1. Use Conventional Commit titles when squash-merging changes: `fix:` for a patch,
   `feat:` for a minor version, and `fix!:` or `feat!:` for a breaking major release.
2. After changes land on `main`, Release Please creates or updates its release PR.
   That PR updates `version.txt`, `.release-please-manifest.json`, the app's
   `CFBundleShortVersionString`, and `CHANGELOG.md` together. CI rejects any
   mismatch between the version files and plist.
3. Review the version, changelog, and CI results, then merge the release PR.
   If GitHub asks you to approve workflows on the bot-created PR, approve them.
   If checks were not started, run **Actions → macOS CI → Run workflow** on the
   release PR's branch before merging.
4. Release Please creates the version tag and a draft GitHub release. The workflow
   reuses macOS CI to test and package the exact release commit, checks the app
   version against the tag, verifies checksums, uploads the DMG and ZIP, and only
   then publishes the developer prerelease.

The tag and draft are created before packaging; downloads remain unpublished if a
check or package fails. Use **Re-run failed jobs** on that Release Please run after
fixing the failure. This retains the successful release job's outputs and retries
packaging or uploading without allocating another version. Uploads replace assets
of the same name so they can be retried safely.

Ordinary CI runs produce developer preview artifacts without publishing releases.
Release Please runs on `main` pushes and can also be retried with **Actions →
Release Please → Run workflow**. Do not create release tags or bump version files
separately from the release PR.

### Choose a specific version

To request `0.2.1` or `1.0.0`, put a `Release-As` footer in the body of a commit
merged into `main`, for example:

```text
chore: prepare first stable release

Release-As: 1.0.0
```

Preserve that footer in the final squash commit message. Release Please proposes
that version in its release PR; review and merge the PR as usual. This is the
[documented version override](https://github.com/googleapis/release-please#how-do-i-change-the-version-number),
so no separate version input or custom increment script is needed.

SkyEye does not currently have an automatic updater. Users update by quitting SkyEye,
downloading a newer app, and replacing it in Applications. Their configuration and
logs remain in their Library folders.
