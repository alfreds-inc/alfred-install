# Alfred Install

Canonical dedicated installer for Alfred.

## Usage

Fresh machine:

```bash
curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash
```

The installer uses GitHub CLI to clone the private `sinapsysxyz/alfred` repo.
If `gh` is not already authenticated, it will prompt for a GitHub token with read access to that repo.
You can also provide it up front:

```bash
GITHUB_TOKEN=ghp_your_token_here curl -fsSL https://raw.githubusercontent.com/sinapsysxyz/alfred-install/main/install.sh | bash
```

Local clone of this install repo:

```bash
bash install.sh
```

Common modes:

```bash
bash install.sh --dev
bash install.sh --fresh-db
bash install.sh --migrate-db ~/Documents/Empresa/_Index/finance_ops.sqlite
bash install.sh --launchd
bash install.sh --with-openclaw
```

The installer clones or reuses the Alfred repo, runs Alfred's repo-local installer, installs a user-local `alfred` launcher at `~/.local/bin/alfred`, and can prompt to add `~/.local/bin` to `~/.zshrc`.
