"""Time each ported Spektrafilm step against SpektraMac's, and regenerate docs/porting.md's table and images.

Run with the interpreter of the pinned Spektrafilm install, from anywhere in the repository (it runs
`swift test`, so it needs Xcode's toolchain):

    ~/.local/share/uv/tools/spektrafilm/bin/python tools/port_report.py

For each case it runs the Python step on the input SpektraMac gets (best of 3 after a warm-up run, so Numba
has compiled), and writes the input and Python's output to a temporary folder laid out like golden/. Then it
runs the engine's `portReport` test with SPEKTRA_PORT_REPORT and SPEKTRA_GOLDEN pointing there: the test
times SpektraMac's step on that input (best of 5 after a warm-up run) and writes its output beside Python's.
Last, it measures how far apart the outputs are, writes the comparison images to docs/porting/ and replaces
the table between docs/porting.md's markers. The prose around them is written by hand.

The "Every film and paper" tables come from the parity tests against golden/ (or SPEKTRA_GOLDEN): the QA
oracle's ΔE2000 for each printed pair, and each slide's chart stage by stage, read from the tests' `parity`
lines (`expectParity` in Engine/Tests/SpektraEngineTests/Compare.swift).

Inputs, both public domain:
- photo: scikit-image's `astronaut` (NASA), cropped to 3:2 and enlarged to 2400 x 1600 with Lanczos, run as
  the photo golden case runs (Portra 400 printed on Portra Endura, sRGB in, default settings, grain and
  glare off). The stages and most steps take its intermediates.
- stars: scikit-image's `hubble_deep_field` (NASA/ESA), mirrored out to 2400 x 1600 at its own sharpness,
  linear, its brightest stars at 4: point lights for halation and the diffusion filter.
"""

from __future__ import annotations

import copy
import json
import os
import platform
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from datetime import date
from importlib.metadata import version
from pathlib import Path
from typing import Callable

import numpy as np
import skimage.data
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

import golden
from spektrafilm.model.diffusion import apply_diffusion_filter_um, apply_halation_um
from spektrafilm.model.glare import compute_random_glare_amount
from spektrafilm.model.grain import apply_grain
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.profiles.io import load_profile
from spektrafilm.runtime.params_schema import DiffusionFilterParams, GlareParams, GrainParams
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.services import EnlargerService
from spektrafilm.utils import gamut_compression
from spektrafilm.utils.autoexposure import measure_autoexposure_ev
from spektrafilm.utils.fast_gaussian_filter import fast_exponential_filter, fast_gaussian_filter
from spektrafilm.utils.fast_interp import fast_interp
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec, compress_rgb
from spektrafilm.utils.morph_curves import PrintCurvesMorphParams, apply_print_curves_morph
from spektrafilm.utils.numba_boost_hightlights import boost_highlights
from spektrafilm.utils.preview import resize_for_preview
from spektrafilm.utils.spectral_upsampling import compute_hanatos2025_tc_lut

REPO = Path(__file__).resolve().parent.parent
DOC = REPO / "docs/porting.md"
IMAGES = REPO / "docs/porting"
BEGIN, END = "<!-- port_report:begin -->", "<!-- port_report:end -->"
FILMS_BEGIN, FILMS_END = "<!-- port_report:films:begin -->", "<!-- port_report:films:end -->"
PROFILES = REPO / "Engine/Sources/SpektraEngine/Resources/profiles"
# The parity tests the films tables read: the QA oracle, and the stages a slide's chart goes through.
SLIDE_STAGES = [("exposeMatchesLogEFilm(caseName:)", "log_e_film max abs", "Exposure (log₁₀)"),
                ("developMatchesCMYFilm(caseName:)", "cmy_film max abs", "Density"),
                ("scanMatchesPythonBeforeGamutCompression(caseName:)", "scanned RGB max abs", "Scanned RGB"),
                ("chainMatchesPython(caseName:)", "rgb_out max abs", "Output RGB")]
HEIGHT, WIDTH = 1600, 2400
FILM, PAPER = "kodak_portra_400", "kodak_portra_endura"
CROP = 400


@dataclass
class Case:
    """One row of the table: a Python step, SpektraMac's counterpart and how they compare."""
    name: str          # its folder in the temporary folder, and the case the Swift test runs
    python: str        # the Python step, as the table names it
    mac: str           # SpektraMac's counterpart
    method: str        # "Same", "Apple's" (an Apple framework does it) or "Different"
    run: Callable[[], np.ndarray]             # the Python step
    inputs: dict[str, np.ndarray] = field(default_factory=dict)
    params: dict[str, list[float]] = field(default_factory=dict)  # for the Swift side
    encoded: bool = False                     # an encoded image: the difference in 8-bit levels too
    compare: Callable[[np.ndarray, np.ndarray], str] | None = None  # (Python, SpektraMac) -> text, for noise
    exact: np.ndarray | None = None           # what both approximate, when there's an exact answer
    domain: tuple[str, float] | None = None   # (where, lowest value): also the difference where Python's is above it
    output: np.ndarray | None = None
    seconds: float = 0.0


def best_of(run: Callable[[], np.ndarray], runs: int = 3) -> tuple[np.ndarray, float]:
    """`run`'s output and its best time over `runs`, after a warm-up run."""
    output = run()
    best = float("inf")
    for _ in range(runs):
        start = time.perf_counter()
        output = run()
        best = min(best, time.perf_counter() - start)
    return output, best


def f32(array) -> np.ndarray:
    """As the Swift side reads it: float32, back in float64 for Python."""
    return np.asarray(array, dtype=np.float32).astype(np.float64)


