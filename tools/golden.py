"""Generate golden reference data from Python Spektrafilm for the Swift parity tests.

Run with the interpreter of the pinned Spektrafilm install:

    uv tool install spektrafilm==0.3.4
    ~/.local/share/uv/tools/spektrafilm/bin/python tools/golden.py

Writes golden/<case>/ (gitignored) and golden/manifest.json (committed; sha256 of every file, so a
regeneration that changes anything shows up in `git diff`).

Inputs
- chart: 256x384 linear ProPhoto RGB (the default input space, no CCTF decoding). Rows 0-63 a grey
  ramp of 24 steps from 0.184*2^-8 to 0.184*2^4; rows 64-191 a 24x8 grid of 16 px patches (24 hues x
  4 saturations x 2 values); rows 192-255 uniform random colours in [0, 1] (seed 20260515).
- photo: scikit-image's `astronaut` (512x512, NASA, public domain) as sRGB-encoded floats in [0, 1],
  fed with input_color_space="sRGB" and input_cctf_decoding=True.

Regimes (stochastic effects are always off: no grain, no glare)
- chart runs with debug.lut_mode=True: a pure per-pixel transform (no spatial effects, no
  auto-exposure, no highlight boost, no scanner corrections). Target for the per-pixel kernels.
- photo runs with the default settings: spatial effects (halation, DIR diffusion, unsharp mask) and
  centre-weighted auto-exposure on. Target for the spatial stages and the end-to-end check.

Pairs: Portra 400 -> Portra Endura, Vision3 500T -> 2383, Velvia 100 scanned directly (scan_film).

primitives/ holds per-pixel kernel cases on 64x64x3 float32 inputs, with references computed in
float64 by the Python functions themselves from those same float32 inputs (so only the kernel's
own error shows): curve interpolation (numba fast_interp) on a negative film's exposure axis and on
a positive film's non-monotonic -density axis, log10(max(x, 0) + 1e-10), 10**x and a 3x3 matrix;
and blurs (fast_gaussian_filter, fast_exponential_filter) with per-channel sigmas covering the FIR
path, the IIR path, a mix, and an image smaller than the kernel, with `<name>_sigma` alongside; and each film's
hanatos2025 tc LUT before input gamut compression (`tc_lut_raw_<film>`, 192x192x3).

Each case directory holds one float32 .npy per pipeline tap that exists for it (rgb_in, rgb_pre,
log_e_film, cmy_film, [log_e_print, cmy_print,] rgb_out), the filming tc LUT the run used
(tc_lut.npy, 192x192x3), and params.json: the digested parameters (profiles by stock name only),
pixel_size_um, the measured auto-exposure EV and the tap list.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
from importlib.metadata import version
from pathlib import Path

import colour
import numpy as np
import skimage.data

from spektrafilm import digest_params, init_params
from spektrafilm.profiles.io import load_profile
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.fast_gaussian_filter import fast_exponential_filter, fast_gaussian_filter
from spektrafilm.utils.fast_interp import fast_interp
from spektrafilm.utils.spectral_upsampling import compute_hanatos2025_tc_lut
from spektrafilm.utils.autoexposure import measure_autoexposure_ev

REFERENCE_VERSION = "0.3.4"
OUT = Path(__file__).resolve().parent.parent / "golden"
PAIRS = [
    ("kodak_portra_400", "kodak_portra_endura", False),
    ("kodak_vision3_500t", "kodak_2383", False),
    # Slides are viewed directly; the print profile is required by the API but unused.
    ("fujifilm_velvia_100", "kodak_portra_endura", True),
]


def make_chart() -> np.ndarray:
    chart = np.zeros((256, 384, 3))
    ramp = 0.184 * 2.0 ** np.linspace(-8, 4, 24)
    chart[0:64] = np.repeat(ramp, 16)[None, :, None]

    hues = np.arange(24) / 24
    for row, (saturation, value) in enumerate(
        (s, v) for v in (0.1, 0.6) for s in (0.25, 0.5, 0.75, 1.0)
    ):
        hsv = np.stack([hues, np.full(24, saturation), np.full(24, value)], axis=-1)
        rgb = colour.HSV_to_RGB(hsv)
        y0 = 64 + 16 * row
        chart[y0:y0 + 16] = np.repeat(rgb, 16, axis=0)[None, :, :]

    chart[192:256] = np.random.default_rng(20260515).uniform(0, 1, (64, 384, 3))
    return chart


def make_photo() -> np.ndarray:
    return skimage.data.astronaut().astype(np.float64) / 255


def params_for(film: str, paper: str, scan_film: bool, input_name: str):
    params = init_params(film, paper)
    params.io.scan_film = scan_film
    params.debug.deactivate_stochastic_effects = True
    if input_name == "chart":
        params.debug.lut_mode = True
    else:
        params.io.input_color_space = "sRGB"
        params.io.input_cctf_decoding = True
    return digest_params(params)


def run_all_taps(pipeline: SimulationPipeline, image: np.ndarray) -> dict[str, np.ndarray]:
    # Same walk as runtime.topology.run_topology, but keeping every tap instead of one.
    state = {"rgb_in": image}
    for node in pipeline._topology:
        if all(k in state for k in node.reads):
            node.fire(state)
    return state


def to_jsonable(value):
    if dataclasses.is_dataclass(value):
        return {f.name: to_jsonable(getattr(value, f.name)) for f in dataclasses.fields(value)}
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, (np.floating, np.integer, np.bool_)):
        return value.item()
    if isinstance(value, (tuple, list)):
        return [to_jsonable(v) for v in value]
    return value


def primitives() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(20260515)

    def image(low, high):
        return rng.uniform(low, high, (64, 64, 3)).astype(np.float32).astype(np.float64)

    arrays = {}
    negative = load_profile("kodak_portra_400").data
    curves = negative.density_curves - np.nanmin(negative.density_curves, axis=0)
    axis = np.tile(negative.log_exposure[:, None], (1, 3)).astype(np.float32).astype(np.float64)
    values = curves.astype(np.float32).astype(np.float64)
    x = image(-3.5, 4.5)
    x[0, :, :] = axis[::4][:64]  # exact nodes: np.interp's right-biased matches
    arrays.update(interp_negative_x=x, interp_negative_axis=axis, interp_negative_values=values,
                  interp_negative_out=fast_interp(x, axis, values))

    positive = load_profile("fujifilm_velvia_100").data
    axis = (-positive.density_curves).astype(np.float32).astype(np.float64)
    values = np.tile(positive.log_exposure[:, None], (1, 3)).astype(np.float32).astype(np.float64)
    x = image(-4.0, 0.5)
    arrays.update(interp_positive_x=x, interp_positive_axis=axis, interp_positive_values=values,
                  interp_positive_out=fast_interp(x, axis, values))

    x = image(-0.5, 20.0)
    x[0, :8, :] = 0.0
    x[1, :8, :] = 1e-12
    arrays.update(log10_x=x, log10_out=np.log10(np.fmax(x, 0.0) + 1e-10))

    x = image(-4.0, 4.0)
    arrays.update(pow10_x=x, pow10_out=10**x)

    matrix = colour.RGB_COLOURSPACES["ProPhoto RGB"].matrix_RGB_to_XYZ.astype(np.float32).astype(np.float64)
    x = image(-0.2, 2.0)
    arrays.update(matmul_x=x, matmul_matrix=matrix, matmul_out=np.einsum("ijk,lk->ijl", x, matrix))

    # Blurs: random pixels (worst case for edges and rounding) on a non-square image.
    blur_cases = {
        "blur_fir": ((96, 128), (0.6, 1.3, 2.9)),
        "blur_iir": ((96, 128), (3.0, 11.0, 40.0)),
        "blur_mixed": ((96, 128), (0.0, 2.0, 7.5)),
        "blur_wide": ((96, 128), (100.0, 100.0, 100.0)),
        "blur_tiny": ((6, 8), (2.9, 1.0, 0.4)),
    }
    for name, (shape, sigma) in blur_cases.items():
        x = rng.uniform(0, 1, (*shape, 3)).astype(np.float32).astype(np.float64)
        arrays.update({f"{name}_x": x, f"{name}_sigma": np.array(sigma),
                       f"{name}_out": fast_gaussian_filter(x, np.array(sigma))})
    x = rng.uniform(0, 1, (96, 128, 3)).astype(np.float32).astype(np.float64)
    decay = np.array([2.0, 9.7, 34.0])
    arrays.update(blur_exponential_x=x, blur_exponential_sigma=decay,
                  blur_exponential_out=fast_exponential_filter(x, decay))

    # As FilmingStage builds it with the default settings (window on, surface off, no blur).
    for film, _, _ in PAIRS:
        profile = load_profile(film)
        adaptation = profile.hanatos2025_adaptation()
        adaptation.apply_window, adaptation.apply_surface = True, False
        sensitivity = np.nan_to_num(10 ** profile.data.log_sensitivity)
        arrays[f"tc_lut_raw_{film}"] = compute_hanatos2025_tc_lut(sensitivity, adaptation, gamut_compress=None)
    return arrays


def main():
    installed = version("spektrafilm")
    if installed != REFERENCE_VERSION:
        raise SystemExit(f"Need spektrafilm {REFERENCE_VERSION}, found {installed}")

    inputs = {"chart": make_chart(), "photo": make_photo()}
    manifest = {
        "versions": {name: version(name) for name in
                     ("spektrafilm", "numpy", "scipy", "colour-science", "scikit-image")},
        "files": {},
    }

    for film, paper, scan_film in PAIRS:
        for input_name, image in inputs.items():
            case = f"{input_name}-{film}-{'scan' if scan_film else paper}"
            params = params_for(film, paper, scan_film, input_name)
            pipeline = SimulationPipeline(params)
            taps = run_all_taps(pipeline, image)

            # The exact value the pipeline applies in preprocess (0 when auto-exposure is off).
            autoexposure_ev = 0.0
            if params.camera.auto_exposure:
                autoexposure_ev = measure_autoexposure_ev(
                    pipeline._resize_service.small_preview(image),
                    params.io.input_color_space,
                    params.io.input_cctf_decoding,
                    method=params.camera.auto_exposure_method,
                )

            case_dir = OUT / case
            case_dir.mkdir(parents=True, exist_ok=True)
            arrays = dict(taps, tc_lut=pipeline._lut_service.filming_tc_lut_memory)
            for name, array in arrays.items():
                np.save(case_dir / f"{name}.npy", np.asarray(array, dtype=np.float32))

            info = {
                "film": film,
                "print": None if scan_film else paper,
                "input": input_name,
                "regime": "lut_mode" if input_name == "chart" else "default",
                "taps": list(taps),
                "pixel_size_um": pipeline._resize_service.pixel_size_um,
                "autoexposure_ev": float(autoexposure_ev),
                "params": {
                    f.name: to_jsonable(getattr(params, f.name))
                    for f in dataclasses.fields(params)
                    if f.name not in ("film", "print")
                },
            }
            (case_dir / "params.json").write_text(json.dumps(info, indent=1))

            for path in sorted(case_dir.iterdir()):
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                manifest["files"][f"{case}/{path.name}"] = digest
            print(f"{case}: {', '.join(taps)}")

    primitives_dir = OUT / "primitives"
    primitives_dir.mkdir(parents=True, exist_ok=True)
    for name, array in primitives().items():
        path = primitives_dir / f"{name}.npy"
        np.save(path, np.asarray(array, dtype=np.float32))
        manifest["files"][f"primitives/{path.name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"primitives: {len(list(primitives_dir.iterdir()))} arrays")

    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
