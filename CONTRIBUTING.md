# Contributing to SpektraMac

Thanks for helping. SpektraMac has one maintainer, [@nainajnahO](https://github.com/nainajnahO), so most of this is
about making a change easy to review. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Before you start

- **A bug, or something you'd like?** [Open an issue](https://github.com/nainajnahO/SpektraMac/issues/new). For a bug,
  say which Mac and macOS, which SpektraMac (a release, or the commit you built), the photo's format, the film and
  paper, and anything the Log window shows.
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
  Matching the original exactly isn't the goal in itself.
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
rely on. The app has no tests of its own, so a pull request says what you tried in it.

### Reference data

The parity tests compare every stage against dumps from the original Python Spektrafilm 0.3.4 in `golden/<case>/`:
one float32 `.npy` per pipeline tap, the film's spectral lookup table and the parameters used. Neither the dumps
(about 230 MB) nor the Python scripts that make them and that exported the bundled data are in the repository;
without `golden/`, those tests are skipped, as on CI. `golden/manifest.json` (committed) holds a checksum of every
file, so `git diff` shows whether a regeneration changed anything.

So unless you have `golden/`, the parity tests won't run for you. Say so in the pull request, and the maintainer runs
them.

### CI

Every pull request is built and tested on GitHub Actions (`.github/workflows/build.yml`): a Release build of the app,
unsigned, and the engine's tests without `golden/`. `PhotoOpeningTests` is skipped there, as reading its renders back
crashes the runner's virtual GPU; it runs with the rest on a Mac.

## Changing the simulation

The engine ports Spektrafilm 0.3.4 stage by stage, and the parity tests hold it to that. A change to a ported stage
should still match, or differ only by what the tests measure and allow (see [Native first](#native-first)): say by
how much in the pull request. Anything meant to render differently from Spektrafilm starts with an issue.

## Code

- Keep a change to what its issue asks: no abstractions, files or options for later.
- No dead code: no commented-out code, unused imports or unreachable branches.
- The app and the engine build in Swift 6 language mode. Keep them free of warnings.
- Comments say why, and match the code around them.

## Pull requests

- One issue per branch, cut from the latest `main`.
- The description starts with `Closes #` and the issue's number, then says what changed and why, and:
  - **Tests:** what you ran: the engine's tests, whether the parity tests ran, and the Release build.
  - **Not yet tried on the Mac:** what still needs someone to look at or try in the app, and how.
- Pull requests are squash-merged, so the title becomes the commit on `main`.

## Licence

SpektraMac is a derivative of Spektrafilm and is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). Under
GitHub's [terms of service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#6-contributions-under-repository-license),
what you contribute is licensed the same way. The film and paper profile data come from Spektrafilm under CC BY-SA
4.0. Credit anything you bring in from elsewhere.
