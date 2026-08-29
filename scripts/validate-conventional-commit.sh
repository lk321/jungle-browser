#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <commit-message-file|--stdin>" >&2
    exit 2
fi

if [[ "$1" == "--stdin" ]]; then
    message="$(cat)"
elif [[ -r "$1" ]]; then
    message="$(< "$1")"
else
    echo "Cannot read commit message: $1" >&2
    exit 2
fi

subject="${message%%$'\n'*}"
subject="${subject%$'\r'}"
header_pattern='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([[:alnum:]./_-]+\))?!?:[[:space:]][^[:space:]].*$'

if [[ ! "$subject" =~ $header_pattern ]]; then
    echo "Invalid Conventional Commit header: $subject" >&2
    echo "Expected: type(scope optional)!: short description" >&2
    echo "Allowed types: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test." >&2
    exit 1
fi
