# Alfred Install

Canonical dedicated installer and cleanup for Alfred.

## Install

Fresh machine:

```bash
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash
```

The installer uses GitHub CLI to clone the private `sinapsysxyz/alfred` repo.
If `gh` is not already authenticated, it prompts for a GitHub token with read access to that repo. The normal interactive flow then installs the Alfred prerequisites, prompts for `ANTHROPIC_API_KEY` / optional `OPENAI_API_KEY`, provisions the OpenClaw workspace, optionally configures Telegram, and leaves email setup for later with `alfred mail setup`.

Advanced / CI alternative if you want to provide the GitHub token up front:

```bash
GITHUB_TOKEN=ghp_your_token_here curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash
```

Local clone of this install repo:

```bash
bash install.sh
```

Advanced / CI modes:

```bash
bash install.sh --dev
bash install.sh --migrate-db ~/Documents/Empresa/_Index/finance_ops.sqlite
bash install.sh --launchd
bash install.sh --skip-openclaw-wizard        # CI: still provisions OpenClaw, skips interactive OpenClaw prompts
```

The installer clones or reuses the Alfred repo under `~/.local/opt/alfred`, runs Alfred's host bootstrap plus product installer from that checkout, installs a user-local `alfred` launcher at `~/.local/bin/alfred`, and can prompt to add `~/.local/bin` to `~/.zshrc`. On first install with no Alfred DB it initializes a fresh local DB automatically. OpenClaw is mandatory — every install provisions the OpenClaw workspace under `~/.openclaw/workspace/alfred`.

## Cleanup

After Alfred is installed, the normal uninstall path is:

```bash
alfred cleanup --dry-run
alfred cleanup -y
```

Public fallback if the CLI is already gone:

```bash
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/cleanup.sh | bash -s -- -y
```

Safer — preview first, then apply:

```bash
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/cleanup.sh | bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/cleanup.sh | bash -s -- -y
```

From a local clone of this repo:

```bash
bash cleanup.sh --dry-run
bash cleanup.sh -y
```

Default cleanup removes only Alfred-owned state. Shared tooling (Node, pnpm, nvm, `gh`, `openclaw`) is preserved so unrelated projects keep working. Common variants:

```bash
bash cleanup.sh -y --keep-watch-dir            # preserve ~/Documents/Alfred
bash cleanup.sh -y --keep-repo                 # keep the repo, wipe runtime state + .env.local
bash cleanup.sh -y --purge-openclaw-cli        # also remove the OpenClaw CLI
bash cleanup.sh -y --purge-telegram-token      # also remove ~/.openclaw/secrets/telegram-bot-token
bash cleanup.sh -y --purge-all                 # everything including shared tooling
```

See `bash cleanup.sh --help` for the full flag list and environment overrides.

### Reinstall after cleanup

```bash
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash
```

### What cleanup does NOT touch by default

- `~/.openclaw/` itself or any non-Alfred workspace under the OpenClaw parent dir.
- Other users' Telegram tokens or OpenClaw secrets.
- Shared system packages (Node, pnpm, nvm, `gh`).
- Arbitrary paths outside the Alfred defaults — the script refuses to remove anything that doesn't look like an Alfred-owned location.

If you need a truly nuclear reset, `--purge-all` is the shortcut, but read `--help` before using it on a shared box.
