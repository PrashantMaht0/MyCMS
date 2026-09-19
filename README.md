# MyCMS

A native macOS CMS for a personal portfolio website. Built with SwiftUI.

> Status: early development. The app is a skeleton right now.

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6)

## Build and run

```bash
git clone https://github.com/PrashantMaht0/MyCMS.git
cd MyCMS
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then add your Team ID
open MyCMS.xcodeproj
```

Press ⌘R in Xcode.

`Config/Local.xcconfig` holds your Apple Developer Team ID and is gitignored, so
signing settings never land in commits. Without a Team ID you can still build
unsigned:

```bash
xcodebuild -project MyCMS.xcodeproj -scheme MyCMS -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Project layout

```
MyCMS.xcodeproj     Xcode project (shared MyCMS scheme)
MyCMS/              App sources and assets
Config/             Build configuration; Signing.xcconfig includes your Local.xcconfig
.github/workflows/  CI build on every push and pull request
```

## Sandbox

The app runs sandboxed. Currently enabled entitlements:

- Outgoing and incoming network connections
- Read-only access to user-selected files

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
