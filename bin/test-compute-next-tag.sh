#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Exercises bin/compute-next-tag.sh against throwaway git repositories.
#
# Usage: bin/test-compute-next-tag.sh
#
# Every scenario creates a repository in a temporary directory, gives it role
# files and a release history, and then replays a series of merges through the
# real script, tagging as it goes just like the autotag workflow does. This
# repository is never touched and no network access is needed.

set -euo pipefail

script_under_test="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/compute-next-tag.sh"

failures=0
workdir=''

cleanup() {
	cd /
	if [ -n "$workdir" ]; then
		rm -rf "$workdir"
		workdir=''
	fi
}

trap cleanup EXIT

# The defaults file of a scenario repository, at tinc 1.0.37-1.
#
# The decoys around the version are deliberate. `tinc_container_image_tag`
# derives from `tinc_version` through Jinja and must never be mistaken for
# the version itself; the commented-out line and the similarly named variables
# must not match either. Keying on anything but the leaf literal would make the
# tags disagree with the version the role actually deploys.
write_defaults() {
	local version="$1"

	cat > defaults/main.yml <<EOF
---
tinc_enabled: true

# tinc_version: 9.9.9-0 (an old value, kept around as a note)
tinc_versions_supported: ["1.0.36-0", "1.0.37-1"]
tinc_version_check_enabled: false

# renovate: datasource=docker depName=ghcr.io/mother-of-all-self-hosting/ansible-role-tinc versioning=loose
tinc_version: $version

tinc_container_image_tag: "{{ tinc_version }}"
tinc_container_image: "ghcr.io/mother-of-all-self-hosting/ansible-role-tinc:{{ tinc_container_image_tag }}"
EOF
}

# Starts a scenario with a repository at tinc 1.0.37-1 which has already
# seen two releases of it (v1.0.37-1-0 and v1.0.37-1-1).
scenario() {
	echo "$1"

	cleanup
	workdir="$(mktemp -d)"

	mkdir -p "$workdir/bin" "$workdir/defaults" "$workdir/meta" "$workdir/tasks" "$workdir/templates"
	cp "$script_under_test" "$workdir/bin/"
	cd "$workdir"

	git init -q -b main .
	git config user.email 'test@example.com'
	git config user.name 'Test'
	git config commit.gpgsign false

	write_defaults 1.0.37-1
	printf 'placeholder\n' > meta/main.yml
	printf 'placeholder\n' > tasks/main.yml
	printf 'placeholder\n' > templates/env.j2
	printf 'placeholder\n' > README.md
	printf 'placeholder\n' > Dockerfile

	git add -A
	git commit -qm 'Initial commit'

	local release_number
	for release_number in 0 1; do
		git tag "v1.0.37-1-$release_number"
	done
}

# Applies a change, commits it, and tags whatever the script says it should be.
# Prints the tag, or nothing when the script decided against a release.
merge() {
	local change="$1" tag

	eval "$change"
	git add -A
	git commit -qm 'Merge'

	tag="$(bin/compute-next-tag.sh 2>/dev/null)"

	if [ -n "$tag" ]; then
		git tag "$tag"
	fi

	printf '%s' "$tag"
}

expect() {
	local description="$1" expected="$2" actual="$3"

	if [ "$actual" = "$expected" ]; then
		printf '  ok   | %s -> %s\n' "$description" "${actual:-no release}"
	else
		printf '  FAIL | %s -> expected %s, got %s\n' "$description" "${expected:-no release}" "${actual:-no release}"
		failures=$((failures + 1))
	fi
}

# An image rebuild of the same tinc release, which is what most bumps here are.
bump_version='write_defaults 1.0.37-2'
revert_version='write_defaults 1.0.37-1'
prefix_version='write_defaults v1.0.37-2'
edit_task="printf 'a task\n' >> tasks/main.yml"
edit_template="printf 'a line\n' >> templates/env.j2"
edit_meta="printf 'a line\n' >> meta/main.yml"
edit_readme="printf 'documentation\n' >> README.md"
edit_script="printf '# a comment\n' >> bin/compute-next-tag.sh"
edit_dockerfile="printf '# a comment\n' >> Dockerfile"

# The two merge orders below apply the same updates and must each end up with
# every update released exactly once, whichever order they arrive in.

scenario 'A version bump merged before other role changes'
expect 'version bump' v1.0.37-2-0 "$(merge "$bump_version")"
expect 'task edit'    v1.0.37-2-1 "$(merge "$edit_task")"
expect 'template'     v1.0.37-2-2 "$(merge "$edit_template")"

scenario 'A version bump merged after other role changes'
expect 'task edit'    v1.0.37-1-2 "$(merge "$edit_task")"
expect 'version bump' v1.0.37-2-0 "$(merge "$bump_version")"

# The Dockerfile reaches the role only through a new image, whose tag then
# gets bumped in defaults/main.yml.
scenario 'Commits that do not affect the role'
expect 'README'     ''          "$(merge "$edit_readme")"
expect 'a script'   ''          "$(merge "$edit_script")"
expect 'Dockerfile' ''          "$(merge "$edit_dockerfile")"
expect 'meta'       v1.0.37-1-2 "$(merge "$edit_meta")"

scenario 'Release numbers past 9'
for release_number in 2 3 4 5 6 7 8 9 10; do
	git tag "v1.0.37-1-$release_number"
done
expect 'a task' v1.0.37-1-11 "$(merge "$edit_task")"

# The image tags of this repository (`1.0.37-1`, without a `v`) live next to
# the role's tags, and must not be read as releases of the role.
scenario 'Image tags next to the role tags'
git tag '1.0.37-1'
git tag '1.0.37-2'
expect 'a task' v1.0.37-1-2 "$(merge "$edit_task")"

# The version contains a dash of its own, so the release history of a longer
# version sharing this prefix must not be read as this one's.
scenario 'Tags of a longer version sharing a prefix'
git tag 'v1.0.37-1-0-legacy'
expect 'a task' v1.0.37-1-2 "$(merge "$edit_task")"

scenario 'Reverting to an already released version'
merge "$bump_version" > /dev/null
# The role is now identical to what v1.0.37-1-1 already published, so there is
# nothing new to release.
expect 'a revert' ''          "$(merge "$revert_version")"

scenario 'Reverting to an already released version, with a change'
merge "$bump_version" > /dev/null
expect 'a revert' v1.0.37-1-2 "$(merge "$revert_version && $edit_task")"

# A new tinc release is released from 0, exactly like an image rebuild,
# because the release counter is per version and it has no releases yet.
scenario 'A new tinc release'
expect 'tinc bump' v1.0.38-0-0 "$(merge 'write_defaults 1.0.38-0')"

scenario 'A version value carrying a leading v does not double it in the tag'
expect 'version bump' v1.0.37-2-0 "$(merge "$prefix_version")"

# The decoy variables in defaults/main.yml must not be picked up. If the script
# keyed on `tinc_container_image_tag`, it would read the Jinja expression
# `{{ tinc_version }}` and produce a nonsensical tag; if it keyed on the
# commented-out line, it would produce v9.9.9-0-0.
scenario 'Decoy variables around the version are ignored'
expect 'task edit' v1.0.37-1-2 "$(merge "$edit_task")"

if [ "$failures" -gt 0 ]; then
	echo >&2 "$failures scenario(s) behaved unexpectedly"
	exit 1
fi

echo 'All scenarios behaved as expected'
