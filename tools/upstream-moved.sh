#!/usr/bin/env bash
# Whether Spektrafilm's main has moved past the commit SpektraMac ports, and if it has, open or
# update one issue listing the new commits: tools/upstream-moved.sh [--dry-run] [commit]. The commit
# defaults to tables.json's spektrafilmCommit; --dry-run prints the issue instead of filing it.
# .github/workflows/upstream.yml runs it weekly.
set -euo pipefail
dry_run=false
if [[ ${1:-} == --dry-run ]]; then
    dry_run=true
    shift
fi
cd "$(dirname "$0")/.."
upstream=https://github.com/andreavolpato/spektrafilm
title="Upstream Spektrafilm has moved"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Commits and trees only: enough for the log and the paths each commit touches.
git clone --quiet --filter=blob:none --no-checkout --branch main "$upstream" "$work/spektrafilm"
upstream_git() { git -C "$work/spektrafilm" "$@"; }
pinned=$(upstream_git rev-parse "${1:-$(jq -r .spektrafilmCommit Engine/Sources/SpektraEngine/Resources/tables.json)}^{commit}")
head=$(upstream_git rev-parse HEAD)
if [[ $head == "$pinned" ]]; then
    echo "Spektrafilm main is still at ${pinned:0:7}, the commit SpektraMac ports."
    exit 0
fi

{
    echo "Spektrafilm's \`main\` is at [\`${head:0:7}\`]($upstream/commit/$head), past [\`${pinned:0:7}\`]($upstream/commit/$pinned), the commit SpektraMac ports (\`spektrafilmCommit\` in \`tables.json\`). Its new commits, oldest first, flagged where they touch the profiles (\`data/profiles/\`), the parameter schema (\`runtime/params_schema.py\`, \`runtime/params_builder.py\`) or the model (\`model/\`):"
    echo
    upstream_git log --reverse --format=%H "$pinned..$head" | while read -r sha; do
        files=$(upstream_git diff-tree --no-commit-id --name-only -r "$sha")
        flags=""
        grep -q '^src/spektrafilm/data/profiles/' <<< "$files" && flags="$flags, profiles"
        grep -qE '^src/spektrafilm/runtime/params_(schema|builder)\.py$' <<< "$files" && flags="$flags, parameters"
        grep -q '^src/spektrafilm/model/' <<< "$files" && flags="$flags, model"
        echo "- [\`${sha:0:7}\`]($upstream/commit/$sha) $(upstream_git log -1 --format='%s (%as)' "$sha")${flags:+ — **${flags#, }**}"
    done
    echo
    echo "\`tools/check-upstream.sh ${head:0:7}\` shows how far SpektraMac is from it. The Upstream Spektrafilm workflow updates this issue weekly; close it once SpektraMac ports a newer commit."
} > "$work/body.md"

number=$(gh issue list --state open --limit 200 --json number,title \
    --jq ".[] | select(.title == \"$title\") | .number" | head -n 1)
if $dry_run; then
    if [[ -n $number ]]; then echo "Would update #$number: $title"; else echo "Would open an issue: $title"; fi
    cat "$work/body.md"
elif [[ -n $number ]]; then
    gh issue edit "$number" --body-file "$work/body.md" > /dev/null
    echo "Updated #$number: $(upstream_git rev-list --count "$pinned..$head") new commits"
else
    gh issue create --title "$title" --body-file "$work/body.md"
fi
