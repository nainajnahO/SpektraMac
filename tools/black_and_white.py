# /// script
# requires-python = "==3.13.*"
# dependencies = [
#     "spektrafilm @ git+https://github.com/andreavolpato/spektrafilm@6cd00c8d4f30b5b550f50f4bbd3753c9f2a48507",
# ]
# ///
"""Black-and-white film: its data and its reference data, from Spektrafilm's `dev` branch at 6cd00c8.

SpektraMac ports Spektrafilm's `main` at 3bb2c2d (tools/export_tables.py, tools/golden.py), which has
no black-and-white film. `dev` has three one-layer stocks: Kodak Double-X 5222, Tri-X Reversal 7266 and
the print film 2302. This script brings those three and nothing else of `dev`:

    uv run tools/black_and_white.py

uv installs the commit named above into an environment of its own; the pinned install of `main` stays
as it is. Run it after tools/export_tables.py, which rewrites the neutral print filters without the
entries added here, and after tools/golden.py, whose Portra 400 cases it reads. With
`--resources <folder>` it only adds the bundled data to that folder (tools/check-upstream.sh).

Bundled data (Engine/Sources/SpektraEngine/Resources/, committed)
- profiles/kodak_doublex.json, kodak_trix.json, kodak_2302.json: copied unchanged (CC BY-SA 4.0).
- neutral_print_filters.json: dev's entries for those stocks, as the film or as the print. Every
  other entry stays main's (dev refitted the colour ones).

Reference data (golden/<case>/, gitignored, and golden/manifest-bw.json, committed: the commit and a
sha256 of every file)
`dev` renders through newer steps than the engine ports, so every run here pins them to the engine's
(`pinned`): the film's exposure as given (dev meters the film's raw exposure, main the scene), DIR
couplers linear with main's strengths and diffusion tail (dev saturates them, with refitted
strengths), the CAM16-UCS output gamut compression (dev's default is OkLCh), no chemistry morph, the
bundled neutral print filters, and a colour film's density curves as stored (dev samples them from
the fitted model; a one-layer stock's stored curves are that sampling to 2e-15). Stochastic effects
are off, as in tools/golden.py.

Before writing anything, the pins are checked: Portra 400 -> Portra Endura, pinned, must come out as
main's own reference data for it (`check_pins`), chart and photo. A pin that's missing or wrong, or a
change in dev that none of them covers, stops the script there.

Cases, named as tools/golden.py names them. The chart is that script's (its `rgb_in`), run per pixel
(`lut_mode`); the photo is its astronaut as main exposed it (its `rgb_pre`, auto-exposure applied),
with the spatial effects on.
- chart-kodak_doublex-kodak_2302: the negative on the print film, both at their standard development.
- chart-kodak_doublex-kodak_2302-developed_8_2.5: asked for 8 and 2.5 minutes, which are developed
  as the nearest measured ones, 9 and 2.
- chart-kodak_doublex-kodak_portra_endura: a one-layer negative on a colour paper.
- chart-kodak_doublex-scan, chart-kodak_trix-scan: the negative and the reversal film, scanned.
- chart-kodak_portra_400-kodak_2302: a colour negative on the one-layer print film.
- photo-kodak_doublex-kodak_2302.
Each holds one float32 .npy per pipeline tap (rgb_pre, log_e_film, cmy_film, [log_e_print, cmy_print,]
rgb_out) and the filming tc LUT (tc_lut). A one-layer stock's taps have one channel.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import replace
from importlib.metadata import distribution, version
from importlib.resources import files
from pathlib import Path

import numpy as np

from spektrafilm import digest_params, init_params
from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.utils.gamut_compression import OutputGamutCompressSpec

REPOSITORY = Path(__file__).resolve().parent.parent
RESOURCES = REPOSITORY / "Engine/Sources/SpektraEngine/Resources"
GOLDEN = REPOSITORY / "golden"
REFERENCE_COMMIT = "6cd00c8d4f30b5b550f50f4bbd3753c9f2a48507"
STOCKS = ("kodak_doublex", "kodak_trix", "kodak_2302")

# (input, film, print or None for the film scanned, film development, print development in minutes)
CASES = [
    ("chart", "kodak_doublex", "kodak_2302", None, None),
    ("chart", "kodak_doublex", "kodak_2302", 8.0, 2.5),
    ("chart", "kodak_doublex", "kodak_portra_endura", None, None),
    ("chart", "kodak_doublex", None, None, None),
    ("chart", "kodak_trix", None, None, None),
    ("chart", "kodak_portra_400", "kodak_2302", None, None),
    ("photo", "kodak_doublex", "kodak_2302", None, None),
]

# The engine's DIR coupler strengths (`Parameters.applyFilmSpecifics`, main's `_apply_film_specifics`):
# same layer, then red to green and blue, green to red and blue, blue to red and green.
COUPLERS = {
    "negative": ((0.336, 0.319, 0.273), (0.353, 0.302), (0.154, 0.353), (0.168, 0.226)),
    "positive": ((0.12, 0.08, 0.06), (0.12, 0.06), (0.08, 0.06), (0.06, 0.06)),
}

# How far pinned dev may be from main's reference data for Portra 400 -> Portra Endura, per tap as the
# largest absolute difference: 3x the most measured (2.0e-7 and 4.9e-7, the float32 they're stored as).
PIN_TOLERANCES = {"chart": 6e-7, "photo": 2e-6}


def export(resources: Path):
    package = files("spektrafilm.data")
    for stock in STOCKS:
        (resources / "profiles" / f"{stock}.json").write_bytes((package / "profiles" / f"{stock}.json").read_bytes())
    theirs = json.loads((package / "filters/neutral_print_filters.json").read_text())
    path = resources / "neutral_print_filters.json"
    filters = json.loads(path.read_text())
    for paper, illuminants in theirs.items():
        for illuminant, films in illuminants.items():
            for film, values in films.items():
                if paper in STOCKS or film in STOCKS:
                    filters.setdefault(paper, {}).setdefault(illuminant, {})[film] = values
    # As Spektrafilm writes it, so the entries that were there stay byte for byte.
    path.write_text(json.dumps(filters, indent=4))


def pinned(film: str, paper: str | None, input_name: str, development=(None, None)) -> SimulationPipeline:
    """The pipeline for `film` on `paper` (None: the film scanned), dev's newer steps pinned to the
    engine's (module docstring)."""
    # A scanned film's print is required by the API but unused.
    params = init_params(film, paper or "kodak_portra_endura")
    stored_curves = np.array(params.film.data.density_curves)
    params.io.scan_film = paper is None
    params.debug.deactivate_stochastic_effects = True
    if input_name == "chart":
        params.debug.lut_mode = True
    else:
        params.io.input_color_space = "sRGB"
        params.io.input_cctf_decoding = True
    params = digest_params(params)

    params.camera.auto_exposure = False
    couplers = params.film_render.dir_couplers
    (couplers.gamma_samelayer_rgb, couplers.gamma_interlayer_r_to_gb, couplers.gamma_interlayer_g_to_rb,
     couplers.gamma_interlayer_b_to_rg) = COUPLERS[params.film.info.type]
    couplers.langmuir_donor_k_rgb = couplers.langmuir_receiver_k_rgb = (np.inf, np.inf, np.inf)
    couplers.diffusion_tail_weight = 0.06
    params.io.output_gamut_compress = OutputGamutCompressSpec(algorithm="cam16ucs")
    params.film_render.chemistry = replace(params.film_render.chemistry, active=False, development_time=development[0])
    params.print_render.chemistry = replace(params.print_render.chemistry, active=False, development_time=development[1])
    bundled = json.loads((RESOURCES / "neutral_print_filters.json").read_text())
    (params.enlarger.c_filter_neutral, params.enlarger.m_filter_neutral,
     params.enlarger.y_filter_neutral) = bundled[params.print.info.stock][params.enlarger.illuminant][film]

    pipeline = SimulationPipeline(params)
    if params.film.is_color:
        pipeline.soft_update(film_density_curves=stored_curves)
    return pipeline


