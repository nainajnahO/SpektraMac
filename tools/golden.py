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

Pairs: Portra 400 -> Portra Endura, Vision3 500T -> 2383, and scanned directly (scan_film): Velvia 100
(a slide) and Portra 400 (the negative itself).

primitives/ holds per-pixel kernel cases on 64x64x3 float32 inputs, with references computed in
float64 by the Python functions themselves from those same float32 inputs (so only the kernel's
own error shows): curve interpolation (numba fast_interp) on a negative film's exposure axis and on
a positive film's non-monotonic -density axis, log10(max(x, 0) + 1e-10), 10**x and a 3x3 matrix;
and blurs (fast_gaussian_filter, fast_exponential_filter) with per-channel sigmas covering the FIR
path, the IIR path, a mix, and an image smaller than the kernel, with `<name>_sigma` alongside; and each film's
hanatos2025 tc LUT before input gamut compression (`tc_lut_raw_<film>`, 192x192x3); and on that LUT's
own cell grid, the input gamut compression's normalised distance to the spectral locus around D55
and T (`locus_dnorm_<illuminant>`) and matplotlib's inside/outside test (`locus_inside`); highlight
boost (`boost`: boost_ev 2, range 0.3, protect 1) and Portra 400's digested halation + scatter at a
5 um pixel (`halation`, 24 MP scale, so the blurs take the IIR path too); and per printed film the
enlarger light at the digested neutral filters (`enlarger_<film>`), with M +12 / Y -7 shifts
(`enlarger_shifted_<film>`) and the preflash light with M +5 / Y -3 (`preflash_<film>`); and the
Portra chart re-run with print exposure 1.3, exposure compensation +0.7 EV balanced at the
enlarger, and a 0.3 preflash with M +5 / Y -3 (`print_variant_cmy_film`, `print_variant_log_e_print`);
and each paper's print curves from its fitted model, plain (`print_curves_<paper>`) and with every
morph control moved, developer exhaustion 0.4 included (`print_curves_morphed_<paper>`); and CAM16-UCS
as the output gamut compression calls it (L_A 64, Y_b 20, Average surround, the output space's white
at Y = 1), around the sRGB and ProPhoto RGB whites: forward on XYZ of random linear RGB in
[-0.25, 1.5] with a row in [-1, 3] and black, white and 1e-6 grey first (`cam16ucs_xyz_<space>` ->
`cam16ucs_jab_<space>`), and inverse on those J'a'b' with chroma scaled by 0.7 plus a row with J' up
to 130 and |a'|, |b'| up to 100 (`cam16ucs_inverse_jab_<space>` -> `cam16ucs_inverse_xyz_<space>`); and
the cam16ucs output gamut compression for the same two spaces: its C_max(J', h') table
(`cmax_cam16ucs_<space>`, 64x720) and random linear RGB in [-0.3, 1.6] with black, white, 2x white,
1e-6 grey, the primaries and an out-of-gamut red first (`output_compress_x_<space>`), compressed with
the default spec (`output_compress_out_<space>`) and with knee (0.2, 1.1, 4) and no lightness
compression (`output_compress_variant_out_<space>`); and print glare with the default parameters
on a 512x512 frame, blurred (`glare_amount`) and not (`glare_amount_unblurred`), drawn with NumPy's
generator seeded 20260515 in place of numba's.

qa-<film>-<paper>/ holds the LUT creator's QA oracle (spektrafilm_lut_creator.qa.reference, the 50k
random sRGB samples of seed 20260515 through the pipeline in lut_mode, linear in and out) for each
printed pair: the linear input samples after its input gain (samples.npy, 200x250x3), the oracle's output as XYZ the way
its ΔE2000 metric reads it (reference_xyz.npy: encoded, clipped to [0, 1], decoded, to XYZ) and
params.json.

