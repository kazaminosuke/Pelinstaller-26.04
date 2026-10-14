#!/bin/bash
# Runs the UI test-suite inside a throwaway Ubuntu container.
# Usage: tests/run.sh [image]   (default ubuntu:24.04; needs docker)
set -eu
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-ubuntu:24.04}"
DOCKER="${DOCKER:-docker}"
exec $DOCKER run --rm -e PELINSTALLER_TEST_SANDBOX=1 -v "$REPO:/src:ro" "$IMAGE" bash /src/tests/ui_test.sh
