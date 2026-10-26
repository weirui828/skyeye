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

The package script builds a universal app for Apple Silicon and Intel Macs, verifies
the signatures, and writes a DMG, app ZIP, and SHA-256 checksums under `build/`.
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

## Publish deliberately

1. Confirm the macOS CI jobs pass on Apple Silicon and Intel.
2. Check the version and build number in `Resources/Info.plist`.
3. Verify the signed package on a Mac that has not built SkyEye before, including
   drag-to-Applications installation, initial command approval, quitting, and updating.
4. Create a GitHub prerelease with the notarized DMG, ZIP, and checksum file. Include
   known limitations and macOS requirements in its release notes.

The CI workflow uploads build artifacts for review; it does not change repository
visibility, publish a release, or access signing credentials.

SkyEye does not currently have an automatic updater. Users update by quitting SkyEye,
downloading a newer app, and replacing it in Applications. Their configuration and
logs remain in their Library folders.
