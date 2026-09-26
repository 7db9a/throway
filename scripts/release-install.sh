#!/bin/sh
# Dear Machine release installer for Linux and macOS, rendered for one GitHub
# release by render-release-installers.py. Do not publish it unrendered.
set -eu

main() {
  repository=@REPOSITORY@
  tag=@TAG@
  source_ref=@SOURCE_REF@
  signer_workflow=@SIGNER_WORKFLOW@
  download_url=@DOWNLOAD_URL@

  say() { printf '%s\n' "$*" >&2; }
  fail() { printf 'Dear Machine installer: %s\n' "$*" >&2; exit 1; }

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64) target=linux-x64 ;;
    Linux:aarch64|Linux:arm64) target=linux-arm64 ;;
    Darwin:arm64) target=darwin-arm64 ;;
    Darwin:x86_64) target=darwin-x64 ;;
    *) fail 'This operating system or processor is not supported.' ;;
  esac
  test "$(id -u)" != 0 || fail 'Run the installer as your normal user, without sudo.'
  : "${HOME:?HOME must be set}"
  if command -v sha256sum >/dev/null 2>&1; then
    digest() { sha256sum -- "$1" | cut -d ' ' -f 1; }
  elif command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 -- "$1" | cut -d ' ' -f 1; }
  else
    fail 'The installer needs sha256sum or shasum to check downloads.'
  fi

  prefix="dearmachine-$tag-$target"
  archive="$prefix.tar.gz"
  bootstrap="$prefix.bootstrap.sh"
  umask 077
  work=$(mktemp -d "${TMPDIR:-/tmp}/dearmachine-install.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP

  # Print the expected checksum of one file named in SHA256SUMS.
  expected() {
    awk -v name="$1" '($2 == name || $2 == "*" name) && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; found = 1; exit }
      END { if (!found) exit 1 }' "$work/SHA256SUMS"
  }

  if ! command -v gh >/dev/null 2>&1; then
    confirm_unverified missing
    verified=false
  elif ! gh_supported; then
    confirm_unverified outdated
    verified=false
  elif ! gh auth status >/dev/null 2>&1; then
    confirm_unverified signed-out
    verified=false
  else
    verified=true
  fi

  if [ "$verified" = true ]; then
    say "Downloading the checksums for Dear Machine $tag..."
    gh release download "$tag" --repo "$repository" --pattern SHA256SUMS --dir "$work" ||
      fail 'Could not download the release checksums. Check your connection and try again.'
    say 'Checking that this release was built by the official release workflow...'
    if ! gh attestation verify "$work/SHA256SUMS" --repo "$repository" \
        --signer-workflow "$signer_workflow" --source-ref "$source_ref" \
        --deny-self-hosted-runners >"$work/verification.log" 2>&1; then
      cat "$work/verification.log" >&2
      fail 'This release could not be verified, so nothing was installed. Please report this to the Dear Machine maintainers.'
    fi
    say 'Release verified.'
  else
    fetch SHA256SUMS
  fi
  if ! expected "$archive" >/dev/null || ! expected "$bootstrap" >/dev/null; then
    fail "Release $tag has no download for $target yet. Nothing was installed."
  fi

  say "Downloading Dear Machine $tag for $target..."
  if [ "$verified" = true ]; then
    gh release download "$tag" --repo "$repository" --pattern "$archive" --pattern "$bootstrap" --dir "$work" ||
      fail 'The download did not complete. Check your connection and try again.'
  else
    fetch "$bootstrap"
    fetch "$archive"
  fi
  for name in "$bootstrap" "$archive"; do
    test "$(digest "$work/$name")" = "$(expected "$name")" ||
      fail "$name does not match the release checksums, so nothing was installed."
  done
  sh "$work/$bootstrap" "$work/$archive"
}

# gh 2.68.0 is the oldest release with --source-ref that also reads the
# current Sigstore trusted root.
gh_supported() {
  gh --version 2>/dev/null | awk 'NR == 1 {
    split($3, v, ".")
    exit !(v[1] > 2 || (v[1] == 2 && v[2] >= 68))
  }'
}

fetch() {
  curl --fail --silent --show-error --location --proto-redir '=https' --retry 2 \
    --connect-timeout 30 --output "$work/$1" "$download_url/$1" ||
    fail "Could not download $1. Check your connection and try again."
}

confirm_unverified() {
  if [ "$1" = missing ]; then
    reason="It uses GitHub's free gh tool for that check, and gh isn't installed on this computer."
    steps="  1. Install gh by following https://cli.github.com
       (on a Mac with Homebrew: brew install gh)
  2. Sign in with: gh auth login
  3. Run this installer again."
  elif [ "$1" = outdated ]; then
    reason="It uses GitHub's gh tool for that check, and the gh on this computer is too old to do it. Version 2.68.0 or newer is needed."
    steps="  1. Update gh by following https://cli.github.com
       (on a Mac with Homebrew: brew upgrade gh)
  2. Sign in if you haven't yet: gh auth login
  3. Run this installer again."
  else
    reason="It uses GitHub's gh tool for that check. gh is installed, but it isn't signed in to GitHub yet."
    steps="  1. Sign in with: gh auth login
  2. Run this installer again."
  fi
  cat >&2 <<EOF

Before installing, this installer normally checks that Dear Machine really
came from its official release process and wasn't changed along the way.
$reason

The safest choice is to stop here and set up gh. It only takes a minute:

$steps

If you'd rather continue now, the installer will still compare each file with
the release's published checksums. That catches a damaged download, but it
can't tell whether someone changed the files on purpose.

EOF
  if ! (: </dev/tty) 2>/dev/null; then
    fail 'There is no terminal to confirm with, so nothing was installed.'
  fi
  printf 'Type yes to continue without the check, or press Enter to stop: ' >&2
  answer=
  IFS= read -r answer </dev/tty || answer=
  if [ "$answer" != yes ]; then
    say 'Stopped. Nothing was installed.'
    exit 1
  fi
  say 'Continuing without the release check.'
}

# Keep all work inside functions so piping this file to sh cannot start
# anything until the complete script has arrived.
main "$@"
