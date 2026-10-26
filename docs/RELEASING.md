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

1. Update `CFBundleShortVersionString` in `Resources/Info.plist` to a new version,
   such as `0.1.1`. Increase `CFBundleVersion` too. Merge the change into `main`.
2. Open **Actions → macOS CI → Run workflow**.
3. Select the `main` branch and enable **Publish a release after tests and packaging**.
4. Click **Run workflow**.

The workflow runs the full tests, builds the Apple Silicon packages, verifies their
checksums, and publishes a developer prerelease with the DMG, ZIP, and checksum file.
The release tag, such as `v0.1.1`, comes from the app version. Release notes are
created automatically. An existing release is not overwritten; use a new version.

Ordinary pushes and manual runs with the release option disabled only produce CI
artifacts. Pull requests run tests and build the app without packaging or publishing.
Releases can only run from `main`. The workflow uses GitHub's built-in token; no
personal access token or Apple credentials are needed for this preview release.

SkyEye does not currently have an automatic updater. Users update by quitting SkyEye,
downloading a newer app, and replacing it in Applications. Their configuration and
logs remain in their Library folders.
