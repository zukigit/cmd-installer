#!/bin/sh
# Run the test cases on the host and in local podman images (never pulls).
# Usage: tests/run.sh

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGES="docker.io/redhat/ubi10:latest ghcr.io/zeroclaw-labs/zeroclaw:debian"

summary=""
failed=0

record() {
	summary="$summary
  $1  $2"
	[ "$1" = "FAIL" ] && failed=1
	return 0
}

if command -v shellcheck >/dev/null 2>&1; then
	echo "== shellcheck"
	if shellcheck -s sh "$REPO/cmd-installer.sh" "$REPO/tests/cases.sh" "$REPO/tests/run.sh"; then
		record PASS shellcheck
	else
		record FAIL shellcheck
	fi
else
	record SKIP "shellcheck (not installed)"
fi

echo
echo "== host"
if sh "$REPO/tests/cases.sh" "$REPO/cmd-installer.sh"; then
	record PASS host
else
	record FAIL host
fi

for img in $IMAGES; do
	echo
	echo "== $img"
	if ! command -v podman >/dev/null 2>&1; then
		record SKIP "$img (podman not installed)"
		continue
	fi
	if ! podman image exists "$img"; then
		record SKIP "$img (image not downloaded)"
		continue
	fi
	if podman run --rm --pull=never --user 1000:1000 \
		--security-opt label=disable \
		--entrypoint /bin/sh \
		-v "$REPO:/src:ro" \
		"$img" /src/tests/cases.sh /src/cmd-installer.sh; then
		record PASS "$img"
	else
		record FAIL "$img"
	fi
done

echo
echo "== summary$summary"
exit "$failed"
