# Alfred Install Agents

Start here before changing installer, cleanup, enrollment, or runtime bootstrap behavior.

## Canonical Docs

- `README.md`
- `alfreds-inc/alfred/docs/cloud_runtime_invariants.md`
- `/Users/machine/.claude/plans/alfred-install-bootstrap-plan.md`

## Repo Role

`alfred-install` owns:

- machine bootstrap
- repo checkout/update
- local vs cloud install mode contract
- cleanup and decommission foundations

It does not own:

- company onboarding
- customer business configuration
- browser auth
- runtime product state

## Current Defaults

- `local` is the default install mode
- `cloud` is explicit and infra-only
- cloud mode is Linux-only in v1
- browser onboarding is the primary product setup path

## Keep Stable

- mode contract
- install-state file layout
- runtime enrollment handoff contract
- public installer and cleanup entrypoints
