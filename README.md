# Alfred Install

Canonical machine bootstrap and cleanup for Alfred.

Hosted architecture constraints live in:
- `alfreds-inc/alfred/docs/cloud_runtime_invariants.md`

This repo owns:
- machine bootstrap
- repo checkout/update
- install state and cloud bootstrap file layout
- cleanup and decommission foundations

This repo does not own:
- company profile collection
- onboarding flow state
- product secrets entry
- browser auth

## Install Modes

### Local

Local self-host remains the default:

```bash
curl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/install.sh | bash
```

Equivalent explicit form:

```bash
bash install.sh --mode local
```

Current local installs still fetch the private `alfreds-inc/alfred` repo through
GitHub CLI and delegate into the runtime repo installer. The installer stops
after the core stack is ready, prompts for Anthropic/OpenAI keys during local
interactive installs, then hands the remaining product setup off to Alfred's
guided CLI commands:

```bash
alfred telegram
alfred mail
alfred entities
```

Useful local variants:

```bash
bash install.sh --mode local --dev
bash install.sh --mode local --migrate-db ~/Documents/Empresa/_Index/finance_ops.sqlite
bash install.sh --mode local --launchd
bash install.sh --mode local --summary
```

### Cloud

Cloud mode is operator-run VM bootstrap for hosted Alfred runtimes:

```bash
bash install.sh --mode cloud --enrollment-token <one-time-token>
```

Cloud mode is infra-only:
- installs host prerequisites
- enrolls the VM with Alfred Cloud
- writes runtime cloud bootstrap files under the Alfred data dir
- clones or updates the `alfred` runtime repo
- delegates into the runtime installer with cloud deployment env

Cloud mode does not collect:
- company name
- owner email
- Telegram configuration
- AI keys
- other customer business settings

Those belong in browser onboarding on the runtime product surface.

Current scaffolding notes:
- cloud mode is Linux-only in v1
- the runtime repo still owns the actual hosted service wiring and health bootstrap
- this repo now persists the installer/cloud contract so cleanup and future runtime work have a stable base

Cloud-specific environment knobs:

```bash
export ALFRED_CLOUD_API_BASE_URL=https://cloud.alfred.example
export ALFRED_CLOUD_ENROLLMENT_URL=https://cloud.alfred.example/v1/runtimes/enroll
export ALFRED_CLOUD_MACHINE_REGION=mad
export ALFRED_CLOUD_TUNNEL_PROVIDER=wireguard
```

Dev/test only:

```bash
export ALFRED_CLOUD_ENROLLMENT_STUB_FILE=/path/to/enrollment-response.json
```

## Installer State Files

The installer now writes:

- `${ALFRED_DATA_DIR}/install/install-state.env`
  - non-secret install metadata for cleanup/supportability
- `${ALFRED_DATA_DIR}/config/cloud-bootstrap.env`
  - cloud runtime bootstrap env, including runtime identity/secret
- `${ALFRED_DATA_DIR}/config/tunnel.env`
  - cloud tunnel provider/config payload

Rules:
- `claim_url` from cloud enrollment is printed once and is not persisted to disk
- `install-state.env` is non-secret
- cloud bootstrap files are intended to be `0600`

## Cleanup

Default cleanup remains narrow:

```bash
bash cleanup.sh --dry-run
bash cleanup.sh -y
```

Remote fallback:

```bash
curl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/cleanup.sh | bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/alfreds-inc/alfred-install/main/cleanup.sh | bash -s -- -y
```

Cloud-aware cleanup behavior:
- detects install mode from `install-state.env` when present
- reuses recorded repo/data/unit paths when present
- attempts best-effort cloud runtime decommission before local deletion
- supports `--keep-cloud-registration` for same-VM repair flows

Examples:

```bash
bash cleanup.sh -y --keep-watch-dir
bash cleanup.sh -y --keep-cloud-registration
bash cleanup.sh -y --purge-openclaw-cli
bash cleanup.sh -y --purge-telegram-token
bash cleanup.sh -y --purge-all
```

What cleanup does not remove by default:
- shared Node/pnpm/nvm/gh installs
- Alfred Cloud tenant membership or user accounts

## Help Output

```bash
bash install.sh --help
bash cleanup.sh --help
```
