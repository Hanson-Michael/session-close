# Releasing Session Close

## One-time setup

1. **Sparkle signing key — done, shared with Session Prep.** Deliberate
   choice (not an oversight): Sparkle 2.x's `generate_keys` tool assumes one
   key per Mac by default (stored under a single generic Keychain item),
   not one per app, and per-app isolation would mean manually
   exporting/importing keys in and out of Keychain before every release of
   either app. Given neither app is a high-value target and the actual
   failure mode of sharing (a stolen key compromises every app trusting it
   at once, requiring a coordinated rotation) is an acceptable tradeoff for
   a solo/hobbyist release cadence, both apps use the same EdDSA key:
   `GLhkauDztD78r7uUzKZIgqj95cEUGFSAfUqCj8xnBD8=` — already set as
   `SUPublicEDKey` in `Session-Close-Info.plist`, `Packaging/Info.plist`,
   and both Xcode build configs' `INFOPLIST_KEY_SUPublicEDKey`. This is
   safe to share: each app only ever checks its own `SUFeedURL`, so sharing
   the signing key doesn't let either app see or install the other's
   updates — it only means the same private key (in Session Prep's
   Keychain-resident copy) is what signs releases for both. No swapping
   needed between releasing one app vs. the other.
2. **Create the GitHub repo** (`Hanson-Michael/session-close`, matching the
   URL already wired into `SUFeedURL` — update that key in both places if
   you use a different repo name) and push this project to it. Done — see
   https://github.com/Hanson-Michael/session-close.
3. **Store notarization credentials** under a Session-Close-specific
   keychain profile:
   ```
   xcrun notarytool store-credentials "session-close-notary"
   ```

## Quick path (once the above is done)

Bump **Version** and **Build** in Xcode's target **General** tab to the same
new value, then run:

```
Scripts/release.sh
```

Archives, exports, zips, notarizes, staples, signs for Sparkle, publishes
the GitHub Release, writes the appcast.xml entry, and pushes — same script
shape as Session Prep's, just pointed at this project's repo/profile names.

## Manual steps

> **Naming note:** Version and Build are the same number, `YY.MM.Dxx` (e.g.
> `26.8.1` for the first release on August, day+sequence tail keeps every
> release's tag/filename unique on its own — same scheme Session Prep uses).

Reference values for this project:

- Bundle ID: `com.mlhproductions.SessionClose`
- Team ID: `9MP82ALK4M`
- Notary keychain profile: `session-close-notary`
- GitHub repo: `Hanson-Michael/session-close`
- Appcast feed (tracked in repo, served raw): `https://raw.githubusercontent.com/Hanson-Michael/session-close/main/appcast.xml`

### 1. Bump the version

Xcode → **Session Close** target → **General** tab → set **Version** and
**Build** to the same `YY.MM.Dxx` value.

### 2. Archive and export a Developer ID build

**Product → Archive** → Organizer → **Distribute App** → **Direct
Distribution** (not App Store Connect).

### 3. Zip it

```
cd /path/to/export/folder
ditto -c -k --keepParent "Session Close.app" "SessionClose-26.8.1.zip"
```

### 4. Notarize

```
xcrun notarytool submit "SessionClose-26.8.1.zip" --keychain-profile "session-close-notary" --wait
```

### 5. Staple the ticket

```
unzip "SessionClose-26.8.1.zip" -d staple-tmp
xcrun stapler staple "staple-tmp/Session Close.app"
ditto -c -k --keepParent "staple-tmp/Session Close.app" "SessionClose-26.8.1.zip"
rm -rf staple-tmp
```

### 6. Sign the release zip for Sparkle

```
find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
/path/to/sign_update "SessionClose-26.8.1.zip"
```

Copy the printed `sparkle:edSignature="..."` and `length="..."` values.

### 7. Publish the release on GitHub

Tag `v26.8.1`, upload the zip, publish, copy the asset's download URL.

### 8. Add the appcast entry

Edit `appcast.xml` — add a new `<item>` above any existing ones (Sparkle
takes the first as latest):

```xml
<item>
    <title>Version 26.8.1</title>
    <sparkle:version>26.8.1</sparkle:version>
    <sparkle:shortVersionString>26.8.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.5</sparkle:minimumSystemVersion>
    <description><![CDATA[
        <ul>
            <li>What changed in this release.</li>
        </ul>
    ]]></description>
    <pubDate>Sat, 15 Aug 2026 00:00:00 +0000</pubDate>
    <enclosure
        url="https://github.com/Hanson-Michael/session-close/releases/download/v26.8.1/SessionClose-26.8.1.zip"
        sparkle:edSignature="PASTE_FROM_STEP_6"
        length="PASTE_FROM_STEP_6"
        type="application/octet-stream" />
</item>
```

### 9. Push

```
cd "/Users/michaelhanson/Documents/Xcode/Session Close"
git add appcast.xml
git commit -m "Release 26.8.1"
git push
```

### 10. Verify

Run an older build, **Help → Check for Updates…**, confirm it finds the new
version, downloads, and installs correctly.
