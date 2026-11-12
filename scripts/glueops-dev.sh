#!/usr/bin/env bash
# Runs a command in the GlueOps fork's dev container, as the host user, with the repo mounted at /w.
# The image is Go (version from go.mod) plus terraform, which `make docs` needs for `terraform fmt`.
#
#   scripts/glueops-dev.sh make docs
#   scripts/glueops-dev.sh go test ./fwprovider/nodes/cloudinitbootstrap/...
#   scripts/glueops-dev.sh lint          # golangci-lint at the Makefile's GOLANGCI_LINT_VERSION
#   scripts/glueops-dev.sh ./testacc TestAccResourceCloudInitBootstrap   # needs testacc.env; see FORK.md
set -euo pipefail

TERRAFORM_VERSION=1.13.3

root=$(git rev-parse --show-toplevel)
go_version=$(awk '/^go /{print $2; exit}' "$root/go.mod")
go_minor=$(printf '%s' "$go_version" | cut -d. -f1,2)
[ -n "$go_minor" ] || { echo "glueops-dev: cannot read the go version from go.mod" >&2; exit 2; }

run_args=(
  # --init forwards Ctrl+C/SIGTERM, so a killed run (e.g. acceptance tests) doesn't keep running.
  --rm --init --user "$(id -u):$(id -g)"
  -v "$root":/w -w /w
  # Code run here (go generate, tests, tools) comes from upstream syncs. Keep it from writing git hooks or
  # config that would run on the host, or from editing the fork tooling the host runs next.
  -v "$root/.git":/w/.git:ro -v "$root/scripts":/w/scripts:ro -v "$root/.glueops":/w/.glueops:ro
  -v "$root/.github":/w/.github:ro
  -e HOME=/tmp
  -e GOTOOLCHAIN=local
  -e GOMODCACHE=/w/.gocache/mod
  -e GOCACHE=/w/.gocache/build
  -e GOFLAGS=-modcacherw  # so .gocache can be deleted without root
  # The repo is owned by the host user; without this git (and go's VCS stamping) refuses to run.
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*'
)

# Our owned files (release workflow, release config, FORK.md, AGENTS.md...) are read-only in the container too.
while read -r owned; do
  case "$owned" in scripts/* | .glueops/* | .github/* | */) continue ;; esac
  if [ -f "$root/$owned" ]; then run_args+=(-v "$root/$owned:/w/$owned:ro"); fi
done < <(sed -e 's/#.*//' "$root/.glueops/allowlist" | awk '$1 == "owned" { print $2 }')

if [ "${1:-}" = lint ]; then
  shift
  lint_version=$(sed -n 's/^GOLANGCI_LINT_VERSION=\([0-9.]*\).*/\1/p' "$root/Makefile")
  [ -n "$lint_version" ] || { echo "glueops-dev: cannot read GOLANGCI_LINT_VERSION from Makefile" >&2; exit 2; }
  exec docker run "${run_args[@]}" -e GOLANGCI_LINT_CACHE=/w/.gocache/lint \
    "golangci/golangci-lint:v${lint_version}" golangci-lint run "$@"
fi

[ $# -gt 0 ] || { sed -n '2,8p' "$0" >&2; exit 2; }

# Tagged by go.mod's full version so a go.mod bump rebuilds; --pull gets a Go patch at least that new.
image="glueops-tfpp-dev:go${go_version}-tf${TERRAFORM_VERSION}"
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build --pull -q -t "$image" - >/dev/null <<EOF
FROM hashicorp/terraform:${TERRAFORM_VERSION} AS terraform
FROM golang:${go_minor}
COPY --from=terraform /bin/terraform /usr/local/bin/terraform
EOF
fi

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)
exec docker run ${tty[@]+"${tty[@]}"} "${run_args[@]}" "$image" "$@"
