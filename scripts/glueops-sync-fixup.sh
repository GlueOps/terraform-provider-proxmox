#!/usr/bin/env bash
# GlueOps fork tooling. See FORK.md for when to run each mode.
#
#   scripts/glueops-sync-fixup.sh sync <TAG> [--ack]   finish a merge of upstream <TAG>: auto-resolve routine
#                                                      conflicts, rebrand, fix go.mod, make docs, then check
#   scripts/glueops-sync-fixup.sh rebrand [TAG]        rebuild the rebranded files from upstream TAG
#   scripts/glueops-sync-fixup.sh check [TAG] [--ack]  check the working tree against upstream TAG
#   scripts/glueops-sync-fixup.sh --self-test [TAG]    prove the checks catch drift (run after editing this file)
#
# TAG defaults to the upstream tag recorded in .glueops/upstream-tag.
# --ack: a human has read the upstream build/workflow changes printed by a sync and accepts them.
#
# Exit codes: 0 ok, 1 usage or setup error, 3 drift or guard failure, 4 conflicts left to resolve by hand.
# Needs bash 3.2+, git and Docker; no other tools beyond POSIX sed/awk/grep (macOS works).
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
ALLOWLIST=.glueops/allowlist
SOURCE_NEW='registry.terraform.io/GlueOps/proxmox'
# Rebranded paths, in upstream: every file here with a "bpg/proxmox" source or a release-please version marker.
REBRAND_SCOPE=(README.md Makefile docs/index.md docs/guides docs/data-sources examples)
# Upstream build inputs that run while the signing key is unlocked: any upstream change needs --ack.
GUARDED=(.goreleaser.yaml terraform-registry-manifest.json)
# shellcheck disable=SC2016 # literal Markdown backticks
INDEX_NOTE='-> **GlueOps fork.** This is the GlueOps fork of [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest), adding the `proxmox_cloudinit_bootstrap` resource. Use the full source address `registry.terraform.io/GlueOps/proxmox` with Terraform and OpenTofu. Versions are the fork'"'"'s own; see [FORK.md](https://github.com/GlueOps/terraform-provider-proxmox/blob/main/FORK.md).'
# shellcheck disable=SC2016 # literal Markdown backticks
README_NOTE='> **GlueOps fork** of [bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox), published as `registry.terraform.io/GlueOps/proxmox` with the added `proxmox_cloudinit_bootstrap` resource. See [FORK.md](FORK.md).'

die() { echo "glueops-sync: $*" >&2; exit 1; }
fail() { echo "DRIFT: $*" >&2; FAILS=$((FAILS + 1)); }

recorded_tag() { tr -d '[:space:]' < .glueops/upstream-tag; }

# Upstream tags are never fetched in bulk (FORK.md), so fetch the one we need explicitly.
require_tag() {
	git rev-parse -q --verify "$1^{commit}" >/dev/null ||
		die "upstream tag $1 isn't in this clone; run: git fetch --no-tags origin tag $1"
}
manifest_version() { git show "$1:.release-please-manifest.json" | sed -n 's/.*"\.": *"\([^"]*\)".*/\1/p'; }

# Allowlist lines as "kind<TAB>path".
entries() { git show "$1:$ALLOWLIST" | sed -e 's/#.*//' | awk 'NF == 2 { print $1 "\t" $2 }'; }

# Kind of the entry covering a path (exact match first, then the longest directory prefix), or empty.
kind_of() {
	awk -F'\t' -v p="$2" '
		$2 == p { print $1; found = 1; exit }
		$2 ~ /\/$/ && index(p, $2) == 1 && length($2) > best { best = length($2); k = $1 }
		END { if (!found && best) print k }' <<<"$1"
}

rebrand_targets() {
	git grep -lE '(source[[:space:]]*=[[:space:]]*"bpg/proxmox"|x-release-please-version)' "$1" -- "${REBRAND_SCOPE[@]}" |
		sed "s|^$1:||" | LC_ALL=C sort
}

