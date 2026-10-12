# Plan: native macOS port of Spektrafilm (Swift + Metal)

## Context

Spektrafilm (Python, v0.3.4, installed via `uv tool` at
`~/.local/share/uv/tools/spektrafilm/lib/python3.13/site-packages/`) is the most physically grounded
free film simulation, but it runs on CPU only (numpy/scipy/numba), so SCAN takes long and the GUI is a
napari/Qt app. Goal: a native Mac app with the same engine ported to Swift + Metal so the full
simulation (incl. grain, halation) runs on the M1 Pro GPU, with an Apple-conventional UI shaped like
the user's Scanjet app. Work happens in ~1–2 h daily sessions, one subtask per day, until the whole
engine is ported.

Decisions already made:
- **Compute:** Metal compute shaders (GPU, f32) for everything per-pixel/spatial; Accelerate (CPU, f64)
  for one-off setup maths (LUT/table builds, curve fitting). No MLX, no Neural Engine (it only runs
  neural networks; this is physics).
- **v1 scope:** full engine ported + parity-tested, in a simple app (open, film/paper, live preview,
  key controls, export). Long tail of advanced controls after v1.
- **Repo:** public GitHub, GPLv3 (required as a derivative of GPLv3 code), crediting Spektrafilm /
  Andrea Volpato; profile data stays CC BY-SA 4.0.
- **UI:** same skeleton/design as Scanjet — Apple conventions, system components (details: see App section).

## Architecture

Repo `~/Developer/SpektraMac` (working name; not in iCloud Drive — git + iCloud sync conflict):

```
SpektraMac/
  SpektraMac.xcodeproj        app target (SwiftUI), mirrors Scanjet's structure
  App/                        SwiftUI views + app model
  Engine/                     local Swift package "SpektraEngine"
    Sources/SpektraEngine/    Swift host code + Metal shaders (.metal as package resources)
    Sources/spektra-cli/      CLI: image in → image out, and stage dumps for parity
    Tests/                    Swift Testing parity tests against golden data
    Resources/                profiles JSON (copied as-is), baked tables (.bin)
  tools/                      Python scripts run in the existing spektrafilm uv env
    golden.py                 generate per-stage reference dumps from Python
    export_tables.py          bake colour-science tables + tc LUT to binary
```

- **Pipeline shape (mirrors Python `runtime/pipeline.py` taps):**
  `rgb_in → rgb_pre → log_e_film → cmy_film → log_e_print → cmy_print → rgb_out`. Each tap is a
  testable checkpoint; the Swift engine exposes the same taps.
- **GPU data:** images as `MTLTexture` `rgba32Float` (spatial ops) / buffers for per-pixel kernels;
  whole chain encoded into one command buffer per render; upload once, read back once.
- **Precision:** per-pixel GPU in f32; CPU precomputes in f64. Clean NaNs host-side before upload
  (profiles contain `null` → NaN in `channel_density`/`base_density`; Python maps NaN transmission to 0).
- **Built-ins first:** try `MPSImageGaussianBlur`, vImage resize, ImageIO/Core Image (`CIRAWFilter`)
  for I/O before writing custom code; only write custom kernels where parity tests fail.
- **Reference designs:** Python source (authoritative, pinned to v0.3.4) and spektrafilm-rs
  (GPLv3, Rust/WGSL; same stage split, 25 WGSL kernels) as a porting crib for shader structure.

## App: Scanjet skeleton

Source to copy from: `~/Library/Mobile Documents/com~apple~CloudDocs/Scanjet/Scanjet/`
(`ScanjetApp.swift`, `ContentView.swift`, `ScannerModel.swift`, `ScanFrame+Image.swift`). Stock
SwiftUI only — no custom theme or tokens, SF Symbols, system materials, automatic dark mode.

```
+-------------------------------------------------------------------------------+
| [sidebar]  Photo name | [Film | Negative] segmented |           Open…  Save…  Log |
+------------------+----------------------------------------------+-------------+
| Form(.grouped)   |  ImageCanvas (fitted CGImage, letterboxed,   | .inspector  |
|  Simulation      |   ContentUnavailableView "Drop a photo")     |  (log)      |
|   Film / Paper   |                                              |             |
|  Exposure        +----------------------------------------------+             |
|  Enlarger …      | StatusBar (.bar): progress + text … error    |             |
+------------------+----------------------------------------------+-------------+
```

Reuse as-is or near as-is:
- `Window` scene with `.defaultSize(1100×760)`, `.commands` (Open ⌘O, Save ⌘S, Cancel ⌘.),
  `@NSApplicationDelegateAdaptor` AppDelegate owning the model.