Each case directory holds one float32 .npy per pipeline tap that exists for it (rgb_in, rgb_pre,
log_e_film, cmy_film, [log_e_print, cmy_print,] rgb_out), the filming tc LUT the run used
(tc_lut.npy, 192x192x3), the film density from the run's log_e_film without DIR couplers
(cmy_film_no_couplers.npy, develop_simple on the normalised curves), the scanned RGB before output
gamut compression, blur, unsharp mask and encoding (rgb_uncompressed.npy, the scanning stage's
_density_to_rgb with compression off), that RGB through the run's output gamut compression
(rgb_compressed.npy, from its float32 values), for the Portra chart also the scan of its float32
cmy_print into each other output space (rgb_out_<space>.npy, spaces as file names: DCI-P3,
Display_P3, Adobe_RGB_1998, ITU-R_BT.2020, ProPhoto_RGB, ACES2065-1), and params.json: the digested parameters (profiles by stock name only),
pixel_size_um, the measured auto-exposure EV and the tap list.
"""

from __future__ import annotations

import copy
import dataclasses
import hashlib
import json
from importlib.metadata import version
from pathlib import Path

import colour
import numpy as np
import skimage.data

from spektrafilm import digest_params, init_params
from spektrafilm_lut_creator.bundles import Bundle, BundleSpec
from spektrafilm_lut_creator.color_spaces import to_xyz_qa
from spektrafilm_lut_creator.qa import reference as qa_reference
from spektrafilm.model.develop import develop_simple
from spektrafilm.profiles.io import load_profile
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.services import EnlargerService
from spektrafilm.model import glare as glare_module
from spektrafilm.model.diffusion import apply_halation_um
from spektrafilm.runtime.params_schema import GlareParams
from spektrafilm.utils import fast_stats
from spektrafilm.utils.numba_boost_hightlights import boost_highlights
from spektrafilm.utils.fast_gaussian_filter import fast_exponential_filter, fast_gaussian_filter
from spektrafilm.utils.fast_interp import fast_interp
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec, compress_rgb
from spektrafilm.utils.morph_curves import PrintCurvesMorphParams, apply_print_curves_morph
from matplotlib.path import Path as MplPath
from spektrafilm.utils.gamut_compression import (
    _CAM16UCS_L_A,
    _CAM16UCS_Y_B,
    _get_output_c_max_table,
    _output_cs_whitepoint_xyz,
    _ray_polygon_distance,
    spectral_locus_xy,
)
from spektrafilm.utils.spectral_upsampling import _illuminant_to_xy, _quad2tri, compute_hanatos2025_tc_lut
from spektrafilm.utils.autoexposure import measure_autoexposure_ev

REFERENCE_VERSION = "0.3.4"
OUT = Path(__file__).resolve().parent.parent / "golden"
OTHER_OUTPUT_SPACES = ["DCI-P3", "Display P3", "Adobe RGB (1998)", "ITU-R BT.2020", "ProPhoto RGB", "ACES2065-1"]


def space_file_name(space: str) -> str:
    return space.replace(" ", "_").replace("(", "").replace(")", "")


PAIRS = [
    ("kodak_portra_400", "kodak_portra_endura", False),
    ("kodak_vision3_500t", "kodak_2383", False),
    # Scanned directly (a slide, and a negative viewed as such); the print profile is required by
    # the API but unused.
    ("fujifilm_velvia_100", "kodak_portra_endura", True),
    ("kodak_portra_400", "kodak_portra_endura", True),
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


def params_json(params, **info) -> str:
    """A case's params.json: `info`, then the digested parameters (profiles by stock name only)."""
    info["params"] = {f.name: to_jsonable(getattr(params, f.name))
                      for f in dataclasses.fields(params) if f.name not in ("film", "print")}
    return json.dumps(info, indent=1)


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
    for film in dict.fromkeys(film for film, _, _ in PAIRS):
        profile = load_profile(film)
        adaptation = profile.hanatos2025_adaptation()
        adaptation.apply_window, adaptation.apply_surface = True, False
        sensitivity = np.nan_to_num(10 ** profile.data.log_sensitivity)
        arrays[f"tc_lut_raw_{film}"] = compute_hanatos2025_tc_lut(sensitivity, adaptation, gamut_compress=None)

    # remap_tc_lut_for_compression's cell grid, decoded to xy as it does.
    cells = np.arange(192) / 191
    xy = _quad2tri(np.stack(np.meshgrid(cells, cells, indexing="ij"), axis=-1))
    locus = spectral_locus_xy()
    for illuminant in ("D55", "T"):
        white = _illuminant_to_xy(illuminant)
        delta = xy - white
        dist = np.linalg.norm(delta, axis=-1)
        direction = delta / np.fmax(dist, 1e-12)[..., None]
        boundary = _ray_polygon_distance(white, direction, locus)
        arrays[f"locus_dnorm_{illuminant}"] = dist / np.fmax(boundary, 1e-12)
    arrays["locus_inside"] = MplPath(locus).contains_points(xy.reshape(-1, 2)).reshape(192, 192)

    x = image(0.0, 3.0)
    arrays.update(boost_x=x, boost_out=boost_highlights(x, boost_ev=2.0, boost_range=0.3, protect_ev=1.0))
    halation = digest_params(init_params("kodak_portra_400", "kodak_portra_endura")).film_render.halation
    x = rng.uniform(0, 2, (96, 128, 3)).astype(np.float32).astype(np.float64)
    arrays.update(halation_x=x, halation_out=apply_halation_um(x, halation, 5.0))

    for film, paper, scan_film in PAIRS:
        if scan_film:
            continue
        enlarger = digest_params(init_params(film, paper)).enlarger
        light = standard_illuminant(enlarger.illuminant)
        arrays[f"enlarger_{film}"] = EnlargerService(enlarger).enlarger_filtered_illuminant(light)
        enlarger.m_filter_shift, enlarger.y_filter_shift = 12.0, -7.0
        enlarger.preflash_m_filter_shift, enlarger.preflash_y_filter_shift = 5.0, -3.0
        arrays[f"enlarger_shifted_{film}"] = EnlargerService(enlarger).enlarger_filtered_illuminant(light)
        arrays[f"preflash_{film}"] = EnlargerService(enlarger).preflash_filtered_illuminant(light)

    params = params_for("kodak_portra_400", "kodak_portra_endura", False, "chart")
    params.enlarger.print_exposure = 1.3
    params.enlarger.print_exposure_compensation = True
    params.camera.exposure_compensation_ev = 0.7
    params.enlarger.preflash_exposure = 0.3
    params.enlarger.preflash_m_filter_shift, params.enlarger.preflash_y_filter_shift = 5.0, -3.0
    taps = run_all_taps(SimulationPipeline(params), make_chart())
    arrays.update(print_variant_cmy_film=taps["cmy_film"], print_variant_log_e_print=taps["log_e_print"])

    morph = PrintCurvesMorphParams(active=True, gamma_factor=1.2, gamma_factor_fast=0.9, gamma_factor_slow=1.1,
                                   gamma_factor_red=1.05, gamma_factor_green=0.97, gamma_factor_blue=1.02,
                                   developer_exhaustion=0.4)
    for paper in ("kodak_portra_endura", "kodak_2383"):
        data, kind = load_profile(paper).data, load_profile(paper).info.type
        for name, params in (("print_curves", PrintCurvesMorphParams(active=False)), ("print_curves_morphed", morph)):
            arrays[f"{name}_{paper}"] = apply_print_curves_morph(
                data.log_exposure, data.density_curves_model, params, profile_type=kind)

    # CAM16-UCS exactly as compress_rgb_cam16ucs_chroma calls it, around the output space's white.
    for space in ("sRGB", "ProPhoto RGB"):
        suffix = space.split()[0]
        cam16 = dict(XYZ_w=_output_cs_whitepoint_xyz(space), L_A=_CAM16UCS_L_A, Y_b=_CAM16UCS_Y_B)
        rgb = rng.uniform(-0.25, 1.5, (64, 64, 3))
        rgb[1] = rng.uniform(-1.0, 3.0, (64, 3))
        rgb[0, :3] = [[0.0] * 3, [1.0] * 3, [1e-6] * 3]
        xyz = colour.RGB_to_XYZ(rgb, colourspace=space, illuminant=colour.RGB_COLOURSPACES[space].whitepoint,
                                apply_cctf_decoding=False).astype(np.float32).astype(np.float64)
        jab = colour.XYZ_to_CAM16UCS(xyz, **cam16)
        inverse_jab = jab * [1.0, 0.7, 0.7]
        inverse_jab[1] = rng.uniform([0.0, -100.0, -100.0], [130.0, 100.0, 100.0], (64, 3))
        inverse_jab = inverse_jab.astype(np.float32).astype(np.float64)
        arrays.update({f"cam16ucs_xyz_{suffix}": xyz, f"cam16ucs_jab_{suffix}": jab,
                       f"cam16ucs_inverse_jab_{suffix}": inverse_jab,
                       f"cam16ucs_inverse_xyz_{suffix}": colour.CAM16UCS_to_XYZ(inverse_jab, **cam16)})

    # Python's glare with its numba RNG (per-thread, not seedable from here) swapped for NumPy's
    # seeded one, so the field is reproducible.
    glare = GlareParams()
    saved = glare_module.fast_lognormal_from_mean_std, fast_stats.fast_lognormal
    glare_module.fast_lognormal_from_mean_std = fast_stats.fast_lognormal_from_mean_std.py_func
    fast_stats.fast_lognormal = fast_stats.fast_lognormal.py_func
    try:
        np.random.seed(20260515)
        arrays["glare_amount"] = glare_module.compute_random_glare_amount(
            glare.percent, glare.roughness, glare.blur, (512, 512))
        arrays["glare_amount_unblurred"] = glare_module.compute_random_glare_amount(
            glare.percent, glare.roughness, 0.0, (512, 512))
    finally:
        glare_module.fast_lognormal_from_mean_std, fast_stats.fast_lognormal = saved

    # Output gamut compression (cam16ucs): the C_max(J', h') table and compressed samples.
    for space in ("sRGB", "ProPhoto RGB"):
        suffix = space.split()[0]
        arrays[f"cmax_cam16ucs_{suffix}"] = _get_output_c_max_table("cam16ucs", space)[2]
        x = rng.uniform(-0.3, 1.6, (64, 64, 3))
        x[0, :8] = [[0, 0, 0], [1, 1, 1], [2, 2, 2], [1e-6] * 3, [1, 0, 0], [0, 1, 0], [0, 0, 1], [1.2, -0.1, -0.1]]
        x = x.astype(np.float32).astype(np.float64)
        variant = OutputGamutCompressSpec(knee=(0.2, 1.1, 4.0), lightness_compression=None)
        arrays.update({f"output_compress_x_{suffix}": x,
                       f"output_compress_out_{suffix}": compress_rgb(x, OutputGamutCompressSpec(), output_color_space=space),
                       f"output_compress_variant_out_{suffix}": compress_rgb(x, variant, output_color_space=space)})
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
            curves = params.film.data.density_curves
            no_couplers = develop_simple(taps["log_e_film"], params.film.data.log_exposure,
                                         curves - np.nanmin(curves, axis=0),
                                         gamma_factor=params.film_render.density_curve_gamma)
            uncompressed_params = copy.deepcopy(params)
            uncompressed_params.io.output_gamut_compress = OutputGamutCompressSpec(algorithm="off")
            scanner = SimulationPipeline(uncompressed_params)._scanning_stage
            uncompressed = scanner._density_to_rgb(taps["cmy_film" if scan_film else "cmy_print"], use_lut=False)
            # From the float32 values the Swift tests read, so both sides compress the same input.
            compressed = compress_rgb(np.float32(uncompressed).astype(np.float64), params.io.output_gamut_compress,
                                      output_color_space=params.io.output_color_space)
            arrays = dict(taps, tc_lut=pipeline._lut_service.filming_tc_lut_memory,
                          cmy_film_no_couplers=no_couplers, rgb_uncompressed=uncompressed,
                          rgb_compressed=compressed)
            if case == "chart-kodak_portra_400-kodak_portra_endura":
                # The scan into every other output space, from the float32 cmy_print.
                for space in OTHER_OUTPUT_SPACES:
                    variant = copy.deepcopy(params)
                    variant.io.output_color_space = space
                    scanner = SimulationPipeline(variant)._scanning_stage
                    arrays[f"rgb_out_{space_file_name(space)}"] = scanner.scan(
                        np.float32(taps["cmy_print"]).astype(np.float64))
            for name, array in arrays.items():
                np.save(case_dir / f"{name}.npy", np.asarray(array, dtype=np.float32))

            (case_dir / "params.json").write_text(params_json(
                params, film=film, print=None if scan_film else paper, input=input_name,
                regime="lut_mode" if input_name == "chart" else "default", taps=list(taps),
                pixel_size_um=pipeline._resize_service.pixel_size_um, autoexposure_ev=float(autoexposure_ev)))

            for path in sorted(case_dir.iterdir()):
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                manifest["files"][f"{case}/{path.name}"] = digest
            print(f"{case}: {', '.join(taps)}")

    # The LUT creator's QA oracle for each printed pair: its 50k random sRGB samples through the
    # pipeline in lut_mode, linear in and out (qa.reference._compute with the default bundle spec:
    # the samples carry its input gain, white 4 stops over grey; the SDR output's gain is 1).
    for film, paper, scan_film in PAIRS:
        if scan_film:
            continue
        spec = BundleSpec(film_profile=film, print_profiles=(paper,), input_color_space="sRGB",
                          output_color_space="sRGB")
        frame = spec.bake_frame()
        assert frame.output_gain == 1
        oracle = qa_reference._compute(spec, Bundle(), 0, n_samples=qa_reference.DEFAULT_OFFGRID_SAMPLES,
                                       rng_seed=qa_reference.DEFAULT_RNG_SEED)
        # Its params, rebuilt as it builds them; checked by rerunning.
        params = init_params(film, paper)
        params.debug.lut_mode = True
        params.io.input_color_space = params.io.output_color_space = "sRGB"
        params.io.input_cctf_decoding = params.io.output_cctf_encoding = False
        params = digest_params(params)
        pipeline = SimulationPipeline(params)
        rerun = np.asarray(pipeline.process(oracle.rng_samples_linear.reshape(1, -1, 3)), dtype=float)
        assert np.array_equal(rerun.reshape(-1, 3), oracle.pipeline_out_linear)

        case = f"qa-{film}-{paper}"
        case_dir = OUT / case
        case_dir.mkdir(parents=True, exist_ok=True)
        np.save(case_dir / "samples.npy", oracle.rng_samples_linear.reshape(200, 250, 3))
        np.save(case_dir / "reference_xyz.npy",
                np.float32(to_xyz_qa(oracle.pipeline_out_encoded, "sRGB")).reshape(200, 250, 3))
        (case_dir / "params.json").write_text(params_json(
            params, film=film, print=paper, input="qa", regime="lut_mode", taps=[],
            pixel_size_um=pipeline._resize_service.pixel_size_um, autoexposure_ev=0.0))
        for path in sorted(case_dir.iterdir()):
            manifest["files"][f"{case}/{path.name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{case}: {len(oracle.rng_samples_linear)} samples")

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
