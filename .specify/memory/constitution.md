<!--
Sync Impact Report:
- Version change: 0.0.0 → 1.0.0
- Modified principles: N/A (initial creation)
- Added sections: Core Principles (4), Development Workflow, Governance
- Removed sections: None
- Templates requiring updates:
  - .specify/templates/plan-template.md ✅ (already has Constitution Check gate and Performance Goals field)
  - .specify/templates/spec-template.md ✅ (already has acceptance scenarios, edge cases, functional requirements)
  - .specify/templates/tasks-template.md ✅ (already supports test-first task ordering and phased delivery)
- Follow-up TODOs: None
-->

# NVIDIA Boot Optimize Constitution

## Core Principles

### I. Code Quality

All code MUST be clear, maintainable, and well-structured.

- Every module MUST have a single, well-defined responsibility
- Shell scripts MUST pass ShellCheck with zero warnings
- Python code MUST pass flake8/ruff with zero errors
- All functions MUST have explicit input/output contracts
  (parameters documented, return values typed or described)
- Dead code MUST be removed; commented-out code is not permitted
  in committed files
- Magic numbers and hard-coded paths MUST be extracted into
  named constants or configuration variables

### II. Testing Standards

All changes MUST be validated by automated tests before merge.

- Every new feature MUST include at least one integration test
  that exercises the end-to-end boot path on target hardware
  or an emulated environment
- Unit tests MUST cover all utility functions and parsers
- Tests MUST be deterministic — no reliance on timing, network,
  or uncontrolled external state
- Regression tests MUST be added for every confirmed bug fix
- Test names MUST describe the scenario under test, not the
  implementation detail (e.g., `test_boot_completes_under_5s`
  not `test_function_returns_true`)
- CI MUST block merge on any test failure

### III. User Experience Consistency

All user-facing output and interfaces MUST be predictable and
uniform across the project.

- CLI tools MUST use consistent argument naming conventions
  (`--timeout`, `--verbose`, `--device`) across all scripts
- Error messages MUST include: what failed, why it failed, and
  a suggested corrective action
- Progress output MUST use a uniform format (timestamped lines
  to stdout, errors to stderr)
- Configuration MUST follow a single canonical format (YAML or
  environment variables) — never mix formats within a feature
- Documentation MUST be updated in the same commit as the code
  change it describes

### IV. Performance Requirements

Boot time optimization is the primary deliverable; every change
MUST be measured against performance baselines.

- A performance baseline MUST be established and recorded before
  any optimization work begins
- Every optimization MUST include before/after timing measurements
  with methodology documented
- Changes that regress boot time by more than 5% MUST NOT be
  merged without explicit justification and approval
- Performance-critical paths MUST be profiled, not guessed at;
  optimizations MUST target measured bottlenecks
- Target boot time thresholds MUST be defined per device/platform
  and tracked in CI where feasible

## Development Workflow

- Feature work MUST happen on dedicated branches
- Commits MUST be atomic — one logical change per commit
- Commit messages MUST follow Conventional Commits format
  (`feat:`, `fix:`, `perf:`, `docs:`, `test:`, `chore:`)
- Code review MUST verify compliance with all four principles
  before approval
- Merge MUST require passing CI (tests + linting)

## Governance

This constitution supersedes all informal practices and ad-hoc
conventions. All contributors MUST follow these principles.

- Amendments require: a documented rationale, review by at least
  one other contributor, and a version bump to this file
- Version follows semantic versioning: MAJOR for principle
  removal/redefinition, MINOR for additions, PATCH for wording
- Complexity additions MUST be justified against the performance
  and code quality principles
- Disputes default to whichever interpretation best serves boot
  time reduction without sacrificing safety

**Version**: 1.0.0 | **Ratified**: 2026-05-14 | **Last Amended**: 2026-05-14
