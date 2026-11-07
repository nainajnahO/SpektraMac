#!/usr/bin/env bash
# How far SpektraMac is from a Spektrafilm commit: tools/check-upstream.sh <ref> (a branch, tag or commit).
#
# Exports the bundled data and makes the reference data from that commit into a temporary folder
# (uv run --isolated: the pinned uv tool install isn't touched), diffs the data against the bundled
# Resources, runs the engine's tests against that reference data and prints the largest difference
# per stage. Exits non-zero if a script fails, the data differ or a test fails.
set -u
ref=${1:?usage: tools/check-upstream.sh <ref>}
repo=$(cd "$(dirname "$0")/.." && pwd)
resources=$repo/Engine/Sources/SpektraEngine/Resources
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
result=0

spektrafilm_python() {
    uv run --quiet --isolated --python 3.13 \
        --with "spektrafilm @ git+https://github.com/andreavolpato/spektrafilm@$ref" python "$@"
}

echo "== Exporting the bundled data from Spektrafilm at $ref"
if ! spektrafilm_python "$repo/tools/export_tables.py" --out "$work/Resources"; then
    echo "export_tables.py failed at $ref"
    exit 1
fi

echo "== Bundled data: $ref against Resources/"
# tables.json names the commit it came from, which differs whenever the data don't.
if diff -rq -x tables.json "$resources" "$work/Resources" &&
    diff -q <(grep -v '"spektrafilmCommit"' "$resources/tables.json") \
        <(grep -v '"spektrafilmCommit"' "$work/Resources/tables.json") > /dev/null; then
    echo "identical"
else
    result=1
    diff -u "$resources/parameters.json" "$work/Resources/parameters.json"
fi

echo "== Making the reference data from Spektrafilm at $ref"
if ! spektrafilm_python "$repo/tools/golden.py" --out "$work/golden"; then
    echo "golden.py failed at $ref"
    exit 1
fi
changed=$(diff <(grep '": "' "$repo/golden/manifest.json" | grep -v Commit) \
    <(grep '": "' "$work/golden/manifest.json" | grep -v Commit) | grep -c '^>')
echo "$changed of $(grep -c '/' "$work/golden/manifest.json") reference files differ from golden/manifest.json"

echo "== Engine tests against $ref's reference data"
log=$work/test.log
SPEKTRA_GOLDEN=$work/golden swift test -c release -Xswiftc -enable-testing --package-path "$repo/Engine" > "$log" 2>&1 \
    || result=1
grep -E '✘|skipped' "$log"
grep -E 'Test run with' "$log"

echo "== Each parity check's worst case, tightest first: headroom (tolerance ÷ measured), measured against tolerance, case"
grep '^parity' "$log" | awk -F' [|] ' '{
    key = $2 " | " $4
    room = ($7 == "inf") ? 1e300 : $7 + 0
    if (!(key in least) || room < least[key]) { least[key] = room; line[key] = $7 " | " $2 " | " $4 " | " $5 " against " $6 " | " $3 }
} END { for (key in line) print line[key] }' | sort -t'|' -k1,1g

exit $result