def run_all_taps(pipeline: SimulationPipeline, image: np.ndarray) -> dict[str, np.ndarray]:
    # Same walk as runtime.topology.run_topology, but keeping every tap instead of one.
    state = {"rgb_in": image}
    for node in pipeline._topology:
        if all(k in state for k in node.reads):
            node.fire(state)
    return state


def reference_input(input_name: str) -> np.ndarray:
    """The chart, or the photo as main exposed it, from main's Portra 400 -> Portra Endura case."""
    path = GOLDEN / f"{input_name}-kodak_portra_400-kodak_portra_endura" / "rgb_pre.npy"
    if not path.exists():
        raise SystemExit(f"Need {path}: run tools/golden.py first")
    return np.load(path).astype(np.float64)


def check_pins():
    for input_name, tolerance in PIN_TOLERANCES.items():
        taps = run_all_taps(pinned("kodak_portra_400", "kodak_portra_endura", input_name), reference_input(input_name))
        for name in ("log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out"):
            reference = np.load(GOLDEN / f"{input_name}-kodak_portra_400-kodak_portra_endura" / f"{name}.npy")
            difference = float(np.max(np.abs(taps[name] - reference)))
            print(f"pins | {input_name} | {name} | {difference:.3g} | {tolerance:.3g}")
            if not difference <= tolerance:
                raise SystemExit(f"Pinned dev isn't main: {input_name} {name} is {difference:.3g} off, over {tolerance:.3g}")


def installed_commit() -> str | None:
    """The commit in the install's direct_url.json (PEP 610); None unless it came from git."""
    direct_url = distribution("spektrafilm").read_text("direct_url.json")
    if direct_url is None:
        return None
    return json.loads(direct_url).get("vcs_info", {}).get("commit_id")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resources", type=Path, help="only add the bundled data, to this folder (tools/check-upstream.sh)")
    args = parser.parse_args()
    installed = installed_commit()
    if installed != REFERENCE_COMMIT:
        raise SystemExit(f"Need spektrafilm at commit {REFERENCE_COMMIT}, found {installed or 'an install not from git'}")
    export(args.resources or RESOURCES)
    if args.resources:
        return

    check_pins()
    manifest = {
        "spektrafilmCommit": installed,
        "versions": {name: version(name) for name in ("numpy", "scipy", "colour-science")},
        "files": {},
    }
    for input_name, film, paper, *development in CASES:
        case = f"{input_name}-{film}-{paper or 'scan'}"
        if development != [None, None]:
            case += "-developed_" + "_".join(f"{minutes:g}" for minutes in development)
        pipeline = pinned(film, paper, input_name, development)
        taps = run_all_taps(pipeline, reference_input(input_name))
        del taps["rgb_in"]
        case_dir = GOLDEN / case
        case_dir.mkdir(parents=True, exist_ok=True)
        for name, array in dict(taps, tc_lut=pipeline._lut_service.filming_tc_lut_memory).items():
            np.save(case_dir / f"{name}.npy", np.asarray(array, dtype=np.float32))
        for path in sorted(case_dir.iterdir()):
            manifest["files"][f"{case}/{path.name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"{case}: {', '.join(f'{name} {array.shape[-1]}' for name, array in taps.items())}")
    (GOLDEN / "manifest-bw.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