# Upstream file content on stdin -> rebranded content on stdout. Fails if an insert anchor is gone.
rebrand_stream() {
	local path=$1 version=$2
	sed -E -e "s#(source[[:space:]]*=[[:space:]]*)\"bpg/proxmox\"#\\1\"$SOURCE_NEW\"#" \
		-e "/x-release-please-version/ s/[0-9]+\\.[0-9]+\\.[0-9]+/$version/" \
		-e "/x-release-please-version/! s/(version[[:space:]]*=[[:space:]]*\")>= *[0-9]+\\.[0-9]+\\.[0-9]+\"/\\1>= 0.0.1\"/" |
		case "$path" in
		docs/index.md) insert_after '^# Proxmox Provider$' "$INDEX_NOTE" ;;
		README.md) insert_after '^# Terraform / OpenTofu Provider for Proxmox VE$' "$README_NOTE" ;;
		*) cat ;;
		esac
}

insert_after() {
	awk -v re="$1" -v note="$2" '
		{ print }
		!done && $0 ~ re { print ""; print note; done = 1 }
		END { if (!done) { print "anchor not found: " re > "/dev/stderr"; exit 5 } }'
}

# Tree object of the working tree (tracked and untracked, minus ignored files), without touching the index.
snapshot_tree() {
	local idx
	idx=$(mktemp)
	cp "$(git rev-parse --git-path index)" "$idx"
	GIT_INDEX_FILE=$idx git add -A
	GIT_INDEX_FILE=$idx git write-tree
	rm -f "$idx"
}

# Whether the name-status diff has an A or M line for the path (exact) or under it (prefix).
differs() {
	awk -F'\t' -v p="$2" -v mode="$3" '
		($1 == "A" || $1 == "M") && ($2 == p || (mode == "prefix" && index($2, p) == 1)) { found = 1 }
		END { exit !found }' <<<"$1"
}

check_tree() {
	local tag=$1 tree=$2 version list diff targets status path kind wf
	FAILS=0
	version=$(manifest_version "$tree")
	list=$(entries "$tree")
	diff=$(git diff-tree -r --no-renames --name-status "$tag" "$tree")
	targets=$(rebrand_targets "$tag")
	if [ -z "$list" ] || [ -z "$targets" ] || [ -z "$version" ]; then
		die "empty allowlist, rebrand set or manifest version"
	fi

	while IFS=$'\t' read -r status path; do
		[ -n "$path" ] || continue
		if grep -qxF "$path" <<<"$targets"; then
			[ "$status" = M ] || fail "$status $path: rebranded file should be modified, not $status"
			continue
		fi
		kind=$(kind_of "$list" "$path")
		case "$kind:$status" in
		owned:A | owned:M | feature:A | feature:M | deleted:D) ;;
		:D) fail "$status $path: not in $ALLOWLIST (if you deleted it on purpose, add a 'deleted' entry)" ;;
		:*) fail "$status $path: not in $ALLOWLIST" ;;
		kept:*) fail "$status $path: listed as kept, so it must equal upstream" ;;
		*) fail "$status $path: listed as $kind, which doesn't allow $status" ;;
		esac
	done <<<"$diff"

	while IFS=$'\t' read -r kind path; do
		case "$kind" in
		owned | feature)
			if [[ $path == */ ]]; then
				differs "$diff" "$path" prefix || fail "$kind $path: nothing under it differs from upstream"
			else
				differs "$diff" "$path" exact || fail "$kind $path: listed but identical to upstream or missing"
			fi
			;;
		deleted)
			if git ls-tree -r --name-only "$tree" -- "$path" | grep -q .; then
				fail "deleted $path: present again (git rm it)"
			elif ! git ls-tree -r --name-only "$tag" -- "$path" | grep -q .; then
				echo "note: deleted $path no longer exists upstream; the entry can go" >&2
			fi
			;;
		kept) git cat-file -e "$tree:$path" 2>/dev/null || fail "kept $path: missing" ;;
		*) fail "$ALLOWLIST: unknown kind '$kind' for $path" ;;
		esac
	done <<<"$list"

	while read -r wf; do
		kind=$(kind_of "$list" "$wf")
		[ "$kind" = owned ] || [ "$kind" = kept ] || fail "$wf: workflow not listed as owned or kept (new upstream workflow?)"
	done < <(git ls-tree --name-only "$tree" .github/workflows/)

	local agent_files
	agent_files=$(git ls-tree -r --name-only "$tree" |
		grep -E '(^|/)\.(claude|cursor[^/]*|gemini)(/|$)|(^|/)\.mcp\.json$|(^|/)GEMINI\.md$|./(AGENTS|CLAUDE)\.md$' || true)
	while read -r path; do
		[ -z "$path" ] || fail "$path: agent config (delete it)"
	done <<<"$agent_files"

	while read -r path; do
		if ! cmp -s <(git show "$tag:$path" | rebrand_stream "$path" "$version") <(git show "$tree:$path"); then
			fail "$path: differs from upstream's copy rebranded (run: $0 rebrand $tag)"
		fi
	done <<<"$targets"

	if ! cmp -s <(git show "$tree:release-please-config.json" | sed -n '/"extra-files"/,/]/p' | sed -n 's/^[[:space:]]*"\([^"]*\)",*$/\1/p' | LC_ALL=C sort) \
		<(git grep -l x-release-please-version "$tree" -- "${REBRAND_SCOPE[@]}" | sed "s|^$tree:||" | LC_ALL=C sort); then
		fail "release-please-config.json extra-files doesn't match the files carrying x-release-please-version"
	fi

	[ "$FAILS" -eq 0 ] || return 3
}

