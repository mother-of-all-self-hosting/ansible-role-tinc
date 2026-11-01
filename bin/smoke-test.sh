#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spatterlight
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Starts two tinc nodes from the given image on a throwaway container network
# and checks that they connect to each other.
#
# Usage: bin/smoke-test.sh <image>
#
# The nodes use dummy devices, so no tun device or capability other than the
# one the role also grants (DAC_READ_SEARCH) is needed.

set -euo pipefail

image="${1:?Usage: $0 <image>}"
name="tinc-smoke-test-$$"
workdir="$(mktemp -d)"

cleanup() {
	docker rm -f "$name-alpha" "$name-beta" > /dev/null 2>&1 || true
	docker network rm "$name" > /dev/null 2>&1 || true
	rm -rf "$workdir"
}
trap cleanup EXIT

docker run --rm "$image" --version

for node in alpha beta; do
	mkdir -p "$workdir/$node/hosts"
	printf 'Name = %s\nDeviceType = dummy\n' "$node" > "$workdir/$node/tinc.conf"

	# Writes rsa_key.priv, and the public key into hosts/<node>.
	docker run --rm --user "$(id -u):$(id -g)" --volume "$workdir/$node:/etc/tinc" "$image" --config=/etc/tinc --generate-keys=2048
done

printf 'Address = %s\n' "$name-alpha" >> "$workdir/alpha/hosts/alpha"
printf 'ConnectTo = alpha\n' >> "$workdir/beta/tinc.conf"
cp "$workdir/alpha/hosts/alpha" "$workdir/beta/hosts/"
cp "$workdir/beta/hosts/beta" "$workdir/alpha/hosts/"

docker network create "$name" > /dev/null

for node in alpha beta; do
	docker run --detach --name "$name-$node" --network "$name" \
		--cap-drop=ALL --cap-add=DAC_READ_SEARCH --read-only --tmpfs=/run \
		--mount "type=bind,src=$workdir/$node,dst=/etc/tinc,ro" \
		"$image" --config=/etc/tinc --no-detach --debug=1 > /dev/null
done

for _ in $(seq 1 30); do
	if docker logs "$name-beta" 2>&1 | grep -q 'Connection with alpha .* activated'; then
		echo "Smoke test passed"
		exit 0
	fi
	sleep 1
done

echo >&2 "The nodes did not connect to each other"
for node in alpha beta; do
	echo >&2 "--- $node"
	docker logs "$name-$node" >&2
done
exit 1
