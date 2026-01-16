# Benchmark Parameter Sweep System

A modular, Helm-based templating system for benchmark parameter sweeps, built on top of Kustomize.

## Directory Structure
```
sweeps/
├── generate.sh         # Main orchestration script
├── README.md           # This file
└── charts/
    ├── base/           # Core sweep logic (patches env vars, names, replicas)
    │   ├── examples/   # Standard sweep configurations
    │   └── generated/  # Default output directory for base sweeps
    └── custom/         # Example of a custom overlay chart
```

## Basic Usage

```bash
# Run a base sweep (uses default resources in values.yaml)
./generate.sh -f charts/base/examples/dp8-tp1.yaml

# To use a different overlay (e.g. gke), override the 'resources' in CLI:
./generate.sh --set "resources={../../../../manifests/modelserver/gke}"
```

## Advanced Usage

### 1. Parallel Sweeps
Use unique `name` values to deploy simultaneous benchmarks:
```bash
./generate.sh --set name=sweep-a --set dpSizeLocal=8 | kubectl apply -f -
./generate.sh --set name=sweep-b --set dpSizeLocal=4 | kubectl apply -f -
```

### 2. Chart Composition (Layering)
You can apply a second chart on top of the base sweep output:
```bash
# 1. Generate base artifacts
./generate.sh

# 2. Apply custom chart on top of base output
./generate.sh --chart charts/custom
```

### 3. Artifact Persistence
By default, artifacts are saved in the `generated/` subfolder of the chart being used.
*   Base: `charts/base/generated/kustomization.yaml`
*   Custom: `charts/custom/generated/kustomization.yaml`

Use `--gen-dir` to override this.

---

## Development

### How it works
The `generate.sh` script follows this workflow:
1.  **Helm Templating**: Runs `helm template` on the selected chart. It uses the `resources` list from `values.yaml` (which should contain relative paths to your base k8s manifests).
2.  **Artifact Persistence**: Saves the rendered `kind: Kustomization` object to the chart's `generated/` folder.
3.  **Kustomize Build**: Runs `kustomize build` on that `generated/` folder to produce the final manifests.

### Adding New Parameters
1.  Add the parameter to `charts/base/values.yaml`.
2.  Update `charts/base/templates/kustomization.yaml` with a new `patch` targeting the relevant fields.
3.  **Patching Strategy**:
    *   **Strategic Merge**: Best for maps like `labels` or `annotations`. It merges keys rather than replacing the whole block.
    *   **JSON Patch (`op: replace`)**: Required for environment variables and lists where you want to target a specific index or avoid wiping out other items in the list.

### Creating a Custom Sweep Chart
1.  Create a folder in `charts/`.
2.  Add `Chart.yaml` and `values.yaml`.
3.  In `values.yaml`, set `resources` to point to `../base/generated`.
4.  Add your own patches in `templates/kustomization.yaml`.