- `NavigationSplitView`: sidebar `Form { Section … }.formStyle(.grouped)` at 280/320/420; toolbar,
  `.inspector` and `.safeAreaInset(edge: .bottom) { StatusBar() }` attached to the **detail** column;
  `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`.
- One `@MainActor @Observable` model via `.environment(model)`; `didSet` → `scheduleRender()`
  coalesce/cancel pattern from `ScannerModel` drives re-rendering.
- Engine as an `actor` with a custom serial executor (Scanjet's `SaneScanner` pattern).
- `ImageCanvas` fit/letterbox + display downscale (≤4096 px), `StatusBar`, `LogView`,
  ImageIO `write(to:as:)` export helper, `NSSavePanel`.
- Build settings: default actor isolation MainActor, approachable concurrency, member-import
  visibility, hardened runtime, Swift Testing; sandbox on (no USB needs, unlike Scanjet).

New relative to Scanjet: open/drag-drop of photos, sliders (`Slider` inside `LabeledContent`),
min window size, GPU readback to `CGImage` for the canvas.

## Parity strategy (how every subtask is verified)

1. `tools/golden.py` runs Python with `debug.deactivate_stochastic_effects=True` on fixed inputs
   (synthetic chart: grey ramp + colour patches; a 512 px real photo crop) for a few film/paper
   pairs, and dumps every tap as float32 `.npy` via `taps.collect`.
2. Swift Testing tests run the Swift stage on the same input and compare:
   per-stage max relative error ≤ 1e-4 (tune per stage, record actual numbers); final 8-bit output
   max ≤ 2/255 with ≥ 99.9 % identical pixels.
3. Colour path also checked with the LUT creator's QA oracle
   (`spektrafilm_lut_creator/qa/reference.py`, 50k samples, seed 20260515): ΔE2000 ≤ 0.5.
4. Stochastic stages (grain, glare, micro-structure) compared statistically (mean, RMS
   granularity, power spectrum within 5 %), not bit-exact.
5. Gotchas to match: blur switches FIR (σ<3, reflect edges, truncate 3) ↔ Young–van Vliet IIR
   (σ≥3); `fast_exponential_filter` uses a fixed 3-Gaussian coefficient table (copy, don't refit);
   auto-exposure and `boost_highlights` are whole-image reductions.

## Daily timeline (one subtask ≈ one 1–2 h session = one GitHub issue → branch → PR)

### Phase 0 — Setup
- **Day 1** Create public repo (GPLv3, README with credits), Xcode project + `SpektraEngine` package +
  `spektra-cli` skeleton mirroring Scanjet; commit this plan as `PLAN.md`; create one GitHub issue
  per day below (milestone per phase).
- **Day 2** `tools/golden.py`: fixed inputs, stochastic off, per-tap dumps for 3 pairs
  (Portra 400/Portra Endura, Vision3 500T/2383, Velvia 100 scan); record spektrafilm version.
- **Day 3** `tools/export_tables.py` + Swift loaders: profile JSON (28 files, NaN handling),
  `.npy` reader, CMFs, illuminants, colourspace/CAT matrices, filter CSVs, neutral-filter DB,
  `irradiance_xy_tc.npy` (192×192×81). Test: all profiles load, values match Python.

### Phase 1 — Metal foundation + first window
- **Day 4** Metal context, image/texture types, CPU↔GPU round trip, comparison helpers
  (max/mean diff, ΔE2000) used by all tests.
- **Day 5** Thin app shell copied from Scanjet (see App section): open a photo (⌘O + drag & drop,
  ImageIO), engine actor, `scheduleRender` pattern, canvas + status bar. Renders whatever stages
  exist so far (today: pass-through). From here on, every stage that lands is visible in the app.
- **Day 6** Per-pixel primitives: 1D curve interpolation (256 pts), log10/pow, 3×3 matmul.
- **Day 7** Gaussian blur parity + exponential filter (3-Gaussian mixture). Expect custom FIR
  (σ<3, reflect, truncate 3) + Young–van Vliet IIR (σ≥3); `MPSImageGaussianBlur` won't match edges —
  check it once, don't tune it.

### Phase 2 — Filming (→ `log_e_film`, `cmy_film`)
- **Day 8** Input decode (colour spaces + CCTF) and auto-exposure (centre-weighted reduction).
- **Day 9** tc LUT build on CPU (192²×81 · sensitivity × erf window), cached per film.
- **Days 10–11** Input gamut-compression bake into the tc LUT (part of the 1,341-line
  `utils/gamut_compression.py`): day 10 spectral-locus geometry + point-in-polygon; day 11 Reinhard
  knee + bilinear resample, parity on the baked LUT.
- **Day 12** hanatos2025 RGB→raw kernel (2D Mitchell-cubic lookup). ✅ first tap parity: `log_e_film`.
- **Day 13** `boost_highlights` (reduce→map), lens blur, halation + scatter (Σ Gaussians, renormalise).
- **Day 14** Density-curve development (exposure → density per channel).
- **Day 15** DIR couplers (3×3 inhibition, blur, re-interpolation on pre-corrected curves).
  ✅ `cmy_film` parity; app can show the developed negative.

### Phase 3 — Printing (→ `log_e_print`, `cmy_print`)
- **Day 16** Enlarger light on CPU: 3400 K blackbody, KG3, analytic dichroic filters at CC values,
  neutral-filter lookup per film/paper.
- **Day 17** Print exposure kernel: 81-band integration (10^-D transmission, NaN→0), mid-grey
  normalisation, preflash. ✅ `log_e_print` parity.
- **Day 18** Print curve morph (normal-CDF sums, root find) on CPU + development kernel.
  ✅ `cmy_print` parity.
- **Day 19** Buffer / perf check of the spectral kernel at 24 MP; add 3D-LUT shortcut only if needed.

### Phase 4 — Scanning (→ `rgb_out`)
- **Day 20** Scan kernel: CMY→spectrum × D50 · CMFs → XYZ, black/white correction, XYZ→RGB.
  First full film look visible in the app (without output gamut compression).
- **Day 21** CAM16-UCS forward + inverse on CPU (f64) with tests against colour-science.
- **Day 22** C_max(J,h) table by bisection + Reinhard knee on CPU; parity on compressed samples.
- **Day 23** `cam16ucs` compression as a Metal kernel (match the CPU version, then Python).
- **Day 24** Glare, scanner blur, unsharp mask, CCTF encode, output colour spaces.
  ✅ **Milestone: full deterministic chain matches Python** (+ QA oracle).
- **Day 25** Slide (positive) films and "scan film" (view the negative) paths.

### Phase 5 — Grain + speed
- **Day 26** GPU RNG (counter-based hash) + Poisson / binomial / lognormal samplers, statistical tests.
- **Day 27** Grain density layers + Poisson→binomial particle model per channel/sublayer.
- **Day 28** Dye-cloud blur, lognormal micro-structure, final blur. ✅ grain statistics match.
- **Day 29** Full-resolution performance pass (24–48 MP): memory, tiling if needed, Metal System
  Trace; benchmark vs Python SCAN.

### Phase 6 — App v1
- **Day 30** RAW import via `CIRAWFilter` (linear), preview size vs full-res Render, Film/Negative
  segmented switch.
- **Day 31** Controls v1: film + paper pickers (paper auto-selected from film), auto/compensation
  exposure, print exposure, Y/M filter shift, grain/halation on-off.
- **Day 32** Export: 16-bit TIFF / JPEG / PNG with ICC + metadata copy (ImageIO), progress, cancel.
- **Day 33** Presets: save/load (Codable JSON), per-stock defaults.
- **Day 34** You test on real photos side-by-side with the Python app; fix list.
- **Day 35** v1 release tag.

≈ 35 sessions ≈ 7 weeks of weekday sessions; overruns get split into new issues, not squeezed.

### After v1 (backlog, ~1 day each)
Other output gamut modes (oklch, aces_rgc, oklrab, jzazbz) · camera/enlarger diffusion filters
(FFT) · full FILM/PRINT/ADVANCED controls (halation, couplers, grain, chemistry, glare, preflash,
channel swap) · mallett2019 upsampling · LUT export for LightCraft (with a working exposure setting) ·
preview crop/upscale · display transform · upstream-sync routine for new Spektrafilm versions.

## Daily session routine
1. `gh issue list --milestone <current phase>` → take the lowest open issue; branch off `main`.
2. Generate/refresh golden data if the subtask needs it; implement; run parity tests.
3. PR with measured tolerances in the description; merge; delete branch; close issue.
4. If a subtask overruns, split the remainder into a new issue for the next day.

## Verification
- Engine: `swift test` in `Engine/` — per-stage parity tests against `tools/golden.py` dumps;
  QA-oracle test for the colour path; statistical grain tests.
- CLI: `spektra-cli render in.tif -o out.tif --film kodak_portra_400 --print kodak_portra_endura`
  compared with Python's output on the same image.
- App: build and run from Xcode; you judge the look and feel on your own photos.
