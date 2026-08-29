# Publishing releases

Every merge to `main` starts the release workflow. It reads the Conventional
Commits added since the latest stable `v*` tag and publishes only when it finds
a release-worthy change:

- `fix:` and `perf:` produce a patch release.
- `feat:` produces a minor release.
- Any `!` after the type or a `BREAKING CHANGE:` footer produces a major release.
- `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, and `test:` do not
  create a release by themselves.

The highest applicable increment wins. The initial automatic release is
`v1.0.0`. The workflow runs tests, builds the app with the calculated version,
verifies its universal binary slices, creates an annotated tag, and adds the ZIP
and SHA-256 checksum to the GitHub Release.

## Exceptional releases

Use **Actions → Release macOS app → Run workflow** only to publish an emergency
release or a pre-release. Enter an exact semantic version such as `1.2.3-rc.1`;
it takes precedence over the manual `bump` choice. Do not create release tags by
hand: `main` is the source of truth for automatic releases.

## Required repository settings

Protect `main`: require pull requests and the two checks from `Verify pull
request`, and prevent direct pushes. Under **Actions → General → Workflow
permissions**, allow workflows to read and write repository contents so the
built-in `GITHUB_TOKEN` can create tags and releases.

## Distribution and signing

The published ZIP contains an unsigned universal (`arm64` and `x86_64`) app.
It is appropriate for internal testing, but macOS Gatekeeper will warn users
until Developer ID signing and notarization are configured. The workflow does
not claim that an unsigned build is notarized.
