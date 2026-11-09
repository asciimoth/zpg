#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: just release VERSION\n'; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 1 && $1 =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    usage >&2
    fail 'Version must be x.y.z (an optional v prefix is allowed).'
}
tag=v${1#v}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$repo_root"

for tool in git just goreleaser gh python3 sha256sum; do
    command -v "$tool" >/dev/null || fail "Missing command: $tool"
done
if [[ -n ${GHREPO_REPO_DIR:-} ]]; then
    command -v ghrepo >/dev/null || fail 'ghrepo is required when GHREPO_REPO_DIR is set.'
    [[ -d $GHREPO_REPO_DIR && -w $GHREPO_REPO_DIR && -r $GHREPO_REPO_DIR/ghrepo.yaml ]] ||
        fail 'GHREPO_REPO_DIR must be a writable, initialized ghrepo repository.'
    ghrepo check --dry-run
fi
[[ -z $(git status --porcelain) ]] || fail 'Commit all changes before releasing.'
[[ $(git rev-parse --is-shallow-repository) == false ]] || fail 'Fetch the full Git history and tags before releasing.'
head=$(git rev-parse HEAD)
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "Local tag $tag already exists."; fi
origin=$(git remote get-url --push --all origin)
[[ $origin != *$'\n'* ]] || fail 'origin must have one push URL.'
case $origin in
    https://github.com/*) github_repo=${origin#https://github.com/} ;;
    git@github.com:*) github_repo=${origin#git@github.com:} ;;
    ssh://git@github.com/*) github_repo=${origin#ssh://git@github.com/} ;;
    *) fail 'origin must point to a github.com repository.' ;;
esac
github_repo=${github_repo%.git}
[[ $github_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'Invalid GitHub origin.'
[[ -z $(git ls-remote --tags "$origin" "refs/tags/$tag") ]] || fail "Remote tag $tag already exists."
export GH_HOST=github.com
export GITHUB_TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}
if [[ -z $GITHUB_TOKEN ]]; then GITHUB_TOKEN=$(gh auth token --hostname github.com); fi
[[ -n $GITHUB_TOKEN ]] || fail 'Set GITHUB_TOKEN or GH_TOKEN with repository write access.'
export GH_TOKEN=$GITHUB_TOKEN
[[ $(gh api "repos/$github_repo" --jq '.permissions.push') == true ]] ||
    fail 'GitHub credentials do not have repository write access.'
if gh release view "$tag" --repo "github.com/$github_repo" >/dev/null 2>&1; then
    fail "GitHub Release $tag already exists."
fi
goreleaser check
just check
[[ -z $(git status --porcelain) && $(git rev-parse HEAD) == "$head" ]] ||
    fail 'Checks changed the source. Commit changes before releasing.'

git -c tag.gpgSign=false tag -a "$tag" "$head" -m "Release $tag"
# Keep the tag local until every asset is built and verified.
GORELEASER_CURRENT_TAG=$tag goreleaser release --clean --skip=publish
python3 tools/package_artifacts.py
(cd dist && sha256sum -c checksums.txt)

assets=(dist/checksums.txt dist/checksums.txt.sig)
urls=()
while read -r checksum name; do
    [[ $checksum =~ ^[[:xdigit:]]{64}$ && $name != */* && -f dist/$name && -f dist/$name.sig ]] ||
        fail "Invalid or unsigned release asset: $name"
    assets+=("dist/$name" "dist/$name.sig")
    case $name in
        *.deb|*.rpm) urls+=("https://github.com/$github_repo/releases/download/$tag/$name") ;;
    esac
done < dist/checksums.txt
((${#assets[@]} > 2)) || fail 'No release assets were built.'
if [[ -n ${GHREPO_REPO_DIR:-} ]]; then
    ((${#urls[@]} > 0)) || fail 'No DEB/RPM packages found for ghrepo.'
fi
[[ -z $(git status --porcelain) && $(git rev-parse HEAD) == "$head" ]] ||
    fail 'Source changed during packaging; refusing to publish.'
[[ $(git rev-parse "$tag^{commit}") == "$head" ]] || fail 'Release tag changed during packaging.'

git push origin "refs/tags/$tag"
gh release create "$tag" "${assets[@]}" --repo "github.com/$github_repo" --verify-tag --title "$tag" --generate-notes
if [[ -n ${GHREPO_REPO_DIR:-} ]]; then
    ghrepo add "${urls[@]}"
fi
printf 'Published https://github.com/%s/releases/tag/%s\n' "$github_repo" "$tag"
