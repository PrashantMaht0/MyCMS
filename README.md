# MyCMS

A native macOS CMS for a personal portfolio website. Built with SwiftUI.

> Status: early development. The app launches and reports whether its database,
> git and Ollama are working. Writing and publishing are not built yet.

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
  App/              App entry point, the environment container, the scenes
  Health/           The launch checks for the database, git and Ollama
  Data/             SQLite store (GRDB)
  Publish/          Git client, and later the serializer and validator
  AI/               Ollama client
  Shared/           Loggers and small shared types
  Editor/           The writing surface (not built yet)
Config/             Build configuration; Signing.xcconfig includes your Local.xcconfig
MyCMSTests/         Unit tests (Swift Testing)
.github/workflows/  CI build and test on every push and pull request
```

`Editor/` does not exist yet. Every other folder is in place.

## Dependencies

Three Swift Package Manager dependencies, resolved by Xcode on first open:

- [GRDB.swift](https://github.com/groue/GRDB.swift) for SQLite
- [swift-markdown](https://github.com/swiftlang/swift-markdown) for parsing Markdown
- [Yams](https://github.com/jpsim/Yams) for YAML frontmatter

## Sandbox

The app is **not** sandboxed, and it holds no entitlements. Publishing runs the
system `/usr/bin/git` against a folder you choose, which the App Sandbox blocks,
so the sandbox is off by design. The hardened runtime stays on, because it does
not interfere and notarising a release later requires it.

This means the app cannot ship on the Mac App Store. It is installed from a .dmg.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
