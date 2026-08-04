#!/bin/bash
# Launch one benchmark run as a pod on the us-west8 GKE cluster (in-cluster
# direct mode: bench -> gateway/service URL from the config's server.base_url;
# no external proxy or auth token needed).
#
# Usage: ./run_bench.sh <run-name> <config-file> [--keep]
#   <run-name>    lowercase DNS-safe name, e.g. sweep-c32
#   <config-file> inference-perf YAML
#   --keep        don't delete pod/configmap afterwards (debugging)
#
# The script blocks until the run finishes, then copies the report directory
# to results/<run-name>/ next to this script's parent folder.
set -euo pipefail

RUN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_NAME="${1:?run name required}"
CONFIG_FILE="${2:?config file required}"
KEEP="${3:-}"

PROJECT=supercomputer-testing
CLUSTER=a4-pr
ZONE=europe-west4  # regional cluster
NAMESPACE=glm-bench
IMAGE="${IMAGE:-us-central1-docker.pkg.dev/supercomputer-testing/inference-perf/inference-perf:weka-fast-bounded-teardown-server-prompt-tokens-20260717}"
KCTX="gke_supercomputer-testing_europe-west4_a4-pr"

# Retry helper: laptop<->cluster connections occasionally get reset mid-stream;
# kubectl cp/exec must survive transient failures instead of killing the run.
retry() {
  local n=0 max=5
  until "$@"; do
    n=$((n+1))
    [ "$n" -ge "$max" ] && echo "!!! command failed after $max attempts: $*" && return 1
    echo ">>> retry $n/$max: $*"
    sleep 10
  done
}

kubectl config get-contexts -o name | grep -q "^${KCTX}$" || \
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
KUBECTL=(kubectl --context "$KCTX" -n "$NAMESPACE")

kubectl --context "$KCTX" get ns "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl --context "$KCTX" create ns "$NAMESPACE"

echo ">>> [$RUN_NAME] creating configmap"
"${KUBECTL[@]}" delete configmap "${RUN_NAME}-config" --ignore-not-found >/dev/null
"${KUBECTL[@]}" create configmap "${RUN_NAME}-config" \
  --from-file=config.yaml="$CONFIG_FILE"

echo ">>> [$RUN_NAME] launching pod"
"${KUBECTL[@]}" delete pod "$RUN_NAME" --ignore-not-found --wait=true >/dev/null
sed -e "s|\${RUN_NAME}|$RUN_NAME|g" -e "s|\${IMAGE}|$IMAGE|g" \
  "$RUN_DIR/manifests/bench-pod.template.yaml" | "${KUBECTL[@]}" apply -f -

echo ">>> [$RUN_NAME] waiting for pod to start"
"${KUBECTL[@]}" wait --for=condition=Ready "pod/$RUN_NAME" --timeout=1800s || {
  "${KUBECTL[@]}" describe pod "$RUN_NAME" | tail -30; exit 1; }

mkdir -p "$RUN_DIR/results/$RUN_NAME" "$RUN_DIR/logs"
echo ">>> [$RUN_NAME] streaming bench logs"
"${KUBECTL[@]}" logs -f "$RUN_NAME" -c bench > "$RUN_DIR/logs/$RUN_NAME-bench.log" 2>&1 &
LOGPID=$!

# Wait for the DONE marker (written after inference-perf exits).
while ! "${KUBECTL[@]}" exec "$RUN_NAME" -c bench -- test -f /workspace/results/DONE 2>/dev/null; do
  if [ "$("${KUBECTL[@]}" get pod "$RUN_NAME" -o jsonpath='{.status.phase}')" != "Running" ]; then
    echo "!!! pod left Running state"; "${KUBECTL[@]}" get pod "$RUN_NAME"; break
  fi
  sleep 20
done
kill "$LOGPID" 2>/dev/null || true

echo ">>> [$RUN_NAME] copying results (chunked: large kubectl cp streams get reset)"
retry "${KUBECTL[@]}" exec "$RUN_NAME" -c bench -- sh -c \
  "cd /workspace/results && tar czf /tmp/results.tgz --exclude=hf-cache . && cd /tmp && rm -f chunk_* && split -b 8m results.tgz chunk_"
CHUNKS=$(retry "${KUBECTL[@]}" exec "$RUN_NAME" -c bench -- sh -c "cd /tmp && stat -c '%n %s' chunk_* | tr '\n' ';'" | tail -1)
case "$CHUNKS" in
  chunk_*) : ;;  # ok
  *) echo "!!! failed to enumerate result chunks (got: '$CHUNKS'); NOT cleaning up pod"; exit 1 ;;
esac
: > "$RUN_DIR/results/$RUN_NAME/results.tgz"
for entry in $(echo "$CHUNKS" | tr ';' ' '); do
  case "$entry" in chunk_*) name="$entry"; continue;; esac
  want="$entry"
  got=0
  for attempt in 1 2 3 4 5 6 7 8; do
    "${KUBECTL[@]}" cp -c bench "$NAMESPACE/$RUN_NAME:/tmp/$name" "$RUN_DIR/results/$RUN_NAME/$name" 2>/dev/null || true
    got=$(stat -f%z "$RUN_DIR/results/$RUN_NAME/$name" 2>/dev/null || echo 0)
    [ "$got" = "$want" ] && break
    sleep 5
  done
  [ "$got" = "$want" ] || { echo "!!! chunk $name incomplete ($got/$want)"; exit 1; }
  cat "$RUN_DIR/results/$RUN_NAME/$name" >> "$RUN_DIR/results/$RUN_NAME/results.tgz"
  rm -f "$RUN_DIR/results/$RUN_NAME/$name"
done
tar xzf "$RUN_DIR/results/$RUN_NAME/results.tgz" -C "$RUN_DIR/results/$RUN_NAME" && rm "$RUN_DIR/results/$RUN_NAME/results.tgz"
# bsdtar exits 0 on an empty archive — verify the report actually landed.
ls "$RUN_DIR/results/$RUN_NAME"/reports-*/summary_lifecycle_metrics.json >/dev/null 2>&1 || {
  echo "!!! extraction produced no reports; NOT cleaning up pod"; exit 1; }

if [ "$KEEP" != "--keep" ]; then
  echo ">>> [$RUN_NAME] cleanup"
  "${KUBECTL[@]}" delete pod "$RUN_NAME" --wait=false
  "${KUBECTL[@]}" delete configmap "${RUN_NAME}-config" --ignore-not-found
fi
echo ">>> [$RUN_NAME] done; results in $RUN_DIR/results/$RUN_NAME/"
