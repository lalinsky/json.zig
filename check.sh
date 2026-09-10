#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

CI_MODE=false

usage() {
  echo "Usage: $0 [--ci]"
}
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=== Formatting code ==="
if [ "$CI_MODE" = true ]; then
    echo "Checking formatting (CI mode)..."
    zig fmt --check .
else
    echo "Formatting code..."
    zig fmt .
fi

echo "=== Running tests ==="
zig build test --summary all
