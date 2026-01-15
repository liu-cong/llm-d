#!/bin/bash
# Benchmark Parameter Sweep Generator
# Usage: ./generate.sh <overlay> [helm-options...]
#
# Examples:
#   ./generate.sh gke -f examples/dp8-tp1.yaml
#   ./generate.sh gke --set name=sweep-1 --set dpSizeLocal=4

set -euo pipefail

# 1. Path Resolution
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
CHART_DIR="${SCRIPT_DIR}/chart"

# Allow override, otherwise resolve from script location
if [ -z "${MODELSERVER_DIR:-}" ]; then
    MODELSERVER_DIR="$(dirname "$SCRIPT_DIR")"
    if [ "$(basename "$MODELSERVER_DIR")" == "manifests" ] && [ -d "${MODELSERVER_DIR}/modelserver" ]; then
        MODELSERVER_DIR="${MODELSERVER_DIR}/modelserver"
    fi
fi

# Debug
echo "Debug: Modelserver dir: $MODELSERVER_DIR" >&2

# 2. Argument Parsing
if [ $# -lt 1 ]; then
    echo "Usage: $0 <overlay> [helm-options...] [--output-dir <dir>]"
    exit 1
fi

OVERLAY="$1"
shift

OUTPUT_DIR=""
HELM_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) HELM_ARGS+=("$1"); shift ;;
    esac
done

OVERLAY_DIR="${MODELSERVER_DIR}/${OVERLAY}"
if [ ! -d "$OVERLAY_DIR" ]; then
    echo "Error: Overlay directory not found: ${OVERLAY_DIR}" >&2
    exit 1
fi

# 3. Tool Check
command -v helm &>/dev/null || { echo "Error: helm not found"; exit 1; }
# yq is NO LONGER REQUIRED

# 4. Generate
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Link base overlay
ln -s "${OVERLAY_DIR}" "${TEMP_DIR}/base-overlay"

# Render Kustomization directly from Helm
helm template sweep-patches "${CHART_DIR}" "${HELM_ARGS[@]}" > "${TEMP_DIR}/kustomization.yaml"

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
