# SpektraMac

A native macOS port of [Spektrafilm](https://github.com/andreavolpato/spektrafilm), Andrea Volpato's
physically based simulation of analog colour photography (negative → print → scan), rewritten in
Swift with the image pipeline on the GPU via Metal.

**Status:** version 1.2: the whole Spektrafilm 0.3.4 engine is ported and parity-tested. See the
[releases](../../releases) for what's in it, [PLAN.md](PLAN.md) for the porting plan and the
[issues](../../issues) for what's next.

## Goals

- Same results as the Python reference (pinned to Spektrafilm v0.3.4), verified stage by stage.
- Fast: the whole simulation, including grain and halation, runs on the Mac's GPU.
- A plain, Apple-conventional SwiftUI app: open a photo, choose film and paper, preview, export.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app |
| `Engine/` | `SpektraEngine` Swift package (Metal shaders, host code, tests) and the `spektra-cli` tool |
| `Engine/Sources/SpektraEngine/Resources/` | Film/paper profiles and spectral tables exported from Spektrafilm |

Requires macOS 26.5 or newer and Xcode 27.

## Reference data

The parity tests compare every stage against dumps from the original Python Spektrafilm 0.3.4 in
`golden/<case>/`: one float32 `.npy` per pipeline tap, the film's spectral lookup table and the
parameters used. Neither the dumps (about 230 MB) nor the Python scripts that make them and that
exported the bundled data are in the repository; without `golden/`, those tests fail with a "not
found" error. `golden/manifest.json` (committed) holds a checksum of every file, so `git diff` shows
whether a regeneration changed anything.

## Credits and licence

All of the photographic model, film and paper data and the methods come from
[Spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato. This port is a
derivative work and is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). The film and paper
profile data are licensed by their author under CC BY-SA 4.0.

The [spektrafilm-rs](https://github.com/turbasvin/spektrafilm-rs) Rust port was used as a
reference for structuring the GPU stages.