def photo() -> np.ndarray:
    astronaut = golden.make_photo()
    top = (astronaut.shape[0] - astronaut.shape[1] * 2 // 3) // 2
    crop = np.uint8(np.round(astronaut[top:top + astronaut.shape[1] * 2 // 3] * 255))
    return np.asarray(Image.fromarray(crop).resize((WIDTH, HEIGHT), Image.LANCZOS), dtype=np.float64) / 255


def stars() -> np.ndarray:
    field = skimage.data.hubble_deep_field().astype(np.float64) / 255
    field = np.pad(field, ((0, HEIGHT - field.shape[0]), (0, WIDTH - field.shape[1]), (0, 0)), mode="symmetric")
    return f32(4 * np.where(field <= 0.04045, field / 12.92, ((field + 0.055) / 1.055) ** 2.4))


def glare_compare(python: np.ndarray, mac: np.ndarray) -> str:
    """Glare's field is random: its mean and standard deviation against Python's (one channel; all three match)."""
    p, m = python.ravel(), mac[..., 0].ravel()
    return (f"Not pixel for pixel (random): mean {m.mean() / p.mean() - 1:+.1%}, "
            f"standard deviation {m.std() / p.std() - 1:+.1%} of Python's")


def grain_compare(base: np.ndarray) -> Callable[[np.ndarray, np.ndarray], str]:
    """Grain: the noise it adds, output − input, compared like the other stochastic steps."""
    def compare(python: np.ndarray, mac: np.ndarray) -> str:
        p, m = (python - base).reshape(-1, 3), (mac - base).reshape(-1, 3)
        mean = np.abs(m.mean(0) - p.mean(0)).max()
        deviation = np.abs(m.std(0) / p.std(0) - 1).max()
        return (f"Not pixel for pixel (random): grain's RMS within {deviation * 100:.1f} % of Python's, "
                f"mean density within {mean:.2g} (worst channel)")
    return compare


def stage_cases(folder: Path, image: np.ndarray) -> tuple[list[Case], dict, SimulationPipeline, object]:
    """The pipeline's stages, each timed on its own and fed the previous stage's Python output, and the
    whole chain. Their inputs are a golden-style case, `photo/`, the Swift side reads with GoldenCase."""
    params = golden.params_for(FILM, PAPER, False, "photo")
    pipeline = SimulationPipeline(params)
    state = golden.run_all_taps(pipeline, image)  # warm-up
    best: dict[str, float] = {}
    for _ in range(3):
        state = {"rgb_in": image}
        for node in pipeline._topology:
            start = time.perf_counter()
            node.fire(state)
            best[node.label] = min(best.get(node.label, float("inf")), time.perf_counter() - start)

    case_dir = folder / "photo"
    case_dir.mkdir(parents=True)
    for tap, array in state.items():
        np.save(case_dir / f"{tap}.npy", np.asarray(array, dtype=np.float32))
    (case_dir / "params.json").write_text(golden.params_json(
        params, film=FILM, print=PAPER, input="photo", regime="default", taps=list(state),
        pixel_size_um=pipeline._resize_service.pixel_size_um, autoexposure_ev=0.0))

    stages = [("preprocess", "rgb_pre", "Preprocess: input colour space, auto-exposure", "`Simulation.encodePreprocess`"),
              ("filming.expose", "log_e_film", "Filming: expose (spectral upsampling, halation)", "`Simulation.encodeExpose`"),
              ("filming.develop", "cmy_film", "Filming: develop (DIR couplers)", "`Simulation.encodeDevelop`"),
              ("printing.expose", "log_e_print", "Printing: expose (enlarger light, 81 bands)", "`Simulation.encodePrintExpose`"),
              ("printing.develop", "cmy_print", "Printing: develop (print curves)", "`Simulation.encodePrintDevelop`"),
              ("scanning.scan_print", "rgb_out", "Scanning", "`Simulation.encodeScan`")]
    # Below the film's curve, its log exposure only reaches the base density: differences there don't show.
    on_curve = ("on the film's curve", float(params.film.data.log_exposure.min()))
    cases = []
    for label, tap, python, mac in stages:
        case = Case(label, f"{python} (`{label}`)", mac, "Same", run=lambda: None, encoded=tap == "rgb_out",
                    domain=on_curve if tap == "log_e_film" else None)
        case.output, case.seconds = state[tap], best[label]
        cases.append(case)
    for name, python, mac in [("chain", "The whole pipeline (`SimulationPipeline`, the stages' times added)",
                               "`Simulation.encode`, full floats"),
                              ("chain_app", "The whole pipeline, as above",
                               "`Simulation.encode`, half-float intermediates (as the app runs)")]:
        case = Case(name, python, mac, "Same" if name == "chain" else "Different", run=lambda: None, encoded=True)
        case.output, case.seconds = state["rgb_out"], sum(best.values())
        cases.append(case)
    return cases, state, pipeline, params


def step_cases(image: np.ndarray, state: dict, pipeline: SimulationPipeline, params) -> list[Case]:
    pixel_size_um = pipeline._resize_service.pixel_size_um
    rgb_pre, log_e_film, cmy_film, cmy_print = (f32(state[tap]) for tap in ("rgb_pre", "log_e_film", "cmy_film", "cmy_print"))
    point_lights = stars()
    film = load_profile(FILM)
    paper = load_profile(PAPER)
    lut = pipeline._lut_service
    curves = film.data.density_curves - np.nanmin(film.data.density_curves, axis=0)
    axis = f32(np.tile(film.data.log_exposure[:, None], (1, 3)))
    morph = PrintCurvesMorphParams(active=True, gamma_factor=1.2, gamma_factor_fast=0.9, gamma_factor_slow=1.1,
                                   gamma_factor_red=1.05, gamma_factor_green=0.97, gamma_factor_blue=1.02,
                                   developer_exhaustion=0.4)
    uncompressed_params = copy.deepcopy(params)
    uncompressed_params.io.output_gamut_compress = OutputGamutCompressSpec(algorithm="off")
    uncompressed_scanner = SimulationPipeline(uncompressed_params)._scanning_stage
    scanner = pipeline._scanning_stage
    uncompressed = f32(uncompressed_scanner._density_to_rgb(cmy_print, use_lut=False))
    compressed = f32(compress_rgb(uncompressed, params.io.output_gamut_compress, output_color_space=params.io.output_color_space))
    sharpened = f32(scanner._apply_blur_and_unsharp(compressed.copy()))
    enlarger = params.enlarger
    exact_blur = ndimage.gaussian_filter(rgb_pre, (20, 20, 0), mode="nearest", truncate=8)

    def c_max():
        gamut_compression._OUTPUT_CMAX_CACHE.clear()
        return gamut_compression._get_output_c_max_table("cam16ucs", params.io.output_color_space)[2]

    def grain():
        return apply_grain(cmy_film.copy(), pixel_size_um, GrainParams(), curves, film.data.density_curves_layers, film.info.type)

    return [
        Case("auto_exposure", "Auto-exposure, centre-weighted (`measure_autoexposure_ev` on `small_preview`)",
             "`autoExposureEV` (CPU)", "Same",
             lambda: np.array([measure_autoexposure_ev(pipeline._resize_service.small_preview(image), "sRGB", True,
                                                       method="center_weighted")])),
        Case("tc_lut", "Spectral upsampling LUT, 192 × 192 (`compute_hanatos2025_tc_lut`, gamut compressed)",
             "`filmingTCLUT` (CPU, vDSP)", "Same",
             lambda: compute_hanatos2025_tc_lut(lut._film_sensitivity, lut.hanatos2025_adaptation,
                                                gamut_compress=lut.input_gamut_compress)),
        Case("boost", "Highlight boost (`boost_highlights`)", "`GPU.encodeBoostHighlights`", "Same",
             lambda: boost_highlights(rgb_pre * 4, boost_ev=2.0, boost_range=0.3, protect_ev=1.0),
             inputs={"x": rgb_pre * 4}),
        Case("halation", "Halation and scatter, on the stars (`apply_halation_um`)",
             "`GPU.encodeHalation`, its bounces by `MPSImageGaussianBlur`", "Apple's",
             lambda: apply_halation_um(point_lights, params.film_render.halation, pixel_size_um),
             inputs={"x": point_lights}, params={"pixelSizeUm": [pixel_size_um]}),
        Case("diffusion", "Diffusion filter, Black Pro-Mist 1/2, on the stars (`apply_diffusion_filter_um`, f64 FFT)",
             "`GPU.encodeDiffusionFilter`, MPSGraph's f32 FFT", "Apple's",
             lambda: apply_diffusion_filter_um(point_lights, DiffusionFilterParams(active=True, filter_family="black_pro_mist",
                                                                                  strength=0.5), pixel_size_um),
             inputs={"x": point_lights}, params={"pixelSizeUm": [pixel_size_um]}),
        Case("glow_half", "Diffusion filter, CineBloom 2, on the stars, as above",
             "`GPU.encodeDiffusionFilter` at half scale, as on photos past 96 Mi FFT samples", "Different",
             lambda: apply_diffusion_filter_um(point_lights, DiffusionFilterParams(active=True, filter_family="cinebloom",
                                                                                  strength=2.0), pixel_size_um),
             inputs={"x": point_lights}, params={"pixelSizeUm": [pixel_size_um], "maxSamples": [4_000_000]}),
        Case("interp", "Density curves, per channel (`fast_interp`)", "`GPU.encodeInterpolate`", "Same",
             lambda: fast_interp(log_e_film, axis, f32(curves)), inputs={"x": log_e_film},
             params={"axis": axis.ravel().tolist(), "values": f32(curves).ravel().tolist()}),
        Case("blur_mixed", "Gaussian blur, σ 0.6, 2.9, 11 px (`fast_gaussian_filter`: FIR, recursive)",
             "`GPU.encodeGaussianBlur`: FIR, Young–van Vliet", "Same",
             lambda: fast_gaussian_filter(rgb_pre, np.array([0.6, 2.9, 11.0])), inputs={"x": rgb_pre},
             params={"sigma": [0.6, 2.9, 11.0]}),
        Case("blur_equal", "Gaussian blur, σ 20 px in every channel (`fast_gaussian_filter`, recursive)",
             "`MPSImageGaussianBlur`", "Apple's",
             lambda: fast_gaussian_filter(rgb_pre, np.array([20.0, 20.0, 20.0])), inputs={"x": rgb_pre},
             params={"sigma": [20.0, 20.0, 20.0]}, exact=exact_blur),
        Case("blur_exponential", "Exponential blur, decay 2, 9.7, 34 px (`fast_exponential_filter`)",
             "`GPU.encodeExponentialBlur`", "Same",
             lambda: fast_exponential_filter(rgb_pre, np.array([2.0, 9.7, 34.0])), inputs={"x": rgb_pre},
             params={"decay": [2.0, 9.7, 34.0]}),
        Case("grain", "Grain, Portra 400, default settings (`apply_grain`)",
             "`Simulation.encodeGrain` (one Poisson draw, PCG generator)", "Different", grain,
             inputs={"x": cmy_film}, params={"pixelSizeUm": [pixel_size_um]}, compare=grain_compare(cmy_film)),
        Case("enlarger", "Enlarger light at the neutral filters (`EnlargerService.enlarger_filtered_illuminant`)",
             "`enlargerLight` (CPU)", "Same",
             lambda: EnlargerService(enlarger).enlarger_filtered_illuminant(standard_illuminant(enlarger.illuminant))),
        Case("print_curves", "Print curves, every morph control moved (`apply_print_curves_morph`, brentq)",
             "`printCurves` (CPU, bisection)", "Different",
             lambda: apply_print_curves_morph(paper.data.log_exposure, paper.data.density_curves_model, morph,
                                              profile_type=paper.info.type)),
        Case("density_to_rgb", "Scan: density to RGB (`ScanningStage._density_to_rgb`, gamut compression off)",
             "`Simulation.encodeDensityToRGB`", "Same",
             lambda: uncompressed_scanner._density_to_rgb(cmy_print, use_lut=False)),
        Case("c_max", "Output gamut compression's C_max table, 64 × 720 (`_build_polar_perceptual_c_max_table`)",
             "`OutputGamutCompression.init` (CPU, rows in parallel)", "Same", c_max),
        Case("output_compression", "Output gamut compression, CAM16-UCS (`compress_rgb`)",
             "`Simulation.encodeOutputCompression`", "Same",
             lambda: compress_rgb(uncompressed, params.io.output_gamut_compress, output_color_space=params.io.output_color_space),
             inputs={"x": uncompressed}),
        Case("scanner_optics", "Scanner lens blur and unsharp mask (`ScanningStage._apply_blur_and_unsharp`)",
             "`Simulation.encodeScannerOptics`", "Same", lambda: scanner._apply_blur_and_unsharp(compressed.copy()),
             inputs={"x": compressed}),
        Case("output_encoding", "Output transfer function (`ScanningStage._apply_cctf_encoding`)",
             "`Simulation.encodeOutputEncoding`", "Same", lambda: scanner._apply_cctf_encoding(sharpened.copy()),
             inputs={"x": sharpened}, encoded=True),
        Case("glare", "Print glare's random field (`compute_random_glare_amount`)",
             "`Simulation.encodeGlareAmount` (PCG generator)", "Different",
             lambda: compute_random_glare_amount(GlareParams().percent, GlareParams().roughness, GlareParams().blur,
                                                 (HEIGHT, WIDTH)),
             compare=glare_compare),
        Case("preview", "Preview resize to 600 px (`resize_for_preview`: anti-aliasing blur, then bilinear)",
             "`RGBImage.scaledDown` (Core Image's Lanczos)", "Apple's",
             lambda: resize_for_preview(rgb_pre, 600), inputs={"x": rgb_pre}),
    ]


def run_swift(folder: Path, cases: list[Case]) -> dict[str, float]:
    for case in cases:
        case_dir = folder / case.name
        case_dir.mkdir(exist_ok=True)
        for name, array in case.inputs.items():
            np.save(case_dir / f"{name}.npy", np.asarray(array, dtype=np.float32))
    (folder / "cases.json").write_text(json.dumps([{"name": c.name, "params": c.params} for c in cases]))
    env = os.environ | {"SPEKTRA_PORT_REPORT": str(folder), "SPEKTRA_GOLDEN": str(folder)}
    subprocess.run(["swift", "test", "-c", "release", "-Xswiftc", "-enable-testing", "--package-path",
                    str(REPO / "Engine"), "--filter", "portReport"], env=env, check=True)
    return json.loads((folder / "mac.json").read_text())


def run_parity() -> list[list[str]]:
    """The `parity` lines of the tests the films tables read, each split into its fields: test, case,
    check, measured, tolerance, headroom and any extra measurements."""
    tests = ["qaOracleDeltaE"] + [test.split("(")[0] for test, _, _ in SLIDE_STAGES]
    result = subprocess.run(["swift", "test", "-c", "release", "-Xswiftc", "-enable-testing", "--package-path",
                             str(REPO / "Engine"), "--filter", "|".join(tests)], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout[-4000:])
        raise SystemExit("The parity tests failed")
    rows = [line.split(" | ")[1:] for line in result.stdout.splitlines() if line.startswith("parity | ")]
    if not rows:
        raise SystemExit("The parity tests printed nothing: make golden/ with tools/golden.py (see CONTRIBUTING.md)")
    return rows


def films_tables(rows: list[list[str]]) -> str:
    profiles = {path.stem: json.loads(path.read_text())["info"] for path in PROFILES.glob("*.json")}
    commit = json.loads((Path(os.environ.get("SPEKTRA_GOLDEN", REPO / "golden")) / "manifest.json").read_text())[
        "spektrafilmCommit"]
    qa = [row for row in rows if row[0] == "qaOracleDeltaE(pair:)"]
    lines = [f"Measured {date.today().isoformat()} by `tools/port_report.py`, from the parity tests against Spektrafilm "
             f"`{commit[:7]}`'s reference data. Each film printed on its paper: the QA oracle's ΔE2000 on its 50,000 "
             "random sRGB samples, worst first.",
             "",
             "| Film | Paper | ΔE2000 max | p99 | mean |",
             "|---|---|---|---|---|"]
    for row in sorted(qa, key=lambda row: -float(row[3])):
        film, paper = row[1].split("-")
        also = dict(field.split(" ") for field in row[6:])
        lines.append(f"| {profiles[film]['name']} | {profiles[paper]['name']} | {row[3]} | {also['p99']} | {also['mean']} |")
    slides = sorted(stock for stock, info in profiles.items() if info["type"] == "positive")
    lines += ["",
              "Each slide, scanned rather than printed, on the test chart: the largest difference at each stage, in the "
              "stage's own units, and the scan as 8-bit values.",
              "",
              "| Slide | " + " | ".join(name for _, _, name in SLIDE_STAGES) + " | 8-bit |",
              "|---|" + "---|" * (len(SLIDE_STAGES) + 1)]
    for slide in slides:
        case = f"chart-{slide}-scan"
        measured = {(row[0], row[2]): row[3] for row in rows if row[1] == case}
        steps = measured[("chainMatchesPython(caseName:)", "8-bit steps, max")]
        differing = float(measured[("chainMatchesPython(caseName:)", "8-bit values not identical")])
        eight_bit = f"max {steps} level{'' if steps == '1' else 's'}, {100 * (1 - differing):.3f} % identical"
        lines.append(f"| {profiles[slide]['name']} | " + " | ".join(measured[(test, check)] for test, check, _ in SLIDE_STAGES)
                     + f" | {eight_bit} |")
    return "\n".join(lines)


def replaced(text: str, begin: str, end: str, content: str) -> str:
    """`text` with what's between the markers `begin` and `end` replaced by `content`."""
    head, _, rest = text.partition(begin)
    _, _, tail = rest.partition(end)
    return f"{head}{begin}\n{content}\n{end}{tail}"


def difference(case: Case, mac: np.ndarray) -> str:
    python = f32(case.output)
    if case.compare:
        return case.compare(python, mac)
    mac = mac.reshape(python.shape).astype(np.float64)
    error = np.abs(mac - python)
    text = f"max {error.max():.2g}, mean {error.mean():.2g}"
    if case.domain:
        where, lowest = case.domain
        inside = python.min(axis=-1) >= lowest
        text += f" ({where}, log exposure ≥ {lowest:g}: max {error[inside].max():.2g}, mean {error[inside].mean():.2g})"
    if case.exact is not None:
        text += (f"; against an exact Gaussian, Python max {np.abs(python - case.exact).max():.2g}, "
                 f"SpektraMac max {np.abs(mac - case.exact).max():.2g}")
    if case.encoded:
        levels = np.abs(np.round(np.clip(mac, 0, 1) * 255) - np.round(np.clip(python, 0, 1) * 255))
        text += (f"; 8-bit: max {levels.max():.0f} level{'s' if levels.max() != 1 else ''}, "
                 f"{(levels == 0).mean() * 100:.3f} % identical")
    return text


def duration(seconds: float) -> str:
    if seconds >= 1:
        return f"{seconds:.2f} s"
    if seconds >= 1e-3:
        return f"{seconds * 1000:.3g} ms"
    return f"{seconds * 1e6:.3g} µs"


def display(array: np.ndarray, encode: bool, scale: float = 1) -> np.ndarray:
    """8-bit sRGB: linear values (divided by `scale`) encoded with the sRGB curve, encoded ones as they are."""
    array = np.clip(array / scale, 0, 1)
    if encode:
        array = np.where(array <= 0.0031308, 12.92 * array, 1.055 * array ** (1 / 2.4) - 0.055)
    return np.uint8(np.round(array * 255))


def amplified(error: np.ndarray, gain: float) -> np.ndarray:
    return np.uint8(np.round(np.clip(error * gain, 0, 1) * 255))


def window_at(error: np.ndarray) -> tuple[slice, slice]:
    """The CROP × CROP window centred where `error` (smoothed, so not one stray pixel) is largest."""
    smooth = ndimage.uniform_filter(error.max(axis=-1) if error.ndim == 3 else error, 32)
    y, x = np.unravel_index(np.argmax(smooth), smooth.shape)
    top = int(np.clip(y - CROP // 2, 0, error.shape[0] - CROP))
    left = int(np.clip(x - CROP // 2, 0, error.shape[1] - CROP))
    return np.s_[top:top + CROP, left:left + CROP]


def sheet(path: Path, title: str, panels: list[tuple[str, np.ndarray]]):
    """Panels side by side under their labels, each an 8-bit crop of the same size."""
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
    gap, header = 12, 58
    height = panels[0][1].shape[0]
    out = Image.new("RGB", (sum(p.shape[1] for _, p in panels) + gap * (len(panels) - 1), height + header), "white")
    draw = ImageDraw.Draw(out)
    draw.text((0, 4), title, fill="black", font=font)
    x = 0
    for label, panel in panels:
        draw.text((x, 30), label, fill="black", font=font)
        out.paste(Image.fromarray(panel), (x, header))
        x += panel.shape[1] + gap
    out.save(path, optimize=True)


def comparison(path: Path, title: str, python: np.ndarray, mac: np.ndarray, names: tuple[str, str],
               encode: bool, scale: float = 1):
    """Python's and SpektraMac's outputs where they differ most, and their difference amplified."""
    error = np.abs(mac - python)
    window = window_at(error)
    gain = 1 / max(error[window].max(), 1e-12)
    sheet(path, f"{title}: 100 % crops where they differ most",
          [(names[0], display(python[window], encode, scale)), (names[1], display(mac[window], encode, scale)),
           (f"Difference × {gain:.3g} (max {error[window].max():.2g})", amplified(error[window], gain))])


def images(cases: dict[str, Case], macs: dict[str, np.ndarray]):
    IMAGES.mkdir(parents=True, exist_ok=True)
    blur = cases["blur_equal"]
    python_error, mac_error = np.abs(f32(blur.output) - blur.exact), np.abs(macs["blur_equal"] - blur.exact)
    window = window_at(python_error)
    gain = 1 / max(python_error[window].max(), mac_error[window].max())
    sheet(IMAGES / "gaussian-blur.png",
          f"Gaussian blur, σ 20 px, where Python's is furthest off: errors against an exact Gaussian, × {gain:.0f}",
          [("Exact Gaussian (SciPy)", display(blur.exact[window], True)),
           (f"Python's recursive filter: max {python_error[window].max():.2g}", amplified(python_error[window], gain)),
           (f"Apple's Gaussian: max {mac_error[window].max():.2g}", amplified(mac_error[window], gain))])

    comparison(IMAGES / "halation.png", "Halation on the stars", f32(cases["halation"].output), macs["halation"],
               ("Python", "SpektraMac (Apple's blur for the bounces)"), True, scale=4)
    comparison(IMAGES / "half-size-glow.png", "CineBloom 2 on the stars", f32(cases["glow_half"].output), macs["glow_half"],
               ("Python (full-size FFT)", "SpektraMac at half scale"), True, scale=4)
    comparison(IMAGES / "half-floats.png", "The whole pipeline", macs["chain"], macs["chain_app"],
               ("SpektraMac, full floats", "SpektraMac, half floats (the app)"), False)
    comparison(IMAGES / "preview.png", "Preview resize to 600 px", f32(cases["preview"].output), macs["preview"],
               ("Python (skimage)", "SpektraMac (Core Image's Lanczos)"), True)

    # Grain: the noise each side adds, in the photo's smoothest area, where the image's own edges don't show.
    grain = cases["grain"]
    base = grain.inputs["x"]
    rows, columns = np.gradient(base.mean(axis=-1))
    busy = ndimage.uniform_filter(np.abs(rows) + np.abs(columns), CROP)[CROP // 2:-CROP // 2, CROP // 2:-CROP // 2]
    top, left = np.unravel_index(np.argmin(busy), busy.shape)
    window = np.s_[top:top + CROP, left:left + CROP]
    python_noise, mac_noise = f32(grain.output)[window] - base[window], macs["grain"][window] - base[window]
    gain = 0.5 / (3 * python_noise.std())
    sheet(IMAGES / "grain.png", f"Grain on Portra 400: the density each adds, × {gain:.0f} around grey, in the photo's smoothest area",
          [("The negative without grain", np.uint8(np.round(np.clip(10 ** -base[window], 0, 1) * 255))),
           ("Python's grain", np.uint8(np.round(np.clip(0.5 + gain * python_noise, 0, 1) * 255))),
           ("SpektraMac's grain", np.uint8(np.round(np.clip(0.5 + gain * mac_noise, 0, 1) * 255)))])


def table(cases: list[Case], macs: dict[str, np.ndarray], mac_seconds: dict[str, float]) -> str:
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    memory = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30
    lines = [f"Measured {date.today().isoformat()} on an {chip} with {memory} GB, macOS {platform.mac_ver()[0]}, "
             f"against Spektrafilm `{golden.installed_commit()[:7]}` with NumPy {version('numpy')}, SciPy "
             f"{version('scipy')} and Numba {version('numba')}, by `tools/port_report.py`. Python runs on the CPU "
             "(Numba-compiled where Spektrafilm uses it), SpektraMac on the GPU unless it says CPU; both on the "
             f"same input, {WIDTH} × {HEIGHT} unless the step says otherwise, best of 3 runs (Python) and 5 "
             "(SpektraMac) after a warm-up run. The stages run at full floats, each fed Python's output of the "
             "stage before. Steps that work in place time a copy of their input too. Difference: SpektraMac's "
             "output against Python's, absolute, in the step's own units (EV, density, linear or encoded RGB).",
             "",
             "| Spektrafilm | SpektraMac | Method | Python | SpektraMac | Faster | Difference |",
             "|---|---|---|---|---|---|---|"]
    for case in cases:
        mac = mac_seconds[case.name]
        lines.append(f"| {case.python} | {case.mac} | {case.method} | {duration(case.seconds)} | {duration(mac)} "
                     f"| {case.seconds / mac:,.0f}× | {difference(case, macs[case.name])} |")
    return "\n".join(lines)


def main():
    installed = golden.installed_commit()
    if installed != golden.REFERENCE_COMMIT:
        raise SystemExit(f"Need spektrafilm at commit {golden.REFERENCE_COMMIT}, found {installed or 'an install not from git'}")
    image = photo()
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        stages, state, pipeline, params = stage_cases(folder, image)
        steps = step_cases(image, state, pipeline, params)
        for case in steps:
            case.output, case.seconds = best_of(case.run)
            print(f"{case.name}: {duration(case.seconds)}")
        cases = stages + steps
        mac_seconds = run_swift(folder, cases)
        macs = {case.name: np.load(folder / case.name / "mac.npy").astype(np.float64) for case in cases}
    by_name = {case.name: case for case in cases}
    images(by_name, macs)
    films = films_tables(run_parity())
    text = replaced(DOC.read_text(), BEGIN, END, table(cases, macs, mac_seconds))
    DOC.write_text(replaced(text, FILMS_BEGIN, FILMS_END, films))
    print(f"Wrote {DOC.relative_to(REPO)} and {IMAGES.relative_to(REPO)}/")


if __name__ == "__main__":
    main()
