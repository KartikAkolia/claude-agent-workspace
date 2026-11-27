# Repo tooling

The scripts at the repo root, plus `scripts/sync-docs-to-trilium.py`, are this repo's own lint, version-tracking and mirror tooling, and `.github/workflows/` runs the lint parts in CI. Most of it runs without anyone asking: `.githooks/pre-commit` on every `git commit` in a clone with `git config core.hooksPath .githooks`, and the workflows on every push and pull request. `lint-markdown.sh`, `refresh-reference-clone.sh` and the Trilium sync are run by hand. [../README.md](../README.md) has the overview; this doc holds the contracts the scripts' short header comments don't carry: modes, exit codes, environment variables, invariants and known limitations. The fixes behind most of these rules are in [script-audit-2026-11-14.md](script-audit-2026-11-14.md), cited here by row ID (TOOL-1 and so on).

| Tool | Run by |
| --- | --- |
| `.githooks/pre-commit` | git, on every commit |
| `lint-bash.sh`, `lint-python.sh`, `validate-config.sh`, `check-markdown-links.py` | the hook (staged files), CI and `lint-markdown.sh` (every tracked file) |
| `lint-markdown.sh` | by hand: the full local sweep |
| `list-lint-files.sh` | sourced by the hook, `lint-bash.sh`, `lint-markdown.sh` and `refresh-reference-clone.sh`; run by CI and the Trilium sync |
| `lint-versions.sh` | sourced by `lint-bash.sh`, `lint-python.sh` and `lint-markdown.yml`; run by the hook and CI |
| `refresh-reference-clone.sh` | by hand, only for a resync Kartik asked for (AGENTS.md non-negotiable #1) |
| `scripts/sync-docs-to-trilium.py` | by hand, after docs change |

## Shared conventions

`lint-bash.sh`, `lint-python.sh` and `validate-config.sh` take the files to check as arguments and exit 0 when given none, so the caller decides what gets checked; `lint-bash.sh` and `lint-python.sh` still run with no files under the hook's `LINT_VERSIONS_MODE` (`sync` or `index`), to check a changed version line. `check-markdown-links.py` takes files the same way but treats none as a usage error. The lint scripts lint whatever they're given: skipping the reference clones and `node_modules` is the caller's job, and every caller here does it by taking its lists from `list-lint-files.sh`, so the hook, the full sweep and CI agree on which file is which. Exit status is 0 for clean, 1 for a finding or failure, and 2 for a usage error where a script has one.

Where a script needs Python (`lint-markdown.sh`, `validate-config.sh`, the hook) it tries `python3`, then `python`, and takes the first that actually runs `-c ""`, rather than trusting `check-markdown-links.py`'s `#!/usr/bin/env python3` shebang. On Windows, `python3` can resolve to the Microsoft Store App Execution Alias stub, which prints an install prompt and exits nonzero even when a real interpreter is on `PATH`.

## `list-lint-files.sh`

```sh
./list-lint-files.sh [-z] <markdown|config|bash|python>   # one category's files
./list-lint-files.sh --reference-clones                    # <dir> TAB <owner/repo> TAB <branch>, one per mirror
```

It lists files git tracks (`git ls-files -z`, so a non-ASCII name prints as itself, never C-quoted: TOOL-5), minus the reference clones, anything under a `node_modules` directory at any depth (TOOL-11), and anything under `.git/`. The clones are also excluded in the `git ls-files` pathspec, so git never walks their thousands of files. Dot-directories are not excluded, so `.claude/skills/` is linted (TOOL-6). A file's category is its extension when that's one of the linted ones: `.md` is markdown, `.json`, `.yml` and `.yaml` are config, and `.py` is python. Otherwise the file is in `bash` if its first line (read up to 512 bytes) is a `bash`, `sh` or `dash` shebang. The interpreter is the shebang's first word or, for `env`, the first word after its options and `NAME=value` settings, so `#!/usr/bin/env -S bash -e` counts, and a trailing CR from a CRLF checkout is ignored (TOOL-7, TOOL-12). So `bash` means every shell script `lint-bash.sh` handles, POSIX sh included, whatever its filename.

With `-z` every path ends in a NUL, which is what every consumer here uses. Without it each ends in a newline, and a name containing a newline is an error rather than a split or dropped name. It exits 0 with the list; 1 if `git ls-files` fails, if the category matches no file, if a name has a newline (without `-z`), or if `reference-clones.tsv` is invalid; and 2 for a usage error or an unknown category. An empty category is an error on purpose: every category has files in this repo, so an empty list means something broke, and a lint run over nothing must not pass (TOOL-4).

Sourced, it defines the helpers below. Sourcing parses `reference-clones.tsv` straight away and fails (returns 1, after the parser's message) if the file is missing or invalid; every caller checks for that.

| Helper | Contract |
| --- | --- |
| `llf_excluded <path>` | 0 if no lint applies to the path (a reference clone, `node_modules`, `.git/`) |
| `llf_name_category <path>` | sets `LLF_CATEGORY` from the extension; 1 if it isn't a linted one |
| `llf_shell_of <first-line>` | sets `LLF_SHELL` to `bash` or `sh` from a shebang line; 1 if it isn't a shell one |
| `llf_file_shell <file>` | the same, from the file's first line; 1 if the file doesn't exist |
| `llf_category_of <path>` | the shared path rules: sets `LLF_CATEGORY` by extension, else to `bash` for a shell shebang; 1 for an excluded path or one no linter takes. `llf_filter` and the pre-commit hook both sort with it, and the hook refuses an index whose lister lacks it |
| `llf_filter <category> <sep>` | filters NUL-separated paths on stdin to one category, printed NUL-terminated when `<sep>` is `nul`, else newline-terminated; 3 if none matched |
| `llf_list <category> <sep>` | prints the category's tracked files, with the CLI's exit codes |
| `llf_read_list <category> <array>` | fills the named array with the category's files; nonzero, the lister having said why, on failure |
| `llf_reference_clone_for <owner/repo>` | sets `LLF_CLONE_DIR` and `LLF_CLONE_BRANCH` for that upstream, matched case-insensitively as on GitHub; 1 if it isn't a mirror |

`llf_read_list` goes through a temporary file rather than `mapfile < <(...)`, because process substitution would hide a lister failure (TOOL-4). The parsed mirror list stays in the parallel arrays `LLF_REFERENCE_CLONES`, `LLF_REFERENCE_REPOS` and `LLF_REFERENCE_BRANCHES`, plus `LLF_REFERENCE_OWNERS`. `LLF_DIR` is the checkout the script lives in, which is the one it lists and whose `reference-clones.tsv` it reads.

## `reference-clones.tsv`

The one list of ChrisTitusTech's read-only mirrors. `list-lint-files.sh` is its only parser: the lint gates, the hook, `refresh-reference-clone.sh` and the Trilium sync all read it through that script, so its rules exist once. Each line is either `<dir> <owner/repo> <branch>` or `@owners <owner>...`, separated by tabs or spaces; `#` starts a comment anywhere on a line, and blank lines and CRs are ignored. The file is refused, and with it every lint gate and the refresh, if:

- it's missing or unreadable, lists no mirror, or has no `@owners` line (which may come anywhere in the file);
- a line isn't one of those two shapes, or a name has characters outside `A-Za-z0-9._-` (a branch may also contain `/`, but not `..`; a dir can't be `.` or `..`);
- a dir isn't named `<repo>-<branch>`, GitHub's name for a branch download (`website-master`);
- a dir, or an `owner/repo` compared case-insensitively, is listed twice;
- a mirror's owner isn't on an `@owners` line.

The naming and owner rules exist because `refresh-reference-clone.sh` runs `rsync --delete` into the dir: a mistaken line naming `docs` or another project directory can't pass them, and trusting a new owner takes a separate, deliberate edit to `@owners`. Check the file with `./list-lint-files.sh --reference-clones`. Adding or renaming a mirror is an edit here, and the four list-based lint workflows (all but `minecraft-tui.yml` and `gitleaks.yml`) re-run on a change to it.

## `.lint-versions`

One `tool=X.Y.Z` line for each of `shellcheck`, `shfmt`, `ruff` and `mdl`: the versions CI installs, and the versions the hook checks a commit against. A line's tool is everything before its first `=` or `#`, trimmed, and only the first line for a tool counts. `#` starts a comment, whole-line or trailing. The value must be exactly `X.Y.Z`, digits only, with spaces allowed around it but not inside: `0.1 0.0` is invalid rather than quietly reading as `0.10.0`, and `shellcheck # hold` with no `=` is still shellcheck's line, invalid rather than missing. A trailing comment whose first word is `hold`, in any case (`# hold`, `# hold: 0.11 regressed`, but not `# holder`), holds the line; see [Sync mode](#sync-mode).

`shellcheck` and `shfmt` follow the newest version installed on Kartik's machines: the hook's sync step bumps them. `ruff` is set by hand, because `uvx` runs exactly that version locally and in CI, so there's no installed copy to follow. `mdl` is set by hand too and never bumped; `lint-markdown.yml` gem-installs exactly it, and the hook only warns when the installed `mdl` is a different version.

## `lint-versions.sh`

It reads and updates `.lint-versions`. Exact versions matter because distro packages lag differently: on 2026-10-18, Ubuntu CI's apt shellcheck 0.9.0 flagged SC2015 where Arch's 0.11.0 didn't, and Ubuntu's apt shfmt was 3.8.0 against Arch's 3.14.1. CI only agrees with the hook when both run the same versions, so CI installs the exact releases `.lint-versions` names, and the hook keeps the file at what's installed locally.

| Command | Does | Exit |
| --- | --- | --- |
| `./lint-versions.sh get <tool>` | prints the tool's version from `.lint-versions` | 0; 1 if the file or a valid line for the tool is missing; 2 for a usage error |
| `./lint-versions.sh changed <tool>` | compares the staged version with HEAD's | 0 if they differ, 1 if not, 2 on a git or usage error |
| `LINT_VERSIONS_MODE=sync ./lint-versions.sh sync` | the hook's sync step: checks shellcheck and shfmt, then writes any bump | 0, or 1 on any problem, a bump not yet staged included; 2 without `LINT_VERSIONS_MODE=sync` |

`changed` is how the hook decides to lint every file of a kind when a commit changes that kind's linter, and the hook fails the commit on 2, so an error must never come back as 1, which would read as "unchanged". That covers an unknown tool too: it would parse as empty on both sides, so `changed` accepts only `shellcheck`, `shfmt`, `ruff` and `mdl` and exits 2 for anything else. A missing file, a missing or invalid line, or an unborn HEAD reads as no version, so adding or removing a line counts as a change.

Two environment variables steer it. `LINT_VERSIONS_DIR` is the checkout whose `.lint-versions` it reads, and in sync mode writes; it defaults to the script's own directory, and the hook sets it so the index's copy of the script, running from the hook's export, works on the real checkout. `LINT_VERSIONS_MODE` decides what an installed shell linter that doesn't match the file means:

| Mode | Set by | Behaviour |
| --- | --- | --- |
| `sync` | the hook's sync step, run against the working tree | see [Sync mode](#sync-mode): may write a bump, and fails until it's staged |
| `index` | the hook's `lint-bash.sh` and `lint-python.sh` runs, over its export of the index | the staged version is this commit's; decides the full re-lint; writes nothing, and doesn't repeat what the sync step said |
| `strict` | `lint-bash.yml` | the installed version must equal the file's exactly, since the workflow installed what the file says; an unreadable installed version fails too |
| unset | `lint-markdown.sh`, which clears it even if the caller exports it; one-off runs | warns about a missing or invalid line, an older installed version, or a newer one the next hook run will bump; notes a held line; writes nothing |

The installed version is the leading `X.Y.Z` of `shellcheck --version` or `shfmt --version`, so a git or distro build like `0.11.0-12-gabcdef` reads as `0.11.0`. A build that reports no version (a `go install` shfmt says `(devel)`) fails strict mode but elsewhere only warns, so one odd build doesn't block every commit on that host; sync and index mode still check the line itself. A linter that isn't installed at all is `lint-bash.sh`'s to report.

Known limitation: "this commit changes the version" always means "the staged version differs from HEAD's", and a pre-commit hook can't tell it's running for `git commit --amend`, where HEAD is the commit being amended. So amending a commit that already changed a version doesn't trigger the full re-lint again; CI's own full lint with that version is the backstop.

## Sync mode

Sync mode runs in the hook whenever a commit stages a shell script or changes the shellcheck or shfmt line, before the shell lint itself. For each of shellcheck and shfmt it answers one question: did you set this line on purpose? You did, and the hook leaves the line alone, if:

1. its trailing comment starts with the word `hold`, in the staged copy or in the working tree, for example to keep a rollback in place across later commits (`shellcheck=0.10.0  # hold: 0.11 regressed`);
2. the staged version differs from HEAD's, because you staged an upgrade or a rollback; or
3. the working-tree version differs from HEAD's but isn't staged: an edit in progress, which like any unstaged edit isn't part of this commit. The exception is a working-tree line that already equals the installed version while a bump is due. That's the bump itself (the hook's earlier write, or yours), so the commit keeps failing until it's staged.

Otherwise the line counts as untouched. If the installed version is newer than HEAD's, or there's no line yet, the installed version is written into it and the commit fails until that's staged. An installed version older than the line only warns: a line is never downgraded. A hold that's only in the working tree lets the commit through with the staged version, and says `git add .lint-versions` would commit the hold.

Whenever the version a commit gives CI differs from HEAD's, every tracked shell script is re-linted with it, as CI will, so the commit that bumps a linter can't fail CI on scripts nobody touched. That happens on the commit that carries the staged change, and only when the installed tool is that version; when it isn't, the hook warns that CI's verdict may differ from its own. When a commit keeps the version but a newer tool is installed and the line isn't held (an unstaged edit of yours stopped the bump), `lint-bash.sh` warns that it linted with a newer tool than the version CI will use.

Both tools are checked before anything is written, then the file gets a single write, because a write for the first tool would look like an unstaged edit to the second tool's check. Only the version value changes: the spacing and any trailing comment stay as written, a missing line is appended, and every other line passes through byte for byte, CRLF endings, blank lines and a missing final newline included. The file is written in place rather than replaced, so its mode and any symlink survive, and only when something changes, so a retry after the bump is already on disk doesn't touch it. A missing file is rebuilt from the staged copy, else HEAD's, so the ruff and mdl lines and the comments survive; with neither, it's created and the message asks for a `ruff=` line. The hook never stages anything itself. It fails with `git add .lint-versions and commit again` (for `git commit <paths>`, `.lint-versions` has to be in the paths too), and when the file holds other unstaged changes it suggests `git add -p`, so they aren't committed by surprise.

Sync mode also fails the commit when `LINT_VERSIONS_DIR` isn't a git work tree, when git can't read the staged or HEAD copy, when a tool's staged line isn't a valid `X.Y.Z` (it would reach CI's `get` as it is), and when the commit would end up with no line for a tool. It also fails when the working-tree line is invalid and neither HEAD nor the index has a version for that tool, the one case where an invalid edit would otherwise read as untouched and be overwritten. A commit that removes `.lint-versions` from the index while HEAD has it is told how to undo that: `git restore --staged .lint-versions`, plus `--worktree` when the file is gone from disk too.

## `lint-bash.sh`

`lint-bash.sh <file>...` runs `shellcheck`, `shfmt -d` and a syntax check over the given scripts: `sh -n` for a `sh` or `dash` shebang, `bash -n` for anything else. shellcheck and shfmt read the dialect from the shebang themselves. It checks both linters against `.lint-versions` first, even when one isn't installed, so that line is still validated before a commit can carry it to CI, and then makes the one sync-mode write (a no-op outside sync mode). A linter missing from `PATH` fails the run.

When a commit changes a linter's version and the installed tool is that version, that linter runs over every tracked shell script from `list-lint-files.sh` instead of only the given files. Tracked files that are gone from disk are skipped, and a list that can't be built fails the run rather than lint nothing. The syntax check always covers only the given files. With no files, `LINT_VERSIONS_MODE` unset or `strict` exits 0 straight away; under the hook's modes it checks versions and runs the full re-lint when one applies.

## `lint-python.sh`

`lint-python.sh <file>...` runs `uvx ruff@<version> check` and `uvx ruff@<version> format --check` at exactly the `ruff` version in `.lint-versions`, so nothing needs a system-wide install. A bare `uvx ruff` would keep reusing whichever version uvx first cached locally while CI fetched each new release, so the two would drift. There's no separate syntax check: ruff's own parser already reports invalid syntax, and `python3 -m py_compile` was dropped because it writes `__pycache__/*.pyc` even under `-B`.

Under the hook (`LINT_VERSIONS_MODE` set to `sync` or `index`), the version comes from the staged `.lint-versions`, which is what CI will read, not from an unstaged edit. A `.lint-versions` that isn't in the index gets a message for each cause (removed by this commit, never staged, or missing altogether), and a git error is reported as one rather than read as "not there". Outside the hook it reads the working-tree file and fails if that's missing. With no files it exits 0, except under the hook, where it still checks that `uvx` can install the staged version, since a commit that changes only the ruff line would otherwise fail CI at install time. A missing `uvx` or no valid `ruff=` line fails the run.

## `validate-config.sh`

`validate-config.sh <file>...` checks that JSON and YAML files parse, nothing more. It's there to catch a typo in `.claude/settings.json` or a workflow before it silently breaks hook or tool wiring at runtime. `.json` files go through `python -m json.tool`. `.yml` and `.yaml` files go through Ruby's Psych, which loads every document in the file (`Psych.safe_load` reads only the first) with aliases allowed and `safe_load`'s restricted class loader: plain YAML types plus `Date`, `DateTime`, `Time` and `Symbol`, so a `!ruby/object` tag is refused, never instantiated (TOOL-10). A syntax error anywhere, or an alias to an undefined anchor, fails with Ruby's own message saying where. Other extensions are ignored, and a missing interpreter fails each file that needs it.

## `check-markdown-links.py`

```sh
check-markdown-links.py [--index] [--real-root DIR] <file.md>...
```

Paths are relative to the repo root (the script's own directory) or absolute. It exits 0 when everything resolves; 1 when a reference is broken (`file:line: broken reference to target`) or a file can't be checked (not valid UTF-8, or not in the index under `--index`); and 2 for a usage error or, under `--index`, a failed `git ls-files`.

It flags references to local files that don't exist, the break a rename or delete leaves behind. Three kinds are checked:

- inline links and images, `[text](target)`, including an `<angle bracket>` target, one level of balanced parentheses in the target, and a trailing `"title"`, `'title'` or `(title)`;
- reference definitions, `[label]: target`, but not footnotes (`[^1]: ...`);
- backtick paths in prose that contain a `/` and end in `.md`, like `` `docs/handoff.md` ``. Bare filenames like `SKILL.md` are generic terms in this repo's prose, so they're deliberately not checked.

Link and definition targets resolve the way GitHub renders them: against the linking file's directory, or the repo root for a target with a leading `/`. The query string and `#fragment` are dropped and the rest is URL-decoded (`%20` is a space). A URL, a `//host` link, any `scheme:` target such as `mailto:`, and a bare `#anchor` are skipped. Anchors are never checked, so a link to a renamed heading isn't caught. A backtick path is prose rather than a link, so it may be relative to the repo root, to the file's directory, or, in a file under `.claude/skills/<name>/`, to that skill's root, which is what skill files mean by a path like references/x.md. Inside fenced code blocks (three or more backticks or tildes, closed by a run of the same character at least as long, indented or in a blockquote too) and inline code spans, only backtick paths are looked for, so `[ERROR]: timeout` in a log isn't read as a link. A target git ignores is skipped as deliberately absent from the checkout (`java-calculator/`, named in `docs/handoff.md` as cross-host notes); if git can't run, nothing is treated as ignored.

With `--index`, as the hook runs it, both the files and their targets come from the git index, which is what the commit will contain. The files are read as staged blobs, and a target inside the repo must be in the index (a directory counts when anything indexed is under it), so a link to a file that was never `git add`ed fails. `GIT_INDEX_FILE` is honoured. Without `--index`, as the full sweep and CI run it, it's the working tree. A target outside the repo can't be in any commit, so it's always looked for on disk, beside `--real-root` when that's given: the hook runs the script from its export of the index, where a `../` target would otherwise point into a temporary directory.

Known limitation ([audit](script-audit-2026-11-14.md#still-needs-kartik), item 6): backtick paths count only when they end in `.md`, so deleting a script a doc names only in backticks or in a code block isn't caught.

## `lint-markdown.sh`

The full local sweep, run by hand with no arguments. It lists every category through `list-lint-files.sh` and runs `mdl` plus `check-markdown-links.py` (working tree, no `--index`) on markdown, `validate-config.sh` on config, and `lint-bash.sh` and `lint-python.sh` on shell and Python. `LINT_VERSIONS_MODE` is cleared for the last two, so a sweep only warns about versions even when the calling shell exports the variable. A category that can't be listed fails the sweep, but the other checks still run. It doesn't run the `unittest` suites. Neither the hook nor CI calls it: CI was split into four path-filtered workflows on 2026-09-03, so that a markdown-only change, say, doesn't also trigger the bash, Python and config checks.

## `.githooks/pre-commit`

The hook lints exactly what the commit contains, with exactly the tooling and config the commit contains (TOOL-2). git runs the working tree's copy, which exports the index (every tracked file except the reference clones) to a temporary directory with `git checkout-index` and runs the index's own copy of the hook there. That copy calls the index's copies of the lint scripts and reads the index's `.mdlrc` and `.mdl_style.rb`. So unstaged edits, partial staging (`git add -p`) and untracked files make no difference: an unstaged fix doesn't hide a staged error, and an unrelated unstaged edit doesn't block a commit. To get past a failed commit, fix the file and stage it again.

The outer run (no `LINT_HOOK_EXPORT` in the environment) does the export:

- A relative `GIT_INDEX_FILE` is made absolute, since `git commit <paths>` and `git commit -a` point it at a temporary index, possibly by a relative path, and the inner run works from elsewhere.
- Which directories are clones comes from the index's own `list-lint-files.sh` run on the index's own `reference-clones.tsv`, both exported on their own first, so a malformed staged list fails the commit with the lister's message rather than excluding the wrong paths. A commit missing either file fails, including one whose tooling predates `reference-clones.tsv` (the transitional whole-index export for those was removed on 2026-11-15, once every branch had the list, so rewriting history from before 2026-11-14 needs `git commit --no-verify`).
- An export that comes out empty fails the commit.
- If the commit drops the hook from the index, or it isn't executable in the export, the working tree's copy lints the commit instead.
- The inner run gets `LINT_HOOK_REPO` (the real checkout), `LINT_HOOK_EXPORT` (the export) and `GIT_DIR` (the real repository). Its output has the export's path prefix stripped, so messages show repo-relative paths, and its exit status is the hook's.

The inner run works in the export, with `GIT_WORK_TREE` set to it and `GIT_OPTIONAL_LOCKS=0`. git still reads the real repository, so `git diff --cached`, the link check and the version checks all see this commit's index and HEAD. In order:

1. The paths the commit adds, copies, modifies or renames to (ACMR) are sorted into markdown, config, shell and Python with `list-lint-files.sh`'s `llf_category_of`, in one pass in the hook's own shell (an index whose lister lacks the helper fails the commit), and the paths it deletes or renames away (DR) are listed separately. Both lists come from `git diff --cached -z` through files, so a git failure fails the commit.
2. A commit with any deletion or rename gets every tracked markdown file's links checked, since any doc may point at what went (TOOL-8).
3. If `.lint-versions` differs from HEAD's (deleting it counts), `./lint-versions.sh changed` is asked about each tool. A ruff change lints every `.py` file; an mdl change runs `mdl` and the link check over every markdown file; a shellcheck or shfmt change runs the shell step even with no shell script staged, and `lint-bash.sh` decides whether a full re-lint means anything. An exit status of 2 fails the commit rather than reading as unchanged.
4. `mdl` runs on the markdown files. A missing `mdl` fails the commit with the gem user bin directory to add to `PATH`; an installed `mdl` that differs from `.lint-versions` only warns.
5. `check-markdown-links.py --index --real-root <real checkout>` checks the links.
6. `validate-config.sh` checks the config files.
7. The shell step runs the sync step first. That's the one step that works on the working tree, and the only thing the hook ever writes: the index's `lint-versions.sh` with `LINT_VERSIONS_DIR` set to the real checkout, `LINT_VERSIONS_MODE=sync`, and `GIT_WORK_TREE` unset so git sees the real checkout as the work tree. Then `LINT_VERSIONS_MODE=index ./lint-bash.sh` lints the staged shell scripts with the versions this commit gives CI.
8. `LINT_VERSIONS_MODE=index ./lint-python.sh` lints the staged `.py` files, and runs with no files too when ruff changed.
9. When the commit adds, changes, deletes or renames anything under `minecraft-tui/` (found with `git diff --cached --quiet -- minecraft-tui`, whose pathspec also catches a file renamed out), unless it removes the crate entirely, `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings` run in the export's copy of the crate, with `CARGO_TARGET_DIR` set to the real checkout's `minecraft-tui/target` so the dependencies don't rebuild every time. A missing `cargo` fails the commit.

Every step runs even after an earlier one fails, and any failure fails the commit. A setup failure (a git error, a file list that can't be built) fails it too, and skips the remaining version checks so a git error isn't repeated for every tool. The hook doesn't run the `unittest` suites or `cargo test`; only CI does.

## CI workflows

All six workflows run on `ubuntu-latest` and pin every action by commit SHA, with its tag in a trailing comment (TOOL-13). All but `gitleaks.yml` set `defaults.run.shell: bash`, so each step runs under `bash -eo pipefail` rather than GitHub's default `bash -e`. The four list-based ones (all but `minecraft-tui.yml`, which checks its one crate, and `gitleaks.yml`) each read their file list NUL-separated from `./list-lint-files.sh -z <category>` through a file, so a lister failure or an empty list fails the step (TOOL-4). None of them is a required check; see `SPEC.md`'s Testing & CI section.

| Workflow | Triggered by | Runs |
| --- | --- | --- |
| `lint-markdown.yml` | every push and pull request | a scope step, then `mdl` and/or `check-markdown-links.py` over every tracked markdown file |
| `lint-config.yml` | `**.json`, `**.yml`, `**.yaml`, `validate-config.sh`, `list-lint-files.sh`, `reference-clones.tsv`, itself | `validate-config.sh` over every config file |
| `lint-bash.yml` | `**.sh`, the extensionless shell scripts by name, the test files it runs plus `scripts/device-power-saving-config.py`, `.lint-versions`, `reference-clones.tsv`, itself | `LINT_VERSIONS_MODE=strict ./lint-bash.sh` over every shell script, then the `unittest` suites `scripts/test_install_fedora.py`, `scripts/minecraft-fabric/test_install.py`, `scripts/test_tui_lib.py` and `scripts/test_device_power_saving.py` |
| `lint-python.yml` | `**.py`, `lint-python.sh`, `list-lint-files.sh`, `reference-clones.tsv`, `lint-versions.sh`, `.lint-versions`, itself | `./lint-python.sh` over every `.py` file (unset mode, so the checkout's ruff line), then `uv run -q --script scripts/test_sync_docs_to_trilium.py -v` |
| `minecraft-tui.yml` | `minecraft-tui/**`, itself | in `minecraft-tui/`, on Rust 1.100.0 (`RUSTUP_TOOLCHAIN`, installed with rustup), pinned so a new clippy lint can't fail an unrelated change; bump it with the local Rust. Job `check`: `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` and `cargo test --locked`. Job `build`, in parallel: `cargo build --release --locked`, uploaded as a 7-day artifact |
| `gitleaks.yml` | every push and pull request | `gitleaks/gitleaks-action` secret scanning, with the full history checked out (`fetch-depth: 0`); no `GITLEAKS_LICENSE`, which only organisation-owned repos need |

A path filter sees paths, not file contents, so `lint-bash.yml` names the shell scripts that have no `.sh` extension one by one: `.githooks/pre-commit`, `.claude/skills/quickshell/scripts/quickshell-qmllint`, `scripts/xppen-tablet/xppentablet` and `scripts/xppen-tablet/xppen-tablet.install`. A new one needs adding there, and to `.gitattributes` to pin it to LF (TOOL-7).

`lint-markdown.yml` has no path filter because deleting or renaming any file can break a link, and a filter only sees the paths a change touches. Its first step diffs against the base (the push's `before`, or the first parent of a pull request's merge commit) with `--no-renames`, so a rename shows its old path as a deletion, and decides what to run. `mdl` runs for a changed markdown file, `list-lint-files.sh`, `reference-clones.tsv`, the workflow itself, `.mdlrc`, `.mdl_style.rb`, `lint-versions.sh`, or a changed `mdl=` value in `.lint-versions` (not the hook's shellcheck and shfmt bumps, or ruff). The link check runs for a changed markdown file, `list-lint-files.sh`, `reference-clones.tsv`, the workflow, `check-markdown-links.py` or any `.gitignore`, and for any deletion. Anything uncertain (another event, no base commit as on a new branch, a base that can't be fetched after a force push, a git failure) means a full run.

`minecraft-tui.yml` replaced `lint-rust.yml` on 2026-11-27 and is the only workflow with `concurrency` (a newer push to the same branch or pull request cancels the running build; on `master` the group is the commit, so every merged commit keeps its own result), a read-only `permissions: contents: read` token and a `timeout-minutes` (15 per job). It has two parallel jobs because the optimised release profile shares no build output with the dev-profile clippy and test builds, only the downloaded crates. One job would gain almost no cache reuse and would run the slowest stage last; a third job for lint alone wouldn't pay for its runner startup and toolchain install, since clippy and the test build share their build scripts and proc macros and fmt takes under a second. Simulated on 4 of the laptop's cores with clean target directories and `CARGO_INCREMENTAL=0`, the `check` job's fmt, clippy and tests take about 11 s and the `build` job's release build about 11 s (17 s and 19 s before the 2026-11-27 build-time work; [minecraft-tui.md](minecraft-tui.md#build-time) has the details). The artifact uses the everyday `release` profile rather than the fat-LTO `dist` one, which takes about 1.7 times as long.

The cache is `Swatinem/rust-cache`, not a hand-keyed `actions/cache`. It keys on every installed toolchain's `rustc -vV`, the crate's `Cargo.lock` and parsed `Cargo.toml` (profiles included) and the `RUST*`/`CARGO*` variables. The toolchain step uninstalls the runner image's own `stable` for that reason: otherwise each new stable on the image would change the restore keys too and empty the cache. It falls back to an older lockfile's cache, pruning week-old files from such a partial restore, and drops the crate's own build output before saving, so the cache holds only dependencies. It also sets `CARGO_INCREMENTAL=0` for the later steps, so CI never builds incrementally. The job id is part of the key, so each job keeps its own profile's build. It saves only when a job succeeds. The release binary is packed into `minecraft-tui-<sha>-x86_64-linux.tar.gz`, since the artifact zip drops the executable bit, and uploaded with `archive: false`, so the download is that tarball; `<sha>` is the commit built, which on a pull request is GitHub's merge commit. It's built on Ubuntu, so it needs that glibc or newer, and its default `--script` path is the runner's checkout, so a downloaded copy needs `--script` or `MC_TUI_SCRIPT`. Each job writes a step summary: the toolchain, CPU count and whether the cache was an exact hit, then a table of wall times for the rustup install, the cache restore, each cargo command and the job so far, plus the artifact's name, the tarball's sha256 and the binary's size. The summary is written even when a job fails or hits its timeout. Only the timed steps have rows: checkout, packaging, the upload and the cache save at the end of a job have none, and neither does a step that didn't run or one killed by the timeout. The artifact note is written only once the upload has succeeded. Once the toolchain is installed, every check and the release build, with its upload, run even after an earlier check or the cache step fails, so a formatting nit doesn't hide a test failure. It runs on pushes to branches only, since GitHub ignores `paths` for tag pushes. Like the other workflows, it runs on both `push` and `pull_request`, so a push to a branch with an open pull request runs it twice, once per ref. The steps both jobs share are written once and repeated with YAML anchors, which GitHub has accepted since September 2025.

Every tool version CI runs comes from `.lint-versions` (`./lint-versions.sh get <tool>` prints it):

- shellcheck and shfmt: `lint-bash.yml` installs the official release binaries for exactly those versions, not Ubuntu's apt packages, ahead of anything preinstalled on `PATH`, and strict mode fails if they still don't match. Each download goes to a file, since a `curl --retry` after a partial transfer would feed a pipe the bytes twice, and is checked against a sha256 before it's unpacked or run. The sha256 is the one pinned in the workflow for that release asset when there is one; otherwise it's the digest GitHub records for the asset, with a `::warning::` to pin it. That fallback exists because the hook bumps `.lint-versions` to whatever's installed locally, so a new version mustn't need a workflow edit first. A release with neither a pin nor a GitHub digest (assets uploaded before mid-2025) fails ([audit](script-audit-2026-11-14.md#still-needs-kartik), item 7).
- ruff: `astral-sh/setup-uv` installs uv, and `lint-python.sh` runs exactly that ruff through `uvx`.
- mdl: `gem install --user-install mdl -v <version>`, since the runner's system gem directory isn't writable, then a check that `mdl --version` matches. mdl's own gem dependencies aren't pinned.

## `refresh-reference-clone.sh`

```sh
./refresh-reference-clone.sh [--force-large-change] <owner/repo> <branch> <local-dir>
```

The one sanctioned write into a mirror, run only when Kartik asks for a resync. It needs `gh`, `rsync`, `git`, `realpath` and `tar`, downloads `gh api repos/<owner/repo>/tarball/<branch>`, and syncs it into the mirror with `rsync -rlcE --delete`. It doesn't commit: the result is a working-tree change to review. It exits 0 when the mirror is already current or has been synced, 1 for any refusal or failure, and 2 for a usage error. `--force-large-change` must come first.

Before anything is downloaded (TOOL-1):

- the branch must be a plain name, with no leading `-` or `/`, no `..`, and only `A-Za-z0-9._/-`, since it ends up in the `gh api` path;
- the repo root is wherever the script really lives (resolved with `realpath`), and must be its git repo's top level, so a stray copy elsewhere can't treat its own directory as the repo;
- `<owner/repo>` must be a mirror in `reference-clones.tsv`, read through `list-lint-files.sh`; a `<branch>` other than the listed one is allowed, with a note;
- the mirror must be a plain directory, not a symlink, directly under the root, and `<local-dir>` must resolve to exactly that directory. Anything else (`.`, `docs`, a path outside the repo, a symlink to the root, another mirror's name) is refused.

Gitignored, untracked paths inside the mirror (`website-master/.claude/`, for one) are local-only. Each becomes an anchored `--exclude`, so `--delete` keeps it, upstream can't overwrite it, and the change report never lists it (TOOL-14). rsync reads a pattern as wildcards only when it contains `*`, `?` or `[`, so in such a name each `\`, `*`, `?`, `[` and `]` is backslash-escaped; a name with a newline can't be written into a rule at all, so it stops the run.

The change report is a dry run of the very rsync that does the sync, with the same options and exclusions plus `--itemize-changes`, so it lists exactly what will change, and a rerun after a sync reports nothing. It compares content by checksum, symlinks and the executable bit, which is what git tracks, and not mtimes, which differ between a tarball and a checkout without meaning anything. rsync's other output goes to stderr as notes, except "cannot delete non-empty directory": that's a directory upstream dropped that still holds a local-only file, which is meant to stay.

If the sync would delete or overwrite more than half the files git tracks in the mirror, it stops with nothing changed unless `--force-large-change` is given, because the wrong upstream, or a wrong line in `reference-clones.tsv`, looks like that. New files and directory deletions don't count.

Every rsync's exit status is checked (TOOL-3). A failed dry run exits 1 before anything is written. A failed sync exits 1 saying the mirror may be partly updated and to check `git status -- <mirror>`. After a sync the same dry run must find nothing; if it can't run, or still reports differences (the sync can't converge, so every later run would report changes), it prints them and exits 1.

## `scripts/sync-docs-to-trilium.py`

It mirrors this repo's markdown into Trilium (`https://trilium.kartikpassbolt.org` unless `--url` or `TRILIUM_URL` says otherwise) as read-only text notes under one parent note, "claude-agent-workspace docs". It runs through `uv run --script` (its shebang; the inline metadata declares its `markdown` dependency), by hand after docs change. Its module docstring is its `--help` text, which gives the usage: `--dry-run` shows what would change without writing, `--prune` deletes notes for docs that are gone, and each path is a file or folder inside the repo, relative to the current directory, with `docs/` the default. The ETAPI token comes from `TRILIUM_ETAPI_TOKEN` or `~/.config/trilium-etapi-token` (Trilium, Options, ETAPI, Create new token). What `--help` doesn't spell out:

- Each markdown file becomes one text note, rendered to HTML, and each directory a folder note. Notes are matched to files by their `workspaceDocPath` label, not their title, so a rerun updates them in place. A note is rewritten only when its final HTML, resolved links included, differs from the hash in its `workspaceDocHash` label, so unchanged docs don't pile up revisions.
- The repo is the source of truth: doc notes carry `#readOnly`, and an edit made in Trilium is overwritten the next time that doc's rendering changes.
- Relative links between synced docs become Trilium internal links, with a leading `/` meaning the repo root and anything else relative to the document. Other relative links, and all images, can't resolve in Trilium and are reported whenever that note is written. Links inside raw HTML blocks are left alone and not reported.
- Only files git tracks, or would track, are synced, so gitignored nested repos (`estuary/`, `personal-website/`) never leave the machine. Hidden paths, `node_modules` and the reference clones (read through `list-lint-files.sh --reference-clones`) are skipped, and so is a symlink that resolves outside the repo or to a skipped path.
- Notes for deleted files are only listed until a run with `--prune`. Pruning never deletes a note that's cloned elsewhere in Trilium (a delete would remove every placement) or a folder holding anything but stale docs. Protected notes are skipped with a warning, never written or pruned, since ETAPI can't open a protected session.
- It stops rather than guess when more than one note carries the `workspaceDocsRoot` label, when two notes carry the same `workspaceDocPath` (Trilium's Duplicate copies labels; the message names the likely original), or when doc notes exist but no root does.
- It won't send the token over anything but HTTPS, localhost aside, and refuses HTTP redirects, which would replay the token to another host.

Its offline test suite is `scripts/test_sync_docs_to_trilium.py`, run with `uv run -q --script scripts/test_sync_docs_to_trilium.py -v`, as `lint-python.yml` also does. It stubs the network but runs the real `list-lint-files.sh` parser.

## `quickshell-qmllint`

`.claude/skills/quickshell/scripts/quickshell-qmllint` is the Quickshell skill's QML lint wrapper, documented in [the skill's linting.md](../.claude/skills/quickshell/references/linting.md). This repo's own tooling only lints it, as a POSIX sh script.
