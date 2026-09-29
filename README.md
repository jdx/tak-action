# tak-action

A GitHub Action for [tak](https://github.com/jdx/tak), which measures commands by counting
retired instructions with valgrind's cachegrind and stores the results in the repository as git
notes under `refs/notes/tak`.

> [!CAUTION]
> ## Pre-v1 software
>
> **tak is pre-v1, and so is this action. Its inputs, outputs, report artifact format, and
> behavior are not finalized.**
>
> Breaking changes may land between releases, including under the floating `v0` tag. Pin a
> full commit SHA or an exact tag, and read the release notes before moving it. If you need a
> stable benchmark tool, use [hyperfine](https://github.com/sharkdp/hyperfine). If you need CI
> benchmark tracking, use [Bencher](https://bencher.dev) or [CodSpeed](https://codspeed.io).

The action replaces the workflow YAML in tak's
[adoption guide](https://tak.jdx.dev/guide/adopting) with three modes:

| mode | where it runs | what it does |
|---|---|---|
| `record` | push to the main branch | installs tak and valgrind, runs your build and `tak run --record`, pushes `refs/notes/tak` |
| `compare` | `pull_request` | fetches the base branch and notes, **removes the checkout's credentials**, runs your build and `tak run --record`, compares with the merge base, writes the report to the job summary, uploads it as an artifact, and fails on a regression or on an empty comparison |
| `comment` | `workflow_run`, after `compare` | reads that artifact and posts a sticky pull-request comment and a check run, without checking out or executing anything from the pull request |

Two smaller modes exist for jobs that need their own steps in between: `prepare` does only
the trusted first half of `compare`, and `install` installs tak and valgrind and nothing else.

Only instruction counts gate. Wall-clock time appears in the report and never fails anything:
on a shared runner it moves 4-20% between identical runs, which is as large as the regressions
worth catching.

## Before you start

- A `tak.toml` declaring your benchmarks. Work through
  [Adopt tak in a project](https://tak.jdx.dev/guide/adopting) first: choose benchmarks that do
  not touch the network or the clock, and check them locally with `tak run`.
- Linux runners. valgrind is what counts instructions, and there is no usable valgrind on Apple
  Silicon or Windows. The action installs it with `apt-get` when it is missing and fails
  clearly on other operating systems.
- Main-branch history before gating. A pull request can only be compared against a base
  commit that `record` has measured, on the same runner class. Until that history exists,
  every comparison reports *nothing was compared*, which fails by default.

## Example workflows

Three files. Replace `0.0.13` with the tak release you use and `cargo build --release` with
your build. The `run` input is executed with `bash -euo pipefail` in the checkout.

The examples reference this action by tag for readability. As with any third-party action,
pin the full commit SHA of a release you have reviewed, with the tag in a comment.

### Record the main branch

`.github/workflows/perf.yml`:

```yaml
name: perf

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions: {}

# One writer at a time, and never cancel: a cancelled run is a hole in the
# history.
concurrency:
  group: perf
  cancel-in-progress: false

jobs:
  record:
    runs-on: ubuntu-24.04
    permissions:
      contents: write # push refs/notes/tak
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: jdx/tak-action@v0.1.0
        with:
          mode: record
          version: 0.0.13
          run: |
            cargo build --release
            tak run --record
          token: ${{ secrets.GITHUB_TOKEN }}
          # A manual dispatch from another branch measures without pushing.
          push: ${{ github.ref == 'refs/heads/main' }}
```

`record` refuses to push from a `pull_request`, `pull_request_target` or `merge_group` event
to this repository. A branch's numbers are not the trunk's, and a series that mixes them
cannot be read.

### Compare pull requests

`.github/workflows/perf-pr.yml`:

```yaml
name: perf-pr

on:
  pull_request:

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  compare:
    runs-on: ubuntu-24.04
    # Read only. This job builds and runs the pull request's code.
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          # The branch commit, not the synthetic merge commit.
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false

      # This must be the first step after checkout that touches files from
      # the pull request. Everything the build needs goes in `run`, which
      # executes after the action has removed every credential.
      - uses: jdx/tak-action@v0.1.0
        with:
          mode: compare
          version: 0.0.13
          run: |
            cargo build --release
            tak run --record
```

The report goes to the job summary and to an artifact named `tak-report`. The job fails when
an instruction count rises beyond the gate (`[gate].pct` in `tak.toml`, or `gate-pct`), when
nothing was compared, or when the build or the comparison fails.

If the build needs another action, such as `jdx/mise-action` reading the pull request's
`mise.toml`, split the comparison around it so the trusted half still runs first. When
`mise.toml` pins tak, `install: false` uses that tak instead of downloading a second one, so
the version that measures and the version that compares are the same:

```yaml
      - uses: jdx/tak-action@v0.1.0
        with:
          mode: prepare
          install: false # prepare runs only git; tak comes from mise.toml

      - uses: jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c # v4.3.0

      - uses: jdx/tak-action@v0.1.0
        with:
          mode: compare
          install: false
          run: mise run perf:record
```

### Comment on pull requests

`.github/workflows/perf-pr-report.yml`:

```yaml
name: perf-pr-report

on:
  workflow_run:
    workflows: [perf-pr]
    types: [completed]

permissions: {}

jobs:
  report:
    if: github.event.workflow_run.event == 'pull_request'
    runs-on: ubuntu-24.04
    permissions:
      actions: read # download the report artifact from the perf-pr run
      checks: write # a check run on the pull request's head commit
      pull-requests: write # the sticky comment
    steps:
      # No checkout. This job holds a write token and executes nothing from
      # the pull request.
      - uses: jdx/tak-action@v0.1.0
        with:
          mode: comment
```

`workflows: [perf-pr]` must match the `name:` of the compare workflow. The comment is edited in
place on every push. The check run is named `tak / instruction-count` by default; its
conclusion is `success`, `failure`, or `neutral` when `fail-on-regression` or
`fail-on-nothing-compared` is `false` in *this* workflow. It works for pull requests from forks,
which get a read-only token in the compare job and no comment without this split.

GitHub runs a `workflow_run` workflow from the default branch only, so this file does nothing
until it has been merged.

## Security model

This follows the model in tak's
[adoption guide](https://tak.jdx.dev/guide/adopting#gate-pull-requests).

- **No job that executes pull-request code gets a write token.** The compare job needs only
  `contents: read`. Writing the comment and the check happens in the separate `workflow_run`
  job, which checks out nothing and runs nothing from the pull request.
- **Credentials are gone before project code runs.** In `compare` and `prepare`, the action
  fetches the base branch and `refs/notes/tak` with the token passed to it (the job's read-only
  token by default), passing the credential to git through the environment for that one
  command. It then removes what `actions/checkout` persisted: a legacy `http.extraheader` in
  `.git/config`, and, since checkout v6, the `includeIf` entry and the
  `$RUNNER_TEMP/git-credentials-*.config` file that actually holds the token. It checks that no
  `http.*.extraheader` remains in the effective configuration and fails otherwise. The `run`
  command and `tak compare` receive no token. `tak compare` refreshes the notes
  unauthenticated and falls back to the notes already fetched when that fails, which keeps
  private repositories working.
- **The action must come first.** Anything that runs between checkout and `prepare`/`compare`
  runs while the token is still reachable. Put the build in `run`, or use `prepare` before
  other actions. Actions you add after `prepare` may still receive the job's read-only token
  through their own inputs (`jdx/mise-action` has a `github_token` input that defaults to it);
  that is why the job's permissions must stay read-only.
- **The report artifact is untrusted data.** The comment job reads only named regular files
  from it, caps their size, accepts `status` from a fixed set, and ignores anything else. The
  pull request to comment on and the commit to attach the check to come from the
  `workflow_run` event, not the artifact: `workflow_run.pull_requests` for same-repository pull
  requests, or open pull requests whose head is that branch at that exact commit for forks. A
  zero-width space follows every `@` in the report so it cannot mention people. The comment job
  refuses to run for any event other than `workflow_run`.
- **The gate is not tamper-proof.** A pull request can change its own copy of the compare
  workflow, or the build it runs, and so change what the report says. The gate catches
  accidental regressions; it is not a control against a malicious contributor. Review changes to
  workflows and to `tak.toml` as you would any other code.
- **tak is downloaded from its GitHub release and checked against the release's `SHA256SUMS`.**
  That detects a corrupted or substituted download, not a compromised release: the checksums
  come from the same place. tak's releases also carry a sigstore-signed `packslip`; this action
  does not verify it yet.
- In `record`, the token is passed only to the steps that push and read notes, again through
  the environment. The `run` command does not receive it. Main-branch code is trusted there,
  as in any workflow that pushes.

## Inputs

| input | modes | default | description |
|---|---|---|---|
| `mode` | all | required | `record`, `compare`, `comment`, `prepare` or `install` |
| `version` | all but comment | required | tak release to install, such as `0.0.13`. No default: changing the measuring instrument can put a step in the series, so upgrade it deliberately |
| `install` | all but comment | `true` | download tak; when `false`, use the `tak` on `PATH` (checked against `version` if given) |
| `install-valgrind` | all but comment | `true` | install valgrind with `apt-get` when it is missing |
| `working-directory` | all but comment | `.` | directory inside the repository to run in |
| `run` | record, compare | `tak run --record` | build-and-measure command, run with `bash -euo pipefail` |
| `measure` | record, compare | `true` | run `run`; set `false` if an earlier step already ran `tak run --record` |
| `runner-class` | record, compare | | exported to `run` as `TAK_RUNNER`; empty uses `tak.toml` or tak's default |
| `gate-pct` | compare | | override `[gate].pct` |
| `token` | all | `github.token` | record: pushes notes (needs `contents: write`). compare/prepare: fetches the base and notes before any project code runs. comment: downloads the artifact, writes the comment and check |
| `push` | record | `true` | push `refs/notes/tak` after recording |
| `summary` | record | `true` | append `tak history` to the job summary |
| `base-ref` | compare, prepare | pull request base | branch to compare against, by its merge base with HEAD |
| `base` | compare, prepare | | full SHA to compare against instead; overrides `base-ref` |
| `head-sha` | compare, prepare | pull request head | commit that must be checked out; fails if HEAD differs. Empty skips the check |
| `fail-on-regression` | compare, comment | `true` | fail (or, in comment, conclude the check `failure`) on a regression; `false` reports only |
| `fail-on-nothing-compared` | compare, comment | `true` | the same for an empty comparison |
| `upload-artifact` | compare | `true` | upload the report for a comment job |
| `artifact-name` | compare, comment | `tak-report` | name of the report artifact |
| `run-id` | comment | triggering run | run whose artifact to read |
| `comment` | comment | `true` | post or update the sticky comment |
| `comment-key` | comment | `tak` | tells this report's comment apart from others on the same pull request |
| `check` | comment | `true` | create a check run on the head commit |
| `check-name` | comment | `tak / instruction-count` | name of the check run |

Boolean inputs accept `true` or `false` and nothing else, so a typo cannot switch a gate off.

## Outputs

| output | modes | description |
|---|---|---|
| `status` | compare, comment | `pass`, `regressed`, `nothing-compared` or `error`; comment reports `skipped` when the triggering run was not a pull request or was cancelled |
| `report` | compare | path of the markdown report |
| `head-sha` | compare, prepare | the commit measured |
| `base-sha` | compare, prepare | the commit compared against |
| `conclusion` | comment | the check run's conclusion |
| `pr-number` | comment | the pull request reported on, or empty |
| `comment-url` | comment | URL of the sticky comment |

## How the outcome is decided

tak has no machine-readable comparison output yet, so the action classifies `tak compare` by
its exit status and the text of its report. This is a stopgap until tak grows such an output.

- **nothing-compared**: the report starts with `**Nothing was compared`. This is checked first
  and regardless of the exit status: released tak versions exit 0 for an empty comparison, and
  newer ones may exit non-zero unless given `--allow-empty`. The action never passes that flag
  and applies `fail-on-nothing-compared` itself, so both behave the same.
- **pass**: exit status 0.
- **regressed**: a non-zero exit status and the report's `benchmark(s) above the …% gate` line.
- **error**: anything else, including a failed build, a moved `HEAD`, a failure before the
  comparison, or a non-zero exit without that line. If tak ever rewords the gate line, a
  regression lands here and still fails; it is not mistaken for a pass.

## The report artifact

`compare` uploads a directory of plain files: `report.md`, `status`, `head-sha`, `base-sha`,
`pr-number` and `format`. `format` is `1`. The comment job refuses a report in a format it does
not know, which can happen when the pull request and the default branch pin different
releases of this action. The format is pre-v1 and may change.

## Limitations

- Linux only, for the valgrind reason above. aarch64 Linux runners are supported by tak's
  release assets but have not been tested with this action.
- The outcome is parsed from report text, as described above.
- The comment job cannot be tried from the pull request that adds it; `workflow_run` workflows
  run from the default branch.
- Only token-based checkout credentials are removed. An SSH key given to `actions/checkout`
  (`ssh-key`) or credentials set up by other steps are not handled. Credentials in submodule
  configuration are not handled.
- `SHA256SUMS` is checked; the sigstore `packslip` signature is not.
- `record` measures the tip of each push. A push with several commits records only the last.
- Main and pull-request jobs must use the same runner class and build inputs, or every
  comparison is empty. This action cannot detect a changed runner image; see
  [runner classes](https://tak.jdx.dev/guide/adopting#record-the-main-branch).

## Development

```sh
mise run lint    # actionlint, shellcheck, zizmor
```

`.github/workflows/test.yml` runs `record` and `compare` end to end against a throwaway fixture
whose origin is a local bare repository: a pass, a regression, an empty comparison, a failed
build, a wrong head commit, and credential removal after a real `actions/checkout` with
`persist-credentials: true`. `.github/workflows/test-comment.yml` runs `comment` on this
repository's own pull requests once it is on the default branch.

Releases are automated as in `jdx/mise-action`: `release-plz.yml` opens a `chore: release
vX.Y.Z` pull request from conventional commits, and merging it tags the release and moves `v0`.

## License

MIT
