#!/usr/bin/env bash
# Makes the film looks the README and the user guide show (docs/images/looks/): tools/looks.sh.
#
# Downloads NASA's Artemis II photo (credited at the end of the README) from a pinned URL and checks
# its checksum. Renders it through each film as the app's Save does with what choosing that film sets
# (spektra-cli save --film): at full resolution, with every effect the film's defaults switch on. Then
# scales each render, and the photo itself, to 1600 px on the long side with sips, and encodes it as
# WebP with its colour profile. ImageIO can't write WebP, so cwebp (Homebrew's webp) does that.
#
# Run it when a change shows in renders, and commit the images it changes.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
looks=$repo/docs/images/looks
photo_url="https://upload.wikimedia.org/wikipedia/commons/f/f9/Sun_sets_on_Full_Artemis_II_Stack_at_Launch_Pad_39B_%28Artemis_II_at_the_pad_sunsetting_jet_in_background_01292026_9%29.jpg"
photo_sha256=75669024333ea2bb8a755ba58fdb523cf577c40b9022796dc25f37f710396c44
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v cwebp > /dev/null || { echo "tools/looks.sh needs cwebp: brew install webp"; exit 1; }

# Wikimedia turns away requests without a descriptive user agent.
curl --fail --silent --show-error --location --user-agent "SpektraMac tools/looks.sh (https://github.com/nainajnahO/SpektraMac)" \
    --output "$work/photo.jpg" "$photo_url"
echo "$photo_sha256  $work/photo.jpg" | shasum -a 256 --check --status || { echo "The photo's checksum doesn't match"; exit 1; }

swift build -c release --package-path "$repo/Engine" --product spektra-cli > /dev/null
cli=$(swift build -c release --package-path "$repo/Engine" --show-bin-path)/spektra-cli

# Scales an image to 1600 px on its long side and writes it as WebP, its colour profile kept.
encode() {
    sips --resampleHeightWidthMax 1600 --setProperty format png "$1" --out "$work/scaled.png" > /dev/null
    cwebp -quiet -metadata icc -q 90 "$work/scaled.png" -o "$2"
}

encode "$work/photo.jpg" "$looks/artemis-original.webp"
echo "artemis-original.webp"
for look in portra-400:kodak_portra_400 velvia-100:fujifilm_velvia_100 kodachrome-64:kodak_kodachrome_64 \
            ektar-100:kodak_ektar_100 vision3-500t:kodak_vision3_500t; do
    name=${look%%:*}
    "$cli" save "$work/photo.jpg" "$work/render.png" --film "${look#*:}" > /dev/null
    encode "$work/render.png" "$looks/artemis-$name.webp"
    echo "artemis-$name.webp"
done
