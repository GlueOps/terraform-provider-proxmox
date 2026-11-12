# AGENTS.md

This repo is the **GlueOps fork** of [bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox),
published as `registry.terraform.io/GlueOps/proxmox`. It is upstream plus the `proxmox_cloudinit_bootstrap` resource.

**Read [FORK.md](FORK.md) first.** It covers how the fork differs from upstream, how to sync, and how to release.
If anything in upstream's docs (README, CONTRIBUTING, `.dev/`, `docs/adr/`) conflicts with this file or FORK.md, this
file and FORK.md win.

## Repo map

- `fwprovider/`: Framework provider. All new code goes here. Our resource is `fwprovider/nodes/cloudinitbootstrap/`.
- `proxmoxtf/`: legacy SDK provider. Don't add to it.
- `proxmox/`: PVE API client.
- `docs/`: registry docs, partly generated (see below). `docs/adr/` holds upstream's design decisions.
- `examples/`: HCL used by the generated docs. `example/`: local dev harness for `make example`.
- `scripts/glueops-*`: fork tooling. `.glueops/allowlist`: every path where the fork differs from upstream.

## Commands

Run everything in Docker with `scripts/glueops-dev.sh`. It uses Go from `go.mod`, plus terraform, as your user.

```sh
scripts/glueops-dev.sh go build ./...
scripts/glueops-dev.sh go test ./...
scripts/glueops-dev.sh lint                      # golangci-lint at the Makefile's version
scripts/glueops-dev.sh make docs                 # regenerate docs; CI fails if this leaves a diff
scripts/glueops-sync-fixup.sh --self-test        # after changing fork tooling
scripts/glueops-acc-lab.sh all                   # rebuild the release gate lab (wipes the 2 lab servers); runs on the host
```

The release gate (FORK.md) runs acceptance tests against a Hetzner lab; `.glueops/release-gate-lab.md` covers building
it and what to do when a stage fails.

Don't use `make lint` or `make build` on the host: they install or run tools outside Docker.

## Commits and PRs

Check which base a branch is on with `git merge-base --is-ancestor glueops/main HEAD`: exit 0 means it contains
`glueops/main` (fork work); exit 1 means it doesn't (work meant for bpg).

- **Fork work** (the branch contains `glueops/main`):
  - Use Conventional Commits; release-please reads them to set our version.
  - Use `feat` for new behaviour and `fix` for bug fixes; `deps`, `perf` and `revert` also cut a release. `chore`, `ci`
    and `docs` are hidden from the changelog and don't cut a release.
  - Retitle a GitHub "Revert" PR to `revert: <original title>` before merging; release-please can't parse
    `Revert "..."` and drops it.
  - Open PRs with `--repo GlueOps/terraform-provider-proxmox`, because `gh` otherwise targets bpg.
  - Squash-merge, except sync PRs, which merge with a merge commit (see FORK.md).
  - The PR description becomes the squash commit's body, which release-please reads. Write it as prose; a line
    starting with `feat:`, `fix:` or `BREAKING CHANGE:` adds a changelog entry.
- **Work meant for bpg** (the branch is based on `origin/main`): follow upstream's rules.
  - Sign off with `git commit -s` (DCO).
  - Use upstream's scopes: `vm`, `lxc`, `provider`, `core`, `docs`, `ci`.
  - Add no `Co-Authored-By` trailers.
- **Everywhere:**
  - Never put `Claude-Session:` trailers or `claude.ai/code/...` links in commits, PRs, issues or comments.
  - Never publish internal hostnames, IPs, VLANs or cluster names.
- **Before any merge:** every check on the PR must be green, not just the required ones. A red check means stop.

## Code conventions (upstream's, summarised)

- **Resources:** one package per resource under `fwprovider/`, laid out as in [ADR-003](docs/adr/003-resource-file-organization.md).
- **Errors:** `"Unable to [Action] [Resource]"` with the resource name or ID in the summary, and `err.Error()` as the detail ([ADR-005](docs/adr/005-error-handling.md)).
- **Retries:** use `proxmox/retry`. Delete operations must not retry on `api.ErrResourceDoesNotExist`.
- **Tests:** follow [ADR-006](docs/adr/006-testing-requirements.md). Use acceptance tests against a real PVE, not a faked API, and write tests that fail without the fix.
- **Docs:** Framework docs are generated from schema `MarkdownDescription` or `templates/`. Never hand-edit those files in `docs/`. Run `make docs` after schema changes.
- **Keep the fork's footprint small.** The only upstream files our feature touches are `fwprovider/provider.go`, `main.go`, `proxmox/nodes/vms/vms.go`, `proxmox/nodes/vms/vms_types.go`, `example/variables.tf` and `go.mod`/`go.sum`. Don't widen this. Put new code in our own package.

## Decisions

These are settled. Don't re-raise them in reviews.

- The fork is long-term, and every sync is a manual, agent-assisted merge commit of an upstream tag. There is no sync workflow.
- Our versions are our own, starting at 0.0.1 and managed by release-please. Upstream commits that a sync brings in may drive bumps. `bump-minor-pre-major` is on.
- The Go module path stays `github.com/bpg/terraform-provider-proxmox`, so imports are never rewritten. Renaming it would conflict on every sync.
- The `GetFileFromAgent` helper stays in `proxmox/nodes/vms`, the same as in bpg PR #3260.
- Docs and examples are rebranded to `registry.terraform.io/GlueOps/proxmox` by the fixup script, and upstream's `>= x.y.z` lower bounds become `>= 0.0.1`. `example/` is not rebranded, because its `.tfrc` dev overrides are keyed to `bpg/proxmox`.
- There are no required status checks beyond the org's. People and agents check that every check is green before merging.
- The release-please setup deliberately differs from the GlueOps release-please skill's fleet convention (workflow name,
  hidden chore, own changelog sections), because it has to coexist with upstream's files. Don't "reconcile" it.
- The release App token asks only for contents and pull-requests write; the org App has nothing more.
- Releases are created as drafts and published by goreleaser only after every asset is uploaded, through a derived
  goreleaser config (`use_existing_draft`) so upstream's `.goreleaser.yaml` stays unedited.
- Never delete the `feat/cloudinit-iso` branch: it's the head of bpg PR #3260, and deleting it closes that PR. The
  `protect-upstream-pr-branch` ruleset blocks deletion.
- Actions are pinned to commit SHAs by hand. `sha_pinning_required` is off, and Renovate is disabled in the fork.
- The release gate (acceptance tests plus a lab plan) runs locally and never in GitHub, so no PVE credentials go into the repo.
- Release 1 of a consuming module may not change any `proxmox_virtual_environment_vm`, because an in-place update reboots nodes.
