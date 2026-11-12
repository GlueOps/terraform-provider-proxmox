# GlueOps fork

This repo is GlueOps' long-term fork of [bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox).
It is upstream plus one resource, `proxmox_cloudinit_bootstrap`, which bootstraps VMs from a temporary NoCloud seed ISO
without SSH. The same code is offered upstream as bpg PR #3260.

Use it as:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/GlueOps/proxmox"
      version = "0.0.1" # pin exactly
    }
  }
}
```

Use the full source address in both Terraform and OpenTofu. With OpenTofu the short `GlueOps/proxmox` resolves to the
OpenTofu registry instead, which is a different address in state (and works only once the provider is listed there).

Versions are our own, starting at 0.0.1. Each release's notes say which upstream version it's based on.
`.glueops/upstream-tag` records the upstream tag that `main` is currently synced to.

Agents: read [AGENTS.md](AGENTS.md) too. It holds the commands and commit rules.

## How the fork differs from upstream

[`.glueops/allowlist`](.glueops/allowlist) lists every path where we differ. `scripts/glueops-sync-fixup.sh check`
fails if the tree differs anywhere else.

| Kind     | Examples                                                    | In a sync                                                           |
| -------- | ----------------------------------------------------------- | ------------------------------------------------------------------- |
| owned    | release-please files, `CHANGELOG.md`, `AGENTS.md`, this file | ours always wins; upstream's change is reviewed (see the table below) |
| deleted  | upstream-only workflows, `.claude/`, `.devcontainer/`       | stays deleted                                                       |
| kept     | `test.yml`, `golangci-lint.yml`                             | taken from upstream; risky changes stop the sync                   |
| feature  | `fwprovider/nodes/cloudinitbootstrap/`, 5 shared files      | conflicts are resolved by hand                                      |
| rebranded | docs/examples `source` and version lines, the README and index notes | rebuilt from upstream by the script                            |

The **rebranded** files aren't listed in the allowlist. The script derives them (`REBRAND_SCOPE`) and checks that ours
equals upstream's copy, rebranded.

## Clone setup (once)

```sh
git clone https://github.com/GlueOps/terraform-provider-proxmox.git && cd terraform-provider-proxmox
git remote rename origin glueops
git remote add origin https://github.com/bpg/terraform-provider-proxmox.git
git config remote.origin.tagOpt --no-tags    # never fetch upstream's tags; they'd collide with ours
git config remote.glueops.tagOpt --no-tags
git fetch --multiple origin glueops
git fetch --no-tags origin tag "$(cat .glueops/upstream-tag)"   # the scripts compare against it
```

After this, local `main` tracks `glueops/main`, and `origin/main` is bpg's.

**Never run `git push --tags`.** Our tags come only from release-please. A `release-tags` ruleset blocks `v*` tags from
anyone else, but admins can bypass it.

## Syncing with upstream

Sync when you need upstream changes in a release. You don't have to sync every upstream release. An agent can follow
these steps, but a human makes the decisions marked **you**.

1. **Pick the upstream release tag** (`TAG`, e.g. `v0.123.0`). Fetch only that tag and the one we're synced to:
   ```sh
   git fetch --multiple origin glueops
   git fetch --no-tags origin tag "$TAG" tag "$(git show glueops/main:.glueops/upstream-tag)"
   git switch -c "sync/$TAG" glueops/main
   git merge --no-ff --no-commit "$TAG"
   ```
2. **Run the fixup.** It resolves the routine conflicts, rebrands, rebuilds `go.mod`/`go.sum`, runs `make docs`, then
   checks the tree.
   ```sh
   scripts/glueops-sync-fixup.sh sync "$TAG"
   ```
   - Exit 3 with `GUARD:`: upstream changed `.goreleaser.yaml`, `terraform-registry-manifest.json`, or added
     permissions, secrets or risky triggers to a kept workflow. Those run in our release job or CI. **You** read the
     printed diff, then re-run with `--ack`.
   - Exit 4: feature files conflict. Take upstream's version, re-apply our lines, `git add`, and re-run `sync`.
   - Any other non-zero exit is a `go` or `make docs` error, usually from a hand-resolved feature file. Fix it and
     re-run `sync`.
   - Exit 3 with `DRIFT:`: something isn't covered.
     - A new upstream workflow or agent file: delete it (`git rm`) and add a `deleted` entry. **You** decide if it
       should be `kept` instead.
     - A new file with a version marker: add it to `extra-files` in `release-please-config.json`.
3. **Review upstream's changes to the files we own or deleted.** The script prints a list of them. For each one, write
   a row in the PR, for example:

   | File | Upstream change | Recommendation |
   | ---- | --------------- | -------------- |
   | `.github/workflows/release-please.yml` | bumped release-please-action | port the SHA bump into ours |
   | `AGENTS.md` | new testing note | ignore (ours points to `docs/adr/`) |

   **You** decide each row. Then port the accepted ones into our files.
4. **Build, test, lint and docs** (AGENTS.md has the commands). Then stage everything and check what you'll commit:
   ```sh
   git add -A && scripts/glueops-sync-fixup.sh check "$TAG"
   ```
5. **Commit and open the PR.**
   ```sh
   git commit --no-edit
   git push -u glueops "sync/$TAG"
   gh pr create --repo GlueOps/terraform-provider-proxmox --base main \
     --title "feat: sync with upstream $TAG" --body "<table from step 3, link to bpg's CHANGELOG for the range>"
   ```
   List upstream's BREAKING changes in the PR body. They won't all appear in our changelog.
6. **Merge.** Every check must be green, not just the required ones. Then:
   ```sh
   gh pr merge <N> --repo GlueOps/terraform-provider-proxmox --admin --merge \
     --subject "feat: sync with upstream $TAG" --body "Upstream: https://github.com/bpg/terraform-provider-proxmox/releases/tag/$TAG"
   ```
   Always use a **merge commit**, never squash or rebase. Squashing loses upstream's history, and the next sync would
   conflict everywhere. The `feat:` subject makes release-please propose a new minor version.

## Releasing

release-please keeps a release PR (`chore(main): release X.Y.Z`) open against `main`. Merging it creates the tag and
GitHub release. A second job in `.github/workflows/release-please.yml` then builds, signs, uploads and attests the
assets.

1. **Check the version** in the release PR. Look for `Release-As:` footers in commits merged since the last release,
   because an upstream one would force its number on us.
2. **Run the release gate** (below). Post the result as a PR comment in this exact format, and never paste raw output:
   ```text
   Release gate for X.Y.Z
   binary sha256: <sha256 of the snapshot binary>
   acceptance: --- PASS ×3 (TestAccResourceCloudInitBootstrap subtests)
   lab plan: no replace, no destroy, no change to proxmox_virtual_environment_vm
   ```
3. **Merge the release PR** once every check is green: `gh pr merge <N> --repo GlueOps/terraform-provider-proxmox --admin --squash`.
4. **Verify the assets** once the goreleaser job finishes: a zip per platform, `SHA256SUMS`, `SHA256SUMS.sig` and
   `manifest.json`.
   ```sh
   gh release download vX.Y.Z --repo GlueOps/terraform-provider-proxmox --dir /tmp/rel && cd /tmp/rel
   gpg --verify terraform-provider-proxmox_X.Y.Z_SHA256SUMS.sig terraform-provider-proxmox_X.Y.Z_SHA256SUMS
   sha256sum -c terraform-provider-proxmox_X.Y.Z_SHA256SUMS
   gh attestation verify terraform-provider-proxmox_X.Y.Z_linux_amd64.zip --repo GlueOps/terraform-provider-proxmox
   ```
   The signature must be from the GlueOps key `52319649A2976E57`. Run the commands in a container if you don't have
   the tools.
5. **Check the registries.** Both pick the release up on their own. The Terraform Registry uses a release webhook. The
   OpenTofu registry polls tags about every 15 minutes. If the Terraform Registry is missing the version, use
   **Resync** in its provider settings.

### Release gate

The gate runs locally, never in GitHub, so no PVE credentials ever reach the repo.

- **Acceptance tests.**
  1. Create a gitignored `testacc.env` in the repo root with these variables:
     - `TF_ACC=1`
     - `PROXMOX_VE_ENDPOINT`
     - `PROXMOX_VE_API_TOKEN`
     - `PROXMOX_VE_INSECURE` (only if needed)
     - `PROXMOX_VE_ACC_NODE_NAME`
     - `PROXMOX_VE_ACC_NODE_2_NAME`
     - `PROXMOX_VE_ACC_CLOUDINIT_BRIDGE` and `PROXMOX_VE_ACC_CLOUDINIT_VLAN_ID`, for a bridge with DHCP and internet
       access
  2. The `local` datastore on both nodes needs the `import`, `images` and `iso` content types. Leave the SSH variables
     out; the resource uses only the API.
  3. Run the tests:
     ```sh
     scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap
     ```
  4. All 3 subtests must report `--- PASS`. Without `NODE_2_NAME` the migration subtest silently doesn't run.
- **Lab plan with the release's code.**
  1. Build the binary:
     ```sh
     docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/w -w /w \
       -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
       goreleaser/goreleaser:v2.20.1 build --snapshot --clean --single-target
     ```
  2. In a nonprod lab, point `dev_overrides` at the **absolute** path of
     `dist/terraform-provider-proxmox_linux_amd64_v1/`. Key it to the address that `tofu providers` shows for proxmox.
  3. Run `TF_LOG=debug tofu plan 2>&1 | grep 'starting plugin.*terraform-provider-proxmox'` and confirm every line
     shows the `dist/` path and none shows `.terraform/providers/`. Pipe straight to grep; don't keep debug logs.
  4. Then run a normal plan. It must show no replace, no destroy and no change to any
     `proxmox_virtual_environment_vm`, because an in-place VM update reboots the node.

### Emergency release

- **The goreleaser job failed:**
  1. If it uploaded some assets, delete them with `gh release delete-asset vX.Y.Z <name> --repo GlueOps/terraform-provider-proxmox`.
  2. Use **Re-run failed jobs** on the workflow run. A new run won't release again, because release-please already
     created the release.
- **The release workflow can't run at all:** an admin can build and sign locally with the GlueOps key, using
  `goreleaser release --clean` with `GPG_FINGERPRINT` and `GITHUB_TOKEN` set. Do this only for an existing tag.

## Signing key and secrets

- **Signing key:** the GlueOps GPG key `52319649A2976E57` (RSA 4096). The same key signs `GlueOps/autoglue` and
  `GlueOps/waggle`. It's stored as `GPG_PRIVATE_KEY` and `PASSPHRASE` in the `release` environment, which only `main`
  can deploy to.
- **If the key leaks:**
  1. Revoke it.
  2. Remove it from the Terraform Registry namespace and the OpenTofu registry.
  3. Add a new key in both places, and update the secrets in all three repos.
  4. Re-release.
- **App token:** release-please uses the org App `public-release-please` through the org secrets
  `RELEASE_PLEASE_APP_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`. Its tags pass the `release-tags` ruleset.
- **Workflow token:** the repo's default workflow token is read-only. Renovate is disabled (`renovate.json`), because
  upstream's Renovate keeps dependencies current and syncs bring those bumps in.

## Feature work

Commit rules per branch are in AGENTS.md. Beyond those:

- **Meant for bpg:** open the PR against bpg from a branch off `origin/main`, then merge the same commits into a fork
  branch off `glueops/main`.
- **Touching another upstream file:** add it to the allowlist as `feature`, and expect to resolve it on syncs.
