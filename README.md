# AppCatcher

Native iOS utility that measures an app container, clears the data iOS lets it
own, and seals the rest into verifiable, restorable `.catcher` archives.

Built in Swift and SwiftUI with [xtool](https://github.com/ktzatos/xtool) — the
whole build runs on this Linux machine, no macOS or Xcode involved.

## Ship state

- **Artifact**: `~/Documents/AppCatcher.ipa` (release, signed, 2.6 MB)
- **Bundle id**: `com.appcatcher.app` (xtool prefixes at sign time)
- **Profile**: Apple Development, bound to the personal device (UDID stored in your local xtool/Apple account, not committed here), expires a year after issue
- **Target**: iOS 17+, arm64, dark mode, native SwiftUI lists, zero warnings

```bash
scripts/build-ipa.sh              # rebuild + resign + republish
xtool devices --usb               # is the phone visible?
xtool install ~/Documents/AppCatcher.ipa
xtool launch
```

## What it does

**Cleaner** walks the sandbox and reports bytes per group, per folder, before
deleting anything: `Library/Caches`, `NSTemporaryDirectory`, WebView storage
(`WKWebsiteDataStore`), `Library/HTTPStorages`, `Library/Logs`. Reclaimed space
is measured as before-minus-after on each root, never estimated from a
selection. AppCatcher's own state (`Application Support/AppCatcher`, staging
and pre-restore folders) is on a deny list, so the tool can never eat its own
backup set.

**Backups** build a single self-describing `.catcher` file:

```
magic "ACBA" | version u8 | flags u8 | reserved u16 | payload u64 | header u32 | JSON header | payload
```

Every file is LZFSE-compressed (raw when compression would inflate it) and
SHA-256 hashed. With a password, the payload is sealed in 4 MiB AES-256-GCM
chunks, each bound to its index as associated data, keyed by PBKDF2-HMAC-SHA256
(120k iterations — implemented here because CryptoKit ships no KDF). Restore
re-hashes every entry before writing, and moves the outgoing `Documents` into a
guarded copy first. Verify opens an archive and re-hashes all of it without
writing a byte. Archives export and import through the system share sheet and
file importer.

**Pro** (StoreKit 2, one-time) gates what the services actually enforce:
unlimited backup history, encrypted archives, scheduled cleaning, web-data
sweeps. When the product id is not live in App Store Connect — every local
build — the paywall says so and offers a preview unlock instead of a dead
button.

## The honest part

iOS sandboxes every app. No App Store app can delete another app's caches, and
there is no private-API shortcut that survives signing on a development
profile. So AppCatcher does not pretend: it cleans the container it owns,
reports real device free space via `volumeAvailableCapacityForImportantUsage`,
and points at Settings › General › iPhone Storage for offloading other apps.
That explanation is in onboarding, on the dashboard, and in
Settings › Why only this app's files.

## Layout

```
Sources/AppCatcher/
  App/          AppCatcherApp, RootView (tabs, toast, paywall, onboarding)
  Core/
    Model/      cache groups, backup records, activity, storage snapshot
    Services/   CacheService, BackupService, ArchiveKit, Crypto, ProService, AppModel, AppSettings
    Support/    Sandbox paths, DiskProbe, formatting, haptics, progress box
  Features/     Dashboard, Cleaner, Backups, Premium, Settings
Support/Info.plist
scripts/build-ipa.sh
xtool.yml
```
