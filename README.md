# SpektraMac

A native macOS port of [Spektrafilm](https://github.com/andreavolpato/spektrafilm), Andrea Volpato's
physically based simulation of analog colour photography (negative → print → scan), rewritten in
Swift with the image pipeline on the GPU via Metal.

**Status:** early work in progress. See [PLAN.md](PLAN.md) for the porting plan and the
[issues](../../issues) for the day-by-day progress.

## Goals

- Same results as the Python reference (pinned to Spektrafilm v0.3.4), verified stage by stage.
- Fast: the whole simulation, including grain and halation, runs on the Mac's GPU.
- A plain, Apple-conventional SwiftUI app: open a photo, choose film and paper, preview, export.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app |
| `Engine/` | `SpektraEngine` Swift package (Metal shaders, host code, tests) and the `spektra-cli` tool |
| `Engine/Sources/SpektraEngine/Resources/` | Film/paper profiles and spectral tables exported from Spektrafilm by `tools/export_tables.py` |
| `tools/` | Python scripts that export data and generate reference data from the original Spektrafilm |

Requires macOS 26.5 or newer and Xcode 27.

## Reference data

The parity tests compare every stage against dumps from the original Python Spektrafilm. They are
not committed (about 80 MB); generate them once with the pinned release:

```bash
uv tool install spektrafilm==0.3.4
~/.local/share/uv/tools/spektrafilm/bin/python tools/golden.py
```

This writes `golden/<case>/` with one float32 `.npy` per pipeline tap, the film's spectral lookup
table and the parameters used. `golden/manifest.json` (committed) holds a checksum of every file,
so `git diff` shows whether a regeneration changed anything. See the top of
[tools/golden.py](tools/golden.py) for the inputs, film pairs and settings.

## Credits and licence

All of the photographic model, film and paper data and the methods come from
[Spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato. This port is a
derivative work and is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). The film and paper
profile data are licensed by their author under CC BY-SA 4.0.

The [spektrafilm-rs](https://github.com/turbasvin/spektrafilm-rs) Rust port was used as a
reference for structuring the GPU stages.
