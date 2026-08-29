#!/usr/bin/env bash

set -euo pipefail

while IFS= read -r workflow; do
    ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$workflow"
done < <(git diff --cached --name-only --diff-filter=ACMR -- '.github/workflows/*.yml' '.github/workflows/*.yaml')
