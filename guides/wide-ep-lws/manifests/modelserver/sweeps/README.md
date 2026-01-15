# Benchmark Parameter Sweep System

Helm-based templating layer for benchmarking.

## Usage

```bash
# Default config
./generate.sh gke

# Using values file
./generate.sh gke -f examples/dp8-tp1.yaml

# Inline overrides (Running Parallel Sweeps)
./generate.sh gke --set name=sweep-1 --set dpSizeLocal=4
```

## Parallel Sweeps
Use unique `name` values to deploy simultaneous benchmarks:

```bash
./generate.sh gke --set name=sweep-a --set dpSizeLocal=8 | kubectl apply -f -
./generate.sh gke --set name=sweep-b --set dpSizeLocal=4 | kubectl apply -f -
```
