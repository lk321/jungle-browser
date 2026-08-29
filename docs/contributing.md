# Development workflow

## One-time setup

Install [Lefthook](https://github.com/evilmartians/lefthook) with Homebrew:

```sh
brew install lefthook
lefthook install
```

The repository hook configuration is committed in `lefthook.yml`; rerun
`lefthook install` after cloning on a new machine.

## Commit format

Use Conventional Commits. The `commit-msg` hook and GitHub pull-request check
both enforce this format:

```text
type(optional-scope)!: short description
```

Examples:

```text
feat(tabs): add sleeping tabs
fix(webview): restore the last committed URL
perf(pool): release idle views sooner
feat!: remove legacy workspace persistence
```

Allowed types are `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `revert`, `style`, and `test`.

## Hooks

- `pre-commit` checks staged whitespace and parses changed workflow YAML.
- `commit-msg` checks the Conventional Commit header.
- `pre-push` runs the macOS test suite when full Xcode is selected. It explains
  and skips locally when only Command Line Tools are installed; the required PR
  workflow still runs the suite on GitHub's macOS runner.

Hooks are an early guard, not the security boundary. The GitHub PR workflow
repeats commit validation and tests, so contributors cannot bypass the policy
with `--no-verify`.

## Branch and merge policy

Use short-lived branches from `main`, named for their intent, such as
`feat/tab-suspension` or `fix/blank-page`. Open a pull request, pass both
required checks, review it, and squash-merge with a Conventional Commit title.
The merge commit is what drives automatic versioning and publication.

For Jungle, this trunk-based flow is preferable to classic Git Flow's permanent
`develop` and release branches: the app has one releasable mainline and each
merged user-facing change can ship promptly. Use a hotfix branch plus the same
PR process for urgent fixes. Reserve a release branch only if maintaining more
than one supported major version becomes necessary.
