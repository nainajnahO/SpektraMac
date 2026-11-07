# Contributing to SpektraMac

Thanks for helping. SpektraMac has one maintainer, [@nainajnahO](https://github.com/nainajnahO), so most of this is
about making a change easy to review. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Before you start

- **A bug, something you'd like, or an accessibility barrier?**
  [Open an issue](https://github.com/nainajnahO/SpektraMac/issues/new/choose) and pick its form, which asks for what's
  needed.
- **A security problem?** Don't open an issue: report it privately, as [SECURITY.md](SECURITY.md) says.
- **Small fixes**, such as a crash, a typo or a wrong label, can go straight to a pull request.
- **Anything bigger**, such as a new control, a change to the simulation or a reworked view, starts with an issue, so
  we can agree on it before you spend time on it. To take on an open issue, say so in it.

## Native first

SpektraMac is meant to be a Mac app through and through: built on what Apple's frameworks already do, and looking and
behaving like the apps Apple makes. This is often called platform-native development, and it applies to the engine and
the interface alike.

- **Reach for the framework before writing your own.** When Apple's frameworks have a ready-made way to do a step, use
  it, for image processing, decoding and analysis as much as for layout and controls. Code written by hand to do the
  same job is usually weaker by design: Apple's version is tuned for the Mac's GPU and hardware, tested across far more
  uses than this app's, and improved with each macOS at no cost here. Write your own only when no framework does the
  job, and say why in a comment.
- **Port the model, not the code.** The engine follows Spektrafilm's physics, not its Python line by line (an
  idiomatic port rather than a literal one). A framework that does a step a little differently is still the better
  choice when the difference is measured and stays small, and when it's faster or more accurate in its own right.
  Matching the original exactly isn't the goal in itself. [docs/porting.md](docs/porting.md) shows each place the
  engine does this, measured.
- **Look and behave like a Mac app.** Follow Apple's
  [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), and use the system's
  own controls, materials, windows, menus and shortcuts, so the app looks current on each macOS without work of its
  own. When in doubt, do it the way Apple's own apps do. A custom control is for when the system has none, and should
  then look and work like a system one, accessibility included.

## Build and test

Build and run the app as in the README's [Build from source](README.md#build-from-source): macOS 26.5 or newer,
Xcode 27, and your own signing team or **Sign to Run Locally**.

Run the engine's tests with:

```sh
swift test -c release -Xswiftc -enable-testing --package-path Engine
```

Optimized, they take about a minute on an M1 Pro instead of six; `-enable-testing` keeps the `@testable import` they
rely on.

Run the app's tests, in `AppTests/`, with:

```sh
xcodebuild test -project SpektraMac.xcodeproj -scheme SpektraMac -destination 'platform=macOS'
```

They run `PhotoModel` in the app with the real engine, in about 10 seconds once built: what the Log says rendered,
what's set and what Undo is called. Each test keeps its settings in its own temporary folder and leaves its photos out
of File › Open Recent, so a run leaves yours as they were. The app's window opens while they run. What they can't see,
such as what's on screen or how a drag feels, a pull request still says you tried in the app.

### UI tests

The same command also runs the UI tests, in `UITests/`. They drive the app as a person does, through its
accessibility tree: whether a control is greyed out, what a menu item says, how a Reset arrow looks enabled and
disabled, and Xcode's accessibility audit (`performAccessibilityAudit()`) of the main window with each settings tab
showing and of the Log window. An audit finding that has an issue of its own is listed in the test with its number,
and passes until it's fixed; any other fails the test. To run only them:

```sh
xcodebuild test -project SpektraMac.xcodeproj -scheme SpektraMac -destination 'platform=macOS' -only-testing:SpektraMacUITests
```

They take over the screen for about four minutes, so run them when you can leave the Mac alone. macOS lets a test drive
an app only in Automation Mode, and by default turning it on asks for an administrator's password each time. Once, in
Terminal, run this and enter your password, and after that the tests run unattended:

```sh
automationmodetool enable-automationmode-without-authentication
```

They launch the app as it's installed for you, with your settings: each test opens a photo of its own (as Finder's
Open With does, so it goes to File › Open Recent) and undoes its changes before the app quits, so the settings it keeps
for the next launch are the ones it started with.

### Runtime checks

The tests check what the engine computes, not how it reaches memory: a read past the end of a value, a data race
between threads or a shader reading outside a buffer can work on one Mac and fail on another. Before a release, and
after changing a kernel's arguments (what a `setBytes` passes, or a struct a kernel reads), run the tests under
Xcode's three runtime checks. Each should pass with no reports:

```sh
# Metal API and shader validation: about a minute
MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER=1 swift test -c release -Xswiftc -enable-testing --package-path Engine
# Address Sanitizer: about 20 minutes
swift test --sanitize=address -Xswiftc -enable-testing --package-path Engine
# Thread Sanitizer: about 20 minutes
swift test --sanitize=thread -Xswiftc -enable-testing --package-path Engine
```