# Upstream changes between two tags that a human must read before pushing a sync branch.
guard_upstream() {
	local old=$1 new=$2 ack=$3 hits=0 kept path
	[ "$old" != "$(git rev-parse "$new^{commit}")" ] || return 0
	if ! git diff --quiet "$old" "$new" -- "${GUARDED[@]}"; then
		git diff "$old" "$new" -- "${GUARDED[@]}" >&2
		echo "GUARD: upstream changed build inputs that run with the signing key (${GUARDED[*]})" >&2
		hits=$((hits + 1))
	fi
	kept=()
	while read -r path; do kept+=("$path"); done < <(entries HEAD | awk -F'\t' '$1 == "kept" { print $2 }')
	if ! git diff --quiet "$old" "$new" -- "${kept[@]}"; then
		git diff "$old" "$new" -- "${kept[@]}" >&2
		if git diff "$old" "$new" -- "${kept[@]}" | grep -E '^\+' | grep -qE 'permissions:|secrets\.|pull_request_target|workflow_run'; then
			echo "GUARD: upstream added permissions, secrets or risky triggers to a kept workflow" >&2
			hits=$((hits + 1))
		fi
	fi
	if [ "$hits" -gt 0 ] && [ "$ack" != yes ]; then
		echo "Read the diff above, then re-run with --ack to accept it." >&2
		return 3
	fi
}

apply_rebrand() {
	local tag=$1 version path
	version=$(manifest_version HEAD)
	while read -r path; do
		git show "$tag:$path" | rebrand_stream "$path" "$version" >"$path.glueops-tmp"
		mv "$path.glueops-tmp" "$path"
	done < <(rebrand_targets "$tag")
}

