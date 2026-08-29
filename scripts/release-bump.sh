#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <git-revision-range>" >&2
    exit 2
fi

release_bump="none"
header_pattern='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([[:alnum:]./_-]+\))?(!)?:[[:space:]][^[:space:]].*$'

while IFS= read -r commit; do
    subject="$(git show --no-patch --format=%s "$commit")"
    message="$(git show --no-patch --format=%B "$commit")"

    if [[ ! "$subject" =~ $header_pattern ]]; then
        echo "Skipping non-Conventional Commit $commit: $subject" >&2
        continue
    fi

    commit_type="${BASH_REMATCH[1]}"
    is_breaking="${BASH_REMATCH[3]}"
    if [[ "$is_breaking" == "!" ]] || grep -q '^BREAKING CHANGE:' <<< "$message"; then
        release_bump="major"
        break
    fi

    case "$commit_type" in
      feat)
        if [[ "$release_bump" == "none" ]] || [[ "$release_bump" == "patch" ]]; then
            release_bump="minor"
        fi
        ;;
      fix|perf)
        if [[ "$release_bump" == "none" ]]; then
            release_bump="patch"
        fi
        ;;
    esac
done < <(git rev-list --reverse "$1")

echo "$release_bump"
