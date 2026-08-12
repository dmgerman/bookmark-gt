#!/usr/bin/env bash
# Update the version string across bookmark-gt sources.
#
# Usage:
#   scripts/update-version.sh <NEW_VERSION>
#
# Rewrites the `;; Version:' header line in every bookmark-gt*.el
# file at the repo root, and the `(defconst bookmark-gt-version
# ...)' form inside bookmark-gt.el.  All three surfaces must agree
# — `make check-version' fails otherwise.
#
# NEW_VERSION must be a dotted numeric string, optionally followed
# by a `-suffix' segment (e.g. `0.1.0', `1.2.3', `0.9.0-rc1').

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") <NEW_VERSION>" >&2
  exit 2
fi

new_version=$1

# Validate.  Accept N.N.N or N.N.N-suffix.
if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?$ ]]; then
  echo "error: version must match N.N.N or N.N.N-suffix (got: $new_version)" >&2
  exit 2
fi

# Locate repo root (this script lives in scripts/).
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
cd "$repo_root"

# Every bookmark-gt*.el file at repo root gets its header updated.
shopt -s nullglob
el_files=(bookmark-gt*.el)
shopt -u nullglob

if [[ ${#el_files[@]} -eq 0 ]]; then
  echo "error: no bookmark-gt*.el files found in $repo_root" >&2
  exit 1
fi

# Portable in-place sed: pass an empty backup extension on macOS/BSD.
if sed --version >/dev/null 2>&1; then
  # GNU sed
  sed_i=(sed -i)
else
  # BSD/macOS sed
  sed_i=(sed -i '')
fi

for f in "${el_files[@]}"; do
  "${sed_i[@]}" -E \
    -e "s|^;; Version:.*$|;; Version: ${new_version}|" \
    "$f"
done

# Sync the defconst inside bookmark-gt.el.  The pattern is anchored
# to the specific defconst so we don't accidentally touch anything
# else that mentions the symbol.
"${sed_i[@]}" -E \
  -e "s|^\(defconst bookmark-gt-version \"[^\"]*\"|(defconst bookmark-gt-version \"${new_version}\"|" \
  bookmark-gt.el

echo "updated ${#el_files[@]} files to version ${new_version}"
