#!/bin/bash
# Collect results from a bench pod that finished (or will finish) but whose
# launcher died. Waits for /workspace/results/DONE, chunk-copies the report
# tarball (large kubectl cp streams get reset on flaky links), extracts into
# results/<run-name>/, and deletes the pod + its secret/configmap.
#
# Usage: ./collect_results.sh <run-dir> <run-name> [--keep]
set -uo pipefail

RUN_DIR="${1:?run dir required}"
RUN_NAME="${2:?run name required}"
KEEP="${3:-}"
KCTX="gke_conliu-gke-dev_us-west8-c_us-west8"
NS=glm-bench
K=(kubectl --context "$KCTX" -n "$NS")

echo ">>> [$RUN_NAME] waiting for DONE marker"
while ! "${K[@]}" exec "$RUN_NAME" -c bench -- test -f /workspace/results/DONE 2>/dev/null; do
  phase=$("${K[@]}" get pod "$RUN_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)
  [ "$phase" != "Running" ] && [ "$phase" != "unknown" ] && echo "!!! pod phase=$phase" && break
  sleep 30
done

echo ">>> [$RUN_NAME] chunking results in pod"
"${K[@]}" exec "$RUN_NAME" -c bench -- sh -c \
  "cd /workspace/results && tar czf /tmp/results.tgz --exclude=hf-cache . && cd /tmp && split -b 8m results.tgz chunk_" || exit 1
SIZES=$("${K[@]}" exec "$RUN_NAME" -c bench -- sh -c "cd /tmp && stat -c '%n %s' chunk_*")

mkdir -p "$RUN_DIR/results/$RUN_NAME"
cd "$RUN_DIR/results/$RUN_NAME"
: > results.tgz
echo "$SIZES" | while read -r name want; do
  got=0
  for attempt in $(seq 1 10); do
    "${K[@]}" cp -c bench "$NS/$RUN_NAME:/tmp/$name" "$name" 2>/dev/null
    got=$(stat -f%z "$name" 2>/dev/null || echo 0)
    [ "$got" = "$want" ] && break
    sleep 4
  done
  [ "$got" = "$want" ] || { echo "!!! $name incomplete ($got/$want)"; exit 1; }
  echo ">>> $name ok"
done || exit 1
for f in chunk_*; do cat "$f" >> results.tgz; done
tar xzf results.tgz || exit 1
rm -f results.tgz chunk_*
echo ">>> [$RUN_NAME] extracted: $(ls -d reports-* 2>/dev/null)"

if [ "$KEEP" != "--keep" ]; then
  "${K[@]}" delete pod "$RUN_NAME" --wait=false
  "${K[@]}" delete secret "${RUN_NAME}-token" --ignore-not-found
  "${K[@]}" delete configmap "${RUN_NAME}-config" --ignore-not-found
fi
echo ">>> [$RUN_NAME] done"
