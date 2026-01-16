#!/bin/bash
# Benchmark Parameter Sweep Generator
# Usage: ./generate.sh [helm-options...]
#
# Examples:
#   ./generate.sh -f charts/base/examples/dp8-tp1.yaml
#   ./generate.sh --set name=sweep-1 --set dpSizeLocal=4

set -euo pipefail

# 1. Path Resolution
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
CHART_DIR="${SCRIPT_DIR}/charts/base"

# Debug
echo "Debug: Script dir: $SCRIPT_DIR" >&2

# 2. Argument Parsing
OUTPUT_DIR=""
GEN_DIR=""
CUSTOM_CHART=""
HELM_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --gen-dir)
            GEN_DIR="$2"
            shift 2
            ;;
        --chart)
            CUSTOM_CHART="$2"
            shift 2
            ;;
        *)
            HELM_ARGS+=("$1")
            shift
            ;;
    esac
done

# Resolve Chart
if [ -n "$CUSTOM_CHART" ]; then
    CHART_DIR="$CUSTOM_CHART"
fi

# 3. Tool Check
command -v helm &>/dev/null || { echo "Error: helm not found"; exit 1; }

# 4. Generate
# Default GEN_DIR to the chart's 'generated' directory if not specified
GEN_DIR="${GEN_DIR:-${CHART_DIR}/generated}"
TEMP_DIR="$GEN_DIR"
mkdir -p "$TEMP_DIR"

# Render Kustomization directly from Helm
# Disable set -u briefly to allow possibly empty HELM_ARGS array on old bash versions
set +u
helm template sweep-patches "${CHART_DIR}" \
  "${HELM_ARGS[@]}" > "${TEMP_DIR}/kustomization.yaml"
set -u

# Build Final Manifest
BUILD_CMD="kubectl kustomize"
if command -v kustomize &>/dev/null; then
    BUILD_CMD="kustomize build"
fi

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    $BUILD_CMD "$TEMP_DIR" > "${OUTPUT_DIR}/manifests.yaml"
    echo "Generated: ${OUTPUT_DIR}/manifests.yaml" >&2
else
    $BUILD_CMD "$TEMP_DIR"
fi

