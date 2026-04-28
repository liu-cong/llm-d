---
name: verify-guide
description: Performs end-to-end verification of llm-d user guides. This skill validates documentation integrity, repository-wide dependency consistency, and manifest correctness through static analysis, dependency mapping, and optional cluster-based validation.
---

# llm-d Guide Verification System

A professional diagnostic skill designed to ensure the integrity and operability of llm-d user guides across the ecosystem.

## Primary Objective

To validate that an llm-d user guide (typically a `README.md` within a subdirectory under `guides/`, such as `guides/optimized-baseline/` or `guides/pd-disaggregation/`) is accurate, consistent with external dependencies, and technically sound.

## Verification Tiers

### Tier 1: Documentation Integrity (Static Analysis)
Perform a rigorous check of all static content within the guide.
- **Link/Path Validation**: Verify all internal links, external URLs, and relative file paths.
- **Formatting & Clarity**: Ensure compliance with project documentation standards.

### Tier 2: Ecosystem Consistency (Dependency Mapping)
Validate that changes to the guide do not break downstream or lateral dependencies across the `llm-d` ecosystem.

#### 2.1 CI/CD Workflow Alignment
- **Location**: `<repo-root>/.github/workflows/`
- **Action**: Inspect workflows (e.g., `e2e-*.yaml`, `test-guides.yaml`). Ensure that workflow matrices, path filters, and deployment steps align with the guide's current structure and logic.

#### 2.2 Cross-Guide Referencing
- **Location**: `<repo-root>/guides/`
- **Action**: Search (using `grep_search`) for mentions of the target guide in other `README.md` files. Ensure all references are current.

### Tier 3: Technical Validation (Dry-runs & E2E)
Validate the actual technical components described in the guide.

#### 3.1 Manifest Integrity (Dry-runs)
- **Action**: Execute dry-runs for all Kubernetes manifests (Helm, Helmfile, or Kustomize).
- **Goal**: Confirm that all templates render valid YAML without schema or logical errors.

#### 3.2 Cluster-Level Validation (E2E)
- **Condition**: **Mandatory ONLY when explicitly requested.**
- **Action**: Deploy the stack step-by-step into the target Kubernetes cluster. Verify an inference request can be successfully processed. When needed, create the `llm-d-hf-token` secret using the `$HF_TOKEN` environment variable if set, otherwise use the `HF_TOKEN` in `../../.env`.
- **Execution Policy**: Fail-fast. Stop execution upon initial failure, capture the error state, and propose remediation.
- **Workarounds Prohibited**: Do not modify the guide's core components (such as the model server image, required resources, or dependent features) to bypass failures. The objective is to test the guide exactly as documented. If a step fails, capture the failure, report it, and terminate the verification tier.

#### 3.3 Benchmarking Validation
- **Condition**: **Mandatory ONLY when explicitly requested.**
- **Action**: Execute the benchmark following the guide's instructions.
    - Download the benchmark script (e.g., `run_only.sh`).
    - Download/prepare the workload template (e.g., `shared_prefix.yaml`).
    - Execute the benchmark (e.g., `./run_only.sh -c config.yaml -o ./results`).
- **Goal**: Verify that the benchmark can be executed and results are generated.
- **Execution Policy**: Capture benchmark results and include them in the report. If it fails, document the failure.

---

## Operational Guidelines

### Environment Awareness
- **Tool Failures**: If core binaries (`kubectl`, `helmfile`, `helm`) return exit code `-1` or encounter security policy blocks, document these as environment constraints and terminate the verification.
- **Network Resilience**: Note any external dependency failures (e.g., chart download timeouts) as environmental limitations rather than guide defects.

### Dependency Discovery Strategies
- Use `grep_search` to map the guide's footprint across the repository.
- Cross-reference with `helmfile.yaml` to identify involved components.

---

## Deliverable: Verification Report

Upon completion, generate a standardized `verification_report.md` in the designated output directory containing:

1. **Executive Summary**: 
    - Mission Status (PASS/FAIL/INCOMPLETE)
    - Scope (Target Guide, Branch, Environment)
2. **Detailed Diagnostics**:
    - **Tier 1 (Documentation)**: Tabular summary of link/path validation.
    - **Tier 2 (Ecosystem)**: Impact analysis on CI/CD, other guides, and the website repository.
    - **Tier 3 (Technical)**: Summary of dry-run execution, E2E deployment, and benchmark results (if requested).
3. **Identified Issues & Remediation**:
    - Classified list of defects (CRITICAL, MAJOR, MINOR).
    - Actionable fix recommendations for each identified issue.