cmd_sync() {
	local tag=$1 ack=$2 old new list targets path kind diskfs reviewed left=()
	new=$(git rev-parse "$tag^{commit}") || die "unknown tag $tag (git fetch --no-tags origin tag $tag)"
	[ "$(git rev-parse -q --verify MERGE_HEAD)" = "$new" ] || die "run this during 'git merge $tag' (MERGE_HEAD must be $tag)"
	old=$(git show HEAD:.glueops/upstream-tag | tr -d '[:space:]')
	require_tag "$old"
	old=$(git rev-parse "$old^{commit}")
	git merge-base --is-ancestor "$old" "$new" || die "$tag is not newer than the recorded upstream tag"
	list=$(entries HEAD)
	targets=$(rebrand_targets "$tag")

	# Owned files always keep our version, even when upstream's change merged in without a conflict
	# (CHANGELOG.md does). Upstream's change is then reviewed from the diff printed below.
	awk -F'\t' '$1 == "owned" && $2 !~ /\/$/ { print $2 }' <<<"$list" | while read -r path; do
		if git cat-file -e "HEAD:$path" 2>/dev/null; then
			git checkout HEAD -- "$path"
			git add -- "$path"
		fi
	done

	while read -r path; do
		kind=$(kind_of "$list" "$path")
		if grep -qxF "$path" <<<"$targets" || [ "$path" = go.mod ] || [ "$path" = go.sum ]; then
			continue # rebuilt below
		fi
		case "$kind" in
		owned) ;; # restored above
		deleted) git rm -q -f -- "$path" ;;
		*) left+=("$path") ;;
		esac
	done < <(git diff --name-only --diff-filter=U)

	# Deleted paths that merged in cleanly (upstream changed them, or added files under a deleted dir).
	awk -F'\t' '$1 == "deleted" { print $2 }' <<<"$list" | while read -r path; do
		git ls-files -- "$path" | grep -q . && git rm -rq -f -- "$path"
		true
	done

	# Go files with conflict markers break go mod tidy and make docs, so stop here first.
	if [ ${#left[@]} -gt 0 ]; then
		printf 'Resolve by hand (take upstream, re-apply our feature lines), git add, then re-run sync:\n' >&2
		printf '  %s\n' "${left[@]}" >&2
		exit 4
	fi

	apply_rebrand "$tag"
	diskfs=$(git show HEAD:go.mod | awk '$1 == "github.com/diskfs/go-diskfs" { print $2 }')
	[ -n "$diskfs" ] || die "can't read the go-diskfs version from our go.mod"
	git show "$tag:go.mod" >go.mod
	git show "$tag:go.sum" >go.sum
	scripts/glueops-dev.sh sh -c "go get github.com/diskfs/go-diskfs@$diskfs && go mod tidy"
	echo "$tag" >.glueops/upstream-tag
	scripts/glueops-dev.sh make docs
	git add -A -- go.mod go.sum .glueops/upstream-tag docs "${REBRAND_SCOPE[@]}"

	reviewed=()
	while read -r path; do reviewed+=("$path"); done < <(awk -F'\t' '$1 == "owned" || $1 == "deleted" { print $2 }' <<<"$list")
	echo "Upstream changes to files we own or deleted ($(git rev-parse --short "$old")..$tag), for the sync PR table:"
	git diff --stat "$old" "$new" -- "${reviewed[@]}" ':!CHANGELOG.md' ':!.release-please-manifest.json' || true

	guard_upstream "$old" "$tag" "$ack" || exit 3
	check_tree "$tag" "$(snapshot_tree)" || exit 3
	echo "OK: sync to $tag passes. Next: build, test, lint, then commit the merge (see FORK.md)."
}

self_test() {
	local tag=$1 base got out idx blob
	base=$(snapshot_tree)
	check_tree "$tag" "$base" || die "self-test needs a clean, passing tree first"

	expect_drift() { # name, tree, message fragment
		set +e
		out=$(check_tree "$tag" "$2" 2>&1)
		got=$?
		set -e
		if [ "$got" -eq 3 ] && grep -qF -- "$3" <<<"$out"; then
			echo "ok   $1"
		else
			echo "FAIL $1 (exit $got)"
			printf '%s\n' "$out" | sed 's/^/     /'
			return 1
		fi
	}
	tree_with() { # base tree, then "add PATH" (content on stdin) or "rm PATH"
		idx=$(mktemp)
		GIT_INDEX_FILE=$idx git read-tree "$1"
		if [ "$2" = add ]; then
			blob=$(git hash-object -w --stdin)
			GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "100644,$blob,$3"
		else
			GIT_INDEX_FILE=$idx git update-index --force-remove -- "$3"
		fi
		GIT_INDEX_FILE=$idx git write-tree
		rm -f "$idx"
	}

	expect_drift "unlisted file" "$(echo x | tree_with "$base" add zz-unlisted.txt)" "zz-unlisted.txt: not in"
	expect_drift "restored deleted file" "$(git show "$tag:.github/workflows/stale.yaml" | tree_with "$base" add .github/workflows/stale.yaml)" "present again"
	expect_drift "new workflow" "$(echo 'on: push' | tree_with "$base" add .github/workflows/new.yml)" "new.yml"
	expect_drift "nested agent file" "$(echo x | tree_with "$base" add docs/AGENTS.md)" "agent config"
	expect_drift "hand-edited rebranded file" "$( (git show "$base:docs/index.md"; echo extra) | tree_with "$base" add docs/index.md)" "docs/index.md: differs"
	expect_drift "owned file removed" "$(tree_with "$base" rm FORK.md </dev/null)" "FORK.md"

	got=$(git show "$tag:Makefile" | rebrand_stream Makefile 9.8.7 | grep x-release-please-version)
	if [[ $got != VERSION=9.8.7#* ]]; then
		echo "FAIL version rewrite: $got"
		return 1
	fi
	echo "ok   version rewrite"
	if echo '# no anchor' | rebrand_stream docs/index.md 1.0.0 >/dev/null 2>&1; then
		echo "FAIL missing anchor not detected"; return 1
	fi
	echo "ok   missing anchor detected"
	got=$(echo '      version = ">= 0.60.0"' | rebrand_stream examples/x.tf 9.8.7)
	if [ "$got" != '      version = ">= 0.0.1"' ]; then
		echo "FAIL lower-bound rewrite: $got"
		return 1
	fi
	echo "ok   upstream lower bound rewritten"

	expect_drift "kept workflow edited" "$( (git show "$base:.github/workflows/test.yml"; echo '# x') | tree_with "$base" add .github/workflows/test.yml)" "listed as kept"
	expect_drift "extra-files out of date" "$(git show "$base:release-please-config.json" | grep -v '"docs/index.md"' | tree_with "$base" add release-please-config.json)" "extra-files"

	apply_rebrand "$tag"
	if [ "$(snapshot_tree)" != "$base" ]; then
		echo "FAIL rebrand isn't idempotent: re-running it changed the tree (see git diff)"
		return 1
	fi
	echo "ok   rebrand idempotent"

	# Guard: fake upstream commits on top of the tag, so no real tag is needed.
	guard_case() { # name, path, appended line
		local t c
		t=$( (git show "$tag:$2"; echo "$3") | tree_with "$(git rev-parse "$tag^{tree}")" add "$2")
		c=$(git commit-tree "$t" -p "$tag" -m guard-test)
		set +e
		out=$(guard_upstream "$(git rev-parse "$tag^{commit}")" "$c" no 2>&1)
		got=$?
		set -e
		if [ "$got" -eq 3 ] && grep -qF GUARD <<<"$out"; then echo "ok   $1"; else echo "FAIL $1 (exit $got)"; return 1; fi
	}
	guard_case "guard: goreleaser change" .goreleaser.yaml '# upstream change'
	guard_case "guard: kept workflow gains permissions" .github/workflows/test.yml 'permissions: write-all'

	docker run --rm -v "$ROOT/scripts":/s:ro koalaman/shellcheck:v0.10.0 /s/glueops-sync-fixup.sh /s/glueops-dev.sh &&
		echo "ok   shellcheck"
}

mode=${1:-}
shift || true
ack=no
args=()
for a in "$@"; do [ "$a" = --ack ] && ack=yes || args+=("$a"); done
tag=${args[0]:-}
case "$mode" in
sync) [ -n "$tag" ] || die "usage: $0 sync <TAG> [--ack]"; cmd_sync "$tag" "$ack" ;;
rebrand)
	tag=${tag:-$(recorded_tag)}
	require_tag "$tag"
	apply_rebrand "$tag"
	;;
check)
	tag=${tag:-$(recorded_tag)}
	require_tag "$tag"
	if ! git diff --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
		echo "note: unstaged changes are part of this check; git add -A before you commit" >&2
	fi
	check_tree "$tag" "$(snapshot_tree)" || exit 3
	echo "OK: working tree matches $ALLOWLIST against $tag"
	;;
--self-test)
	tag=${tag:-$(recorded_tag)}
	require_tag "$tag"
	self_test "$tag"
	;;
*) sed -n '2,13p' "$0" >&2; exit 1 ;;
esac
