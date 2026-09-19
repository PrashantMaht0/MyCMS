# Contributing

Thanks for your interest in MyCMS.

## Getting set up

See [Build and run](README.md#build-and-run). In short: copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig`, add your Team ID,
and open `MyCMS.xcodeproj`.

## Before you open a pull request

- Build cleanly: `xcodebuild -project MyCMS.xcodeproj -scheme MyCMS -configuration Debug build`
- Keep changes focused; one topic per pull request.
- Never commit `Config/Local.xcconfig`, `xcuserdata/`, or build output. They are
  gitignored — if git offers them, something is wrong.
- If Xcode writes `DEVELOPMENT_TEAM` back into `project.pbxproj` (it does this
  when you touch the Signing & Capabilities tab), remove that line before
  committing. The team ID belongs in `Config/Local.xcconfig`.

## Style

Swift 6, SwiftUI, standard Xcode formatting. Match the surrounding code.

## Reporting bugs

Open an issue with your macOS version, Xcode version, and steps to reproduce.
