#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
# SPDX-FileCopyrightText: 2026 spatterlight
#
# SPDX-License-Identifier: Apache-2.0

# Prints the tag that the container image built from the currently checked out
# commit should be published as, or nothing at all if it does not warrant a
# new image.
#
# Usage: bin/compute-next-image-tag.sh
#
# Tags look like `<tinc version>-<release>`, the tinc version being the
# `TINC_VERSION` the Dockerfile builds:
#
# - if this tinc version has never been released, the release counter
#   restarts at 0 (`1.0.37-0`)
# - otherwise the counter is incremented (`1.0.37-1`), but only if something
#   that ends up in the image has changed since the last release
#
# They carry no leading `v`, which keeps them apart from the tags of the role
# itself (`v1.0.37-0-0`, see `bin/compute-next-tag.sh`).

set -euo pipefail

repository_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repository_path"

version="$(sed -nE 's|^ARG[[:space:]]+TINC_VERSION=([^[:space:]]+).*$|\1|p' Dockerfile | head -n1)"

if [ -z "$version" ]; then
	echo >&2 "Could not determine the tinc version from the Dockerfile"
	exit 1
fi

# Paths that shape the image. A commit touching only other paths (the role, a
# README fix, CI configuration, helper scripts) produces the same image, and
# releasing it would only create churn for everyone consuming the image.
image_defining_paths=(
	'Dockerfile'
)

tag_prefix="${version}-"

# Of all releases of this version, the highest release number. Sorted
# numerically, so that -10 is recognized as newer than -9. The grep ignores
# any tag which merely starts like this version's tags, but does not end in a
# plain release number.
last_release="$(git tag --list "${tag_prefix}*" | sed -e "s|^${tag_prefix}||" | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)"

if [ -z "$last_release" ]; then
	echo >&2 "Version $version has never been released"
	echo "${tag_prefix}0"
	exit 0
fi

previous_tag="${tag_prefix}${last_release}"

if git diff --quiet "$previous_tag" HEAD -- "${image_defining_paths[@]}"; then
	echo >&2 "Nothing affecting the image has changed since $previous_tag"
	exit 0
fi

echo >&2 "The image has changed since $previous_tag"
echo "${tag_prefix}$((last_release + 1))"
