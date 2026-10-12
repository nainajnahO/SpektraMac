"""Export the data tables the Swift engine needs from Python Spektrafilm 0.3.4.

    ~/.local/share/uv/tools/spektrafilm/bin/python tools/export_tables.py

Writes Engine/Sources/SpektraEngine/Resources/ (committed, it ships with the engine):
- profiles/*.json, neutral_print_filters.json: copied unchanged from the package (CC BY-SA 4.0).
- irradiance_xy_tc.npy: hanatos2025 spectra LUT (192x192x81 float16), copied unchanged.
- tables.json: values that live inside colour-science or are resampled at import time, evaluated
  on Spektrafilm's 380-780 nm / 5 nm grid exactly as the Python code computes them:
  CIE 1931 2-degree CMFs, the normalised illuminants used by profiles and the enlarger, the KG3
  heat filter and lens transmission (Akima-resampled), the analytic dichroic CMY filters, RGB
  colour spaces (RGB->XYZ matrix, whitepoint, transfer function) and chromatic-adaptation matrices.
"""

from __future__ import annotations

import json
import shutil
from importlib.metadata import version
from importlib.resources import files
from pathlib import Path

import colour

from spektrafilm.config import SPECTRAL_SHAPE, STANDARD_OBSERVER_CMFS
from spektrafilm.model.color_filters import (
    custom_dichroic_filters,
    generic_lens_transmission,
    schott_kg3_heat_filter,
)
from spektrafilm.model.illuminants import standard_illuminant

REFERENCE_VERSION = "0.3.4"
OUT = Path(__file__).resolve().parent.parent / "Engine/Sources/SpektraEngine/Resources"

ILLUMINANTS = ["D50", "D55", "D65", "T", "K75P", "TH-KG3", "TH-KG3-L"]

# Transfer functions as colour-science 0.4.7 defines them for each space Spektrafilm offers.
COLOUR_SPACES = {
    "sRGB": {"cctf": "sRGB"},
    "DCI-P3": {"cctf": "gamma", "gamma": 2.6},
    "Display P3": {"cctf": "sRGB"},
    "Adobe RGB (1998)": {"cctf": "gamma", "gamma": 563 / 256},
    "ITU-R BT.2020": {"cctf": "BT.2020"},
    "ProPhoto RGB": {"cctf": "ROMM RGB"},
    "ACES2065-1": {"cctf": "linear"},
}

CATS = ["CAT02", "CAT16", "Bradford"]


def main():
    installed = version("spektrafilm")
    if installed != REFERENCE_VERSION:
        raise SystemExit(f"Need spektrafilm {REFERENCE_VERSION}, found {installed}")

    package = files("spektrafilm.data")
    profiles_out = OUT / "profiles"
    profiles_out.mkdir(parents=True, exist_ok=True)
    for entry in (package / "profiles").iterdir():
        if entry.name.endswith(".json"):
            (profiles_out / entry.name).write_bytes(entry.read_bytes())
    shutil.copyfile(package / "filters/neutral_print_filters.json", OUT / "neutral_print_filters.json")
    shutil.copyfile(package / "luts/spectral_upsampling/irradiance_xy_tc.npy", OUT / "irradiance_xy_tc.npy")

    colour_spaces = {}
    for name, transfer in COLOUR_SPACES.items():
        space = colour.RGB_COLOURSPACES[name]
        colour_spaces[name] = {
            "rgbToXYZ": space.matrix_RGB_to_XYZ.tolist(),
            "whitepoint": space.whitepoint.tolist(),
            **transfer,
        }

    tables = {
        "spektrafilmVersion": installed,
        "colourVersion": version("colour-science"),
        "wavelengths": SPECTRAL_SHAPE.wavelengths.tolist(),
        "cmfs": STANDARD_OBSERVER_CMFS[:].tolist(),
        "illuminants": {name: standard_illuminant(name).tolist() for name in ILLUMINANTS},
        "kg3HeatFilter": schott_kg3_heat_filter.transmittance.tolist(),
        "lensTransmission": generic_lens_transmission.transmittance.tolist(),
        "dichroicFilters": custom_dichroic_filters.filters.tolist(),
        "colourSpaces": colour_spaces,
        "chromaticAdaptation": {
            name: colour.adaptation.CHROMATIC_ADAPTATION_TRANSFORMS[name].tolist() for name in CATS
        },
    }
    (OUT / "tables.json").write_text(json.dumps(tables, indent=1) + "\n")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
