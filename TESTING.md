# Helm testing

This repo is the public bridge-only Helm checkout.

## CLI smoke checks

Run the core command checks:

```bash
node bin/helm.js --help
node bin/helm.js bridge --help
node bin/helm.js platforms --json
```

Validate the npm package payload:

```bash
npm run pack:dry-run
```

## Local prototype

Start the bridge stack:

```bash
cd /path/to/helm
scripts/prototype-up.sh
scripts/prototype-status.sh
```

Expected local services:

- bridge: `http://127.0.0.1:8787`
- codex app-server: `ws://127.0.0.1:6060`

Stop the stack:

```bash
scripts/prototype-down.sh
```

## Pairing

Print the pairing QR or setup link:

```bash
helm bridge pair
```

Expected result:

- the setup link uses a concrete reachable bridge address
- Tailscale is preferred over LAN addresses when available
- pairing token is stored locally

## Installer sandbox

Create an isolated install sandbox:

```bash
scripts/test-install-sandbox.sh
```

Run the assertion-based smoke pass and remove the sandbox afterward:

```bash
scripts/test-install-sandbox.sh --smoke --cleanup --no-runtime-start
```

Expected result:

- Helm installs into a temporary `HOME`
- runtime shims and shell integration are written in the sandbox
- `helm help` and `helm platforms --json` succeed there
- stable repo-local links are refreshed under `.runtime/test-install-sandbox/`

Useful follow-up commands:

```bash
source ./.runtime/test-install-sandbox/latest-env.sh
./.runtime/test-install-sandbox/latest-run.sh scripts/prototype-status.sh
./.runtime/test-install-sandbox/latest-run.sh zsh -ic 'command -v codex && command -v claude && ls -la ~/.local/bin'
```

## Public repo guard

Verify the public repo policy explicitly:

```bash
scripts/check-public-repo.sh
```

That check fails if the public repo contains:

- app code
- private repo-name references
- absolute local user paths
- generated artifacts that should not be versioned
