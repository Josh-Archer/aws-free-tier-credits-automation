# Free-tier task plugins

This directory holds the **task catalog** and **plugins** used by `run_and_cleanup.sh` / `run_and_cleanup.ps1`.

When AWS updates the free-tier credits program, add or adjust tasks here without rewriting the runners.

## Layout

| Path | Purpose |
|------|---------|
| `catalog.json` | Source of truth: task ids, credits, defaults, **last verified** date |
| `plugins/<id>.sh` | Bash plugin: `task_<id>_check_perm`, `task_<id>_provision`, `task_<id>_cleanup` |
| `plugins/<id>.ps1` | PowerShell plugin: `Invoke-Task<Name>Check/Provision/Cleanup` |

## Adding a new task

1. Append an entry to `catalog.json` (`id`, `name`, `description`, `credit_usd`, `default_enabled`, `plugin`).
2. Create `plugins/<plugin>.sh` with the three `task_<plugin>_*` functions.
3. Create `plugins/<plugin>.ps1` with Check / Provision / Cleanup functions and register them in the runner’s plugin map (PowerShell) — the bash runner auto-discovers from the catalog.
4. Bump `last_verified` in `catalog.json` and update the root `README.md` task table.
5. Skip or enable via `--skip-<id>` / `--only <ids>` (bash) or `-Skip` / `-Only` (PowerShell).

## Verifying against AWS

Re-check the AWS Free Tier / Billing console and set `last_verified` (ISO date) whenever credits or required actions change.
