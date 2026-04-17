# Distribution

Helm can support two user-facing install paths that we can realistically own:

1. `npm install -g @devlin/helm`
2. `brew tap devlln/helm && brew install devlln/helm/helm`

After either install, the user runs:

```bash
helm setup
```

## Why not `brew install helm` or `npm install -g helm`?

Those unscoped names are already taken outside this project:

- Homebrew `helm` is the Kubernetes package manager.
- npm `helm` is an unrelated browser router package.

That means Helm should keep the runtime command name `helm`, but distribution should use:

- the scoped npm package `@devlin/helm`
- the `homebrew-helm` tap, exposed to users as `devlln/helm`

## npm release

1. Verify the package payload:

```bash
npm run pack:dry-run
```

2. Publish the package publicly:

```bash
npm publish --access public
```

3. Validate the install flow in a clean shell:

```bash
npm install -g @devlin/helm
helm --help
helm setup
```

## Homebrew tap release

This repo does not replace Homebrew core. Instead, publish a formula in a dedicated tap repository named `homebrew-helm`.

1. Create a Git tag and GitHub release tarball:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

2. Compute the public release tarball checksum:

```bash
curl -L "https://codeload.github.com/DEVLlN/helm/tar.gz/refs/tags/vX.Y.Z" | shasum -a 256
```

3. Render the formula:

```bash
node scripts/render-homebrew-formula.mjs --version X.Y.Z --sha256 <sha256>
```

4. Commit that output as `Formula/helm.rb` in the `homebrew-helm` tap repo, then users can install with:

```bash
brew tap devlln/helm
brew install devlln/helm/helm
helm setup
```

## Keeping releases updated

This repo now supports a tag-driven release flow in GitHub Actions:

- `.github/workflows/ci.yml` validates the CLI surface, npm package payload, sandbox installer, and generated Homebrew formula on every push and pull request.
- `.github/workflows/release.yml` runs on `v*` tags, publishes `@devlin/helm` to npm, creates a GitHub release if needed, and updates `DEVLlN/homebrew-helm` with the new `Formula/helm.rb`.

Required repo secrets in `DEVLlN/helm`:

- `NPM_TOKEN`: npm automation token with publish rights for `@devlin/helm`
- `HOMEBREW_TAP_TOKEN`: GitHub token with write access to `DEVLlN/homebrew-helm`

The steady-state release flow is:

```bash
git tag vX.Y.Z
git push origin main --follow-tags
```

That keeps npm and Homebrew in sync off the same version tag instead of relying on manual formula edits or manual `npm publish`.

## User-facing install copy

Use this wording in docs and release notes:

```bash
# npm
npm install -g @devlin/helm
helm setup

# Homebrew
brew tap devlln/helm
brew install devlln/helm/helm
helm setup
```
