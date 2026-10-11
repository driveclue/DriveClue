#!/bin/bash
# Build the website in Web/ and publish the built files to the gh-pages branch of
# driveclue/driveclue.github.io. The site source lives on that repo's main branch;
# GitHub Pages serves gh-pages, which only ever holds the build output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/Web"
DIST="$WEB/dist"
REPO="driveclue/driveclue.github.io"
BRANCH="gh-pages"
SITE_URL="https://driveclue.github.io/"
STAGE=""
PUBLISHED=0

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
usage() {
  printf '%s\n' 'usage: scripts/deploy-web.sh build' \
    '       scripts/deploy-web.sh publish [--allow-dirty]' \
    '' \
    '  build          install dependencies, build Web/ into Web/dist, check the output' \
    '  publish        build, then push Web/dist to the gh-pages branch' \
    '  --allow-dirty  publish even if Web/ has uncommitted source changes' >&2
  exit 2
}

[ $# -ge 1 ] || usage
ACTION="$1"; shift
ALLOW_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty) [ "$ACTION" = publish ] || usage; ALLOW_DIRTY=1; shift ;;
    *) usage ;;
  esac
done
case "$ACTION" in build|publish) ;; *) usage ;; esac

require() { command -v "$1" >/dev/null || fail "missing tool: $1"; }
require git
require node
require npm

[ -f "$WEB/package.json" ] || fail "no website project at $WEB"
git -C "$WEB" rev-parse --git-dir >/dev/null 2>&1 || fail "$WEB is not a git checkout of $REPO"
REMOTE_URL="$(git -C "$WEB" remote get-url origin 2>/dev/null)" || fail "$WEB has no origin remote"
[[ "$REMOTE_URL" =~ github\.com[:/]${REPO//./\\.}(\.git)?$ ]] || fail "origin of $WEB is $REMOTE_URL, expected $REPO"

check_source() {
  [ -z "$(git -C "$WEB" status --porcelain)" ] && return
  if [ "$ALLOW_DIRTY" -eq 1 ]; then
    printf 'warning: publishing uncommitted source changes in %s\n' "$WEB" >&2
  else
    git -C "$WEB" status --short >&2
    fail "Web/ has uncommitted changes; commit them or pass --allow-dirty"
  fi
}

build() {
  info "installing dependencies"
  (cd "$WEB" && npm ci --no-audit --no-fund --loglevel=error)
  info "building site"
  rm -rf "$DIST"
  (cd "$WEB" && npm run build --silent)
}

check_dist() {
  local ref missing=0
  [ -f "$DIST/index.html" ] || fail "build produced no dist/index.html"
  if grep -q 'src="/src/' "$DIST/index.html"; then
    fail "dist/index.html still points at source files"
  fi
  while IFS= read -r ref; do
    [ -e "$DIST/$ref" ] || { printf 'missing: %s\n' "$ref" >&2; missing=1; }
  done < <(grep -oE '(src|href)="\./[^"#?]+' "$DIST/index.html" | sed -E 's/^(src|href)="\.\///' | sort -u)
  [ "$missing" -eq 0 ] || fail "dist/index.html references files that are not in the build"
  info "build ok: $(find "$DIST" -type f | wc -l | tr -d ' ') files, $(du -sh "$DIST" | cut -f1)"
}

publish() {
  local sha note="" name email rc=0
  sha="$(git -C "$WEB" rev-parse --short HEAD)"
  [ -z "$(git -C "$WEB" status --porcelain)" ] || note=" with uncommitted changes"
  name="$(git -C "$WEB" config user.name || true)"
  email="$(git -C "$WEB" config user.email || true)"
  [ -n "$name" ] && [ -n "$email" ] || fail "set git user.name and user.email before publishing"

  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$DIST/." "$STAGE/"
  touch "$STAGE/.nojekyll"
  if [ -f "$WEB/LICENSE" ]; then cp "$WEB/LICENSE" "$STAGE/"; fi

  # Stage the build in a throwaway repo whose parent commit is the current gh-pages
  # tip, so the new commit replaces the whole tree and pushes as a fast-forward.
  git -C "$STAGE" init -q -b "$BRANCH"
  git ls-remote --exit-code --heads "$REMOTE_URL" "$BRANCH" >/dev/null || rc=$?
  case "$rc" in
    0) git -C "$STAGE" fetch -q --depth 1 "$REMOTE_URL" "$BRANCH"
       git -C "$STAGE" reset -q --soft FETCH_HEAD ;;
    2) info "$BRANCH does not exist yet; creating it" ;;
    *) fail "could not reach $REMOTE_URL" ;;
  esac
  git -C "$STAGE" add -A
  if git -C "$STAGE" rev-parse -q --verify HEAD >/dev/null && git -C "$STAGE" diff --cached --quiet HEAD; then
    info "site unchanged; nothing to publish"
    return
  fi
  git -C "$STAGE" -c user.name="$name" -c user.email="$email" \
    commit -q -m "Deploy site from $sha$note"
  info "pushing to $REPO $BRANCH"
  git -C "$STAGE" push -q "$REMOTE_URL" "HEAD:refs/heads/$BRANCH"
  info "published $(git -C "$STAGE" rev-parse --short HEAD) (source $sha$note)"
  PUBLISHED=1
}

check_pages_source() {
  local src
  command -v gh >/dev/null || return 0
  src="$(gh api "repos/$REPO/pages" --jq '.source.branch + ":" + .source.path' 2>/dev/null || true)"
  if [ "$src" = "$BRANCH:/" ]; then
    [ "$PUBLISHED" -eq 0 ] || info "GitHub Pages will update $SITE_URL in a minute or two"
  else
    printf 'warning: GitHub Pages serves %s, not %s:/. To switch it:\n' "${src:-unknown}" "$BRANCH" >&2
    printf '  gh api -X PUT repos/%s/pages -f "source[branch]=%s" -f "source[path]=/"\n' "$REPO" "$BRANCH" >&2
  fi
}

[ "$ACTION" = publish ] && check_source
build
check_dist
if [ "$ACTION" = publish ]; then
  publish
  check_pages_source
fi
