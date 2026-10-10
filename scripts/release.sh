#!/usr/bin/env bash
# Release a new version to Homebrew users.
#
# Versioned-release model: ordinary commits never ship to users. Only when you
# run this script (a tagged release) do `brew update && brew upgrade quicktodo`
# deliver the change.
#
# `main` is branch-protected (no direct pushes), so the version bump goes
# through a PR which is opened and merged here via the GitHub CLI.
#
# Usage:
#   ./scripts/release.sh
#
# Requires: gh (authenticated), push access to the tap repo.
set -euo pipefail

REPO=mdopeace/quicktodo            # app repo (origin)
TAP=mdopeace/homebrew-quicktodo    # tap repo containing Cask/quicktodo.rb (binary distribution only)

cd "$(dirname "$0")/.."

# Read current version from Info.plist
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
NEXT_MAJOR="$((MAJOR + 1)).0.0"
NEXT_MINOR="$MAJOR.$((MINOR + 1)).0"
NEXT_PATCH="$MAJOR.$MINOR.$((PATCH + 1))"

if ! git diff --quiet; then
    echo "error: working tree is dirty. Commit your changes first." >&2
    exit 1
fi

# Version bump selector
echo "Release v$CURRENT — choose bump:"
select V in "$NEXT_PATCH" "$NEXT_MINOR" "$NEXT_MAJOR" "Abort"; do
    case "$V" in
        "") continue ;;
        "Abort") echo "Aborted."; exit 1 ;;
        *) break ;;
    esac
done

# Confirmation prompt
echo "This will release v$V:"
echo "  - Bump version in Info.plist"
echo "  - Create & merge PR to main"
echo "  - Tag v$V"
echo "  - Create GitHub Release with binary zip + checksum"
echo "  - Update Homebrew tap cask"
read -p "Proceed? [y/N] " confirm || { echo "Aborted."; exit 1; }
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# 1. Bump version in Info.plist (short + full)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $V" Info.plist

# 2. Bump version in Version.swift (shared constant for CLI + UI)
sed -i '' "s/^public let appVersion = \".*\"/public let appVersion = \"$V\"/" Sources/QuickTodoCore/Version.swift
grep -q "appVersion = \"$V\"" Sources/QuickTodoCore/Version.swift || { echo "Version.swift update failed"; exit 1; }

# 3. Push the version bump to main via a PR (main is branch-protected)
BR="release/v$V"
git checkout -b "$BR"
git add Info.plist Sources/QuickTodoCore/Version.swift
git commit -m "Bump version to $V"
git push -u origin "$BR"
# gh pr create prints the URL on stdout; keep it for the failure handler below.
PR_URL=$(gh pr create --base main --head "$BR" --title "Release v$V" \
    --body "Bumps the version to $V for release.")
gh pr merge --merge --delete-branch || {
    echo "error: could not merge $BR into main automatically." >&2
    echo "       The version bump is committed and pushed, and its PR is still open:" >&2
    echo "         $PR_URL" >&2
    echo "       To release it, merge that PR, then re-run this script." >&2
    echo "       To abandon it, remove the branch and the PR too:" >&2
    echo "         git checkout main && git branch -D $BR && \\" >&2
    echo "           git push origin --delete $BR && gh pr close $PR_URL" >&2
    exit 1
}
git checkout main
git fetch origin
git reset --hard origin/main

# 3. Build the app archive used by the in-app updater.
#    Pass version so package.sh uses correct version in bundle.
MARKETING_VERSION="$V" CURRENT_PROJECT_VERSION="$V" CREATE_ARCHIVE=1 ./scripts/package.sh local
ARCHIVE="quicktodo.app.zip"
CHECKSUM="$ARCHIVE.sha256"
# Also cleans the tap clone (step 6) and the parent dir its clone path implies,
# so a mid-release failure doesn't leave an untracked dir in the repo root.
# rmdir, not rm -rf, on the parent: it refuses when the dir still has contents.
trap 'rm -f "$ARCHIVE" "$CHECKSUM"; rm -rf "$TAP"; rmdir "$(dirname "$TAP")" 2>/dev/null || true' EXIT

# 4. Tag the release (tags are not branch-protected) and attach the app
#    archive and its checksum to the GitHub Release.
git tag "v$V"
git push origin "v$V"
gh release create "v$V" --title "v$V" --generate-notes "$ARCHIVE" "$CHECKSUM"

# 5. Get SHA from the binary release asset (for tap formula)
BINARY_URL="https://github.com/$REPO/releases/download/v$V/quicktodo.app.zip"
HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "$BINARY_URL")
if [ "$HTTP_CODE" != "200" ]; then
    echo "error: failed to fetch binary release (HTTP $HTTP_CODE)" >&2
    exit 1
fi
BINARY_SHA=$(curl -sL "$BINARY_URL" | shasum -a 256 | awk '{print $1}')

# 6. Update the tap cask to point at the new binary release + its checksum
#
# A cask rather than a formula: the deliverable is a .app bundle, not a binary on
# PATH. A formula sandboxes it under libexec and leaves the user to copy it into
# /Applications by hand; a cask installs there directly.
#
# Deliberately no `auto_updates true`. That stanza tells Homebrew to skip the app
# during `brew upgrade` and defer to its in-app updater. We want brew to upgrade
# it too, so the tap is bumped in lockstep with every release below and both
# paths converge on the same version.
rm -rf "$TAP"
git clone "https://github.com/$TAP" "$TAP"
# Drop the old formula; a name in both Formula/ and Cask/ makes the install ambiguous.
rm -rf "$TAP/Formula"
F="$TAP/Cask/quicktodo.rb"
mkdir -p "$(dirname "$F")"
cat > "$F" <<EOF
# frozen_string_literal: true

cask "quicktodo" do
  version "$V"
  sha256 "$BINARY_SHA"

  url "https://github.com/$REPO/releases/download/v$V/quicktodo.app.zip"
  name "QuickTodo"
  desc "Minimal menu-bar todo app for macOS"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :ventura"

  app "quicktodo.app"
end
EOF

(
    cd "$TAP"
    git checkout -b "quicktodo-v$V"
    git add -A
    git commit -m "quicktodo $V"
    git push -u origin "quicktodo-v$V"
    # gh pr create prints the URL on stdout; keep it for the failure handler below.
    TAP_PR_URL=$(gh pr create --base main --head "quicktodo-v$V" --title "quicktodo $V" \
        --body "Releases quicktodo v$V.")
    # Runs after the tag and GitHub Release are already published, so a failure
    # here is a half-published release: v$V is live but Homebrew still serves
    # the previous version. Name the PR instead of aborting silently.
    gh pr merge --merge --delete-branch || {
        echo "error: could not merge the tap PR, so Homebrew is not updated yet." >&2
        echo "       GitHub Release v$V IS published — only the tap update failed." >&2
        echo "       Merge this PR to finish, then 'brew update && brew upgrade quicktodo':" >&2
        echo "         $TAP_PR_URL" >&2
        exit 1
    }
)

echo "Released v$V. Users can now: brew update && brew upgrade quicktodo"