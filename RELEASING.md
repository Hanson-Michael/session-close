# Releasing Session Close

## One-time setup (not done yet for this project)

Before the first release, three things need doing that Session Prep already
has and Session Close doesn't yet:

1. **Generate a Sparkle signing keypair** for this app — it cannot reuse
   Session Prep's key. Find `generate_keys` the same way Session Prep's
   README describes:
   ```
   find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f 2>/dev/null | head -1
   /path/to/generate_keys
   ```
   It stores the private key in your login Keychain and prints the public
   key — paste that into `SUPublicEDKey` in both `Session-Close-Info.plist`
   and the Xcode project's `INFOPLIST_KEY_SUPublicEDKey` build setting
   (currently both hold the placeholder
   `REPLACE_WITH_SESSION_CLOSE_SPARKLE_PUBLIC_KEY`).
2. **Create the GitHub repo** (`Hanson-Michael/session-close`, matching the
   URL already wired into `SUFeedURL` — update that key in both places if
   you use a different repo name) and push this project to it.
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
