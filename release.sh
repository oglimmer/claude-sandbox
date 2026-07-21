#!/usr/bin/env bash
#
# release.sh — cut a new Homebrew release of claude-sandbox.
#
# Mirrors the existing tag history: the tag points at the "Point the formula
# at vX.Y.Z" commit (which carries a blank checksum, since the tarball can't
# be hashed until the tag exists), and a follow-up commit pins the sha256.
#
# Steps:
#   1. Point the formula URL at the new tag and blank its sha256.
#   2. Commit "Point the formula at vX.Y.Z" and tag it vX.Y.Z.
#   3. Push the branch + tag so GitHub generates the source tarball.
#   4. Download the tarball, compute its sha256, pin it in the formula.
#   5. Commit "Pin the vX.Y.Z tarball checksum in the formula" and push.
#
# Usage:
#   ./release.sh           # bump the minor version of the latest tag (default)
#   ./release.sh minor     # same as above
#   ./release.sh patch     # bump the patch version instead
#   ./release.sh major     # bump the major version
#   ./release.sh 1.3.0     # release an explicit version

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

formula="Formula/claude-sandbox.rb"
remote="origin"
tarball_url_base="https://github.com/oglimmer/claude-sandbox/archive/refs/tags"

die() { echo "release.sh: $*" >&2; exit 1; }

[[ -f "$formula" ]] || die "formula not found at $formula"

# --- Work out the version to release ---------------------------------------
latest_tag="$(git tag -l 'v*' --sort=-v:refname | head -n1)"
[[ -n "$latest_tag" ]] || die "no existing v* tag to bump from"
latest="${latest_tag#v}"
IFS=. read -r major minor patch <<<"$latest"

case "${1:-minor}" in
  major)          version="$((major + 1)).0.0" ;;
  minor)          version="${major}.$((minor + 1)).0" ;;
  patch)          version="${major}.${minor}.$((patch + 1))" ;;
  [0-9]*.[0-9]*.[0-9]*) version="$1" ;;
  *)              die "unknown argument '$1' (expected major|minor|patch|X.Y.Z)" ;;
esac
tag="v${version}"
url="${tarball_url_base}/${tag}.tar.gz"

# --- Preconditions ----------------------------------------------------------
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
branch="$(git symbolic-ref --short HEAD)" || die "not on a branch"
! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null || die "tag ${tag} already exists"

echo "==> Releasing ${tag} (previous: ${latest_tag}) on branch ${branch}"

# --- Formula rewrite helper -------------------------------------------------
# Rewrites the url + sha256 fields in place without touching the rest of the file.
set_field() {
  local field=$1 value=$2 tmp
  tmp="$(mktemp)"
  sed -E "s#^([[:space:]]*${field} \")[^\"]*(\")#\\1${value}\\2#" "$formula" >"$tmp"
  mv "$tmp" "$formula"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# --- Step 1+2: point the formula at the new tag, commit, tag ----------------
set_field url "$url"
set_field sha256 ""
git add "$formula"
git commit -m "Point the formula at ${tag}"
git tag "$tag"

# --- Step 3: push branch + tag so GitHub materialises the tarball -----------
echo "==> Pushing ${branch} and ${tag} to ${remote}"
git push "$remote" "$branch"
git push "$remote" "$tag"

# --- Step 4: fetch the tarball and compute its checksum ---------------------
echo "==> Fetching source tarball to compute sha256"
sha=""
for attempt in 1 2 3 4 5; do
  if sha="$(curl -fsSL "$url" | sha256_of)" && [[ -n "$sha" ]]; then
    break
  fi
  echo "    tarball not ready yet (attempt ${attempt}); retrying in 5s..."
  sha=""
  sleep 5
done
[[ -n "$sha" ]] || die "could not download ${url} to compute its checksum"
echo "==> sha256: ${sha}"

# --- Step 5: pin the checksum, commit, push ---------------------------------
set_field sha256 "$sha"
git add "$formula"
git commit -m "Pin the ${tag} tarball checksum in the formula"
git push "$remote" "$branch"

echo "==> Released ${tag}"
echo "    brew upgrade claude-sandbox   # once the tap picks it up"
