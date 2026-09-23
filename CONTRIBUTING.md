# Working on MyCMS

This is a personal app that manages one website, so this file is mostly notes to myself for the
next time I open the project. If you are someone else and want to try it, everything in
[README.md](README.md) applies to you too.

## Getting set up

Full steps are in [Build and run](README.md#build-and-run). The short version: copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig`, put your Apple Developer Team ID in it,
then open `MyCMS.xcodeproj`.

Turn the pre commit hook on once. A pre commit hook is a script git runs every time you commit, and
this one checks the code before the commit is allowed through:

```bash
git config core.hooksPath .githooks
brew install swiftlint
```

SwiftLint is optional. Without it the hook skips that one check and tells you it did.

## Before committing

The hook runs three things: the formatting check, SwiftLint, and a build. If any of them fail, the
commit is stopped and you see why. It only ever checks. It never edits a file for you and never
commits anything by itself.

Run the tests yourself, since the hook does not:

```bash
xcodebuild -scheme MyCMS -destination 'platform=macOS' test
```

Keep each commit about one thing.

## Two things that go wrong

**Xcode adds your Team ID to the project file.** It writes a `DEVELOPMENT_TEAM` line into
`MyCMS.xcodeproj/project.pbxproj` as soon as you open the Signing and Capabilities tab. Delete that
line before committing. The Team ID belongs in `Config/Local.xcconfig`, which git ignores, so it
never reaches GitHub.

**Some files must never be committed:** `Config/Local.xcconfig`, any `xcuserdata/` folder, `build/`
and `Notes.md`. All four are already ignored. If git ever offers you one of them, something has
moved that should not have.

## House rules

These live in `AGENTS.md` (kept on my machine, not in this repository) and most of them are checked
automatically by `.swiftlint.yml`:

- A plain `//` comment is one precise line, two at most, and says **why** the code is like that, not
  what it does.
- A `///` documentation comment on a type or a function can be longer. That is where the inputs,
  the outputs and the errors get written down.
- No em dash or en dash anywhere, in code or in comments.
- Tests use Swift Testing, not XCTest.

## Design notes

The specs and design notes in `docs/` stay on my machine and are not in this repository. The part
worth reading is [Why it is built this way](README.md#why-it-is-built-this-way) in the README: the
one decision everything else follows from, and the nine rules that keep publishing safe.