The sanitizers build unoptimized, hence the time. Under validation, Core Image prints `Error creating PSO for the uber
shader: ci_ubershader_r4` about 140 times: that's Core Image's own shader, not the engine's, and expected.

After changing how `PhotoModel`'s tasks share its state, also run the app's tests under Thread Sanitizer, which should
report nothing:

```sh
xcodebuild test -project SpektraMac.xcodeproj -scheme SpektraMac -destination 'platform=macOS' -enableThreadSanitizer YES
```

### Reference data

The parity tests compare every stage against dumps from the original Python Spektrafilm, at commit `3bb2c2d`, in
`golden/<case>/`: one float32 `.npy` per pipeline tap, the film's spectral lookup table and the parameters used.
The dumps (about 550 MB) aren't in the repository; make them with that Spektrafilm, installed as the README's
[Faithful to Spektrafilm](README.md#faithful-to-spektrafilm) says:

```sh
~/.local/share/uv/tools/spektrafilm/bin/python tools/golden.py
```

Without `golden/`, those tests are skipped. `golden/manifest.json` (committed) names the commit and holds a checksum of
every file, so `git diff` shows whether a regeneration changed anything. `tools/export_tables.py` exported the engine's
bundled data in `Engine/Sources/SpektraEngine/Resources/` the same way. The top of each script says what it writes.

So unless you've made `golden/`, the parity tests won't run for you. Say so in the pull request, and the maintainer
runs them.

Each parity check prints one line, `parity | test | case | check | measured | tolerance | headroom`, the headroom being
how many times worse the measurement can get before the test fails (`expectParity` in `Compare.swift`; the QA
oracle adds its p99 and mean). To see how close each is to failing, tightest first:

```sh
swift test -c release -Xswiftc -enable-testing --package-path Engine 2>&1 | grep '^parity' | sort -t'|' -k7,7g
```

To see how far SpektraMac is from another Spektrafilm commit, a branch such as `dev` or a newer `main`, run
`tools/check-upstream.sh <ref>`. It needs [uv](https://docs.astral.sh/uv/) and leaves your own install alone: it makes
the bundled data and the reference data from that commit in a temporary folder, diffs the data against
`Resources/` (`parameters.json` lists every parameter and its default), runs the tests against that reference data
and prints each parity check's worst case against its tolerance.

Every Monday, a workflow ([`upstream.yml`](.github/workflows/upstream.yml), `tools/upstream-moved.sh`) checks whether
Spektrafilm's `main` has moved past that commit, and if it has, opens or updates one issue, "Upstream Spektrafilm has
moved", listing the new commits and flagging those that touch the profiles, the parameter schema or the model.

## Changing the simulation

The engine ports Spektrafilm at commit `3bb2c2d` stage by stage, and the parity tests hold it to that. A change to a
ported stage should still match, or differ only by what the tests measure and allow (see [Native first](#native-first)):
say by how much in the pull request. If it changes a step's speed or result, regenerate
[docs/porting.md](docs/porting.md)'s table and images with `tools/port_report.py`, and say why in its text if the step
now works differently. Anything meant to render differently from Spektrafilm starts with an issue.

When a change shows in renders, run `tools/looks.sh` (under a minute; it needs `cwebp`: `brew install webp`). It
makes the film looks the README and the user guide show from NASA's Artemis II photo, saved as the app saves them with
each film's defaults. Commit the images it changes, and the pull request shows old and new side by side.

Before a pull request that touches the engine's speed or memory, run `tools/benchmark.sh` on an idle Mac (about five
minutes). It times the README's renders and the saves of a 50 and a 100 MP photo, with and without a diffusion filter,
and fails, naming the row, when a time is more than 15 % slower or a peak more than 10 % higher than
`tools/benchmark-baseline.tsv`. Put its table in the pull request. The committed baseline is the maintainer's MacBook
Pro (M1 Pro, 16 GB): on another Mac, record your own on `main` first with `tools/benchmark.sh --update`, and don't
commit it. A change that makes renders faster or leaner on purpose records the new baseline in the same pull request.

## Code

- Keep a change to what its issue asks: no abstractions, files or options for later.
- No dead code: no commented-out code, unused imports or unreachable branches.
- The app and the engine build in Swift 6 language mode. Keep them free of warnings.
- Comments say why, and match the code around them.

## Pull requests

- One issue per branch, cut from the latest `main`.
- Fill in the description's template: the issue it closes, what changed and why, the tests you ran, and what's not
  yet tried on the Mac.
- Pull requests are squash-merged, so the title becomes the commit on `main`.

## Licence

SpektraMac is a derivative of Spektrafilm and is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). Under
GitHub's [terms of service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#6-contributions-under-repository-license),
what you contribute is licensed the same way. The film and paper profile data come from Spektrafilm under CC BY-SA
4.0. Credit anything you bring in from elsewhere.
