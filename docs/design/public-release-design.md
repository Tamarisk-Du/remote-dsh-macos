# Remote DSH for macOS Public-Release Design

Date: 2026-08-29

## Objective

Create a new, local, public-ready Git repository for an unofficial native macOS
launcher for DeepSeek Harness. The public project preserves the useful behavior
of the private application—automatic SSH tunnel startup, Harness startup,
embedded AppKit/WebKit presentation, exact child-process ownership, project
selection, and safe shutdown—without publishing the private repository, its Git
history, or any machine-specific identity.

This phase prepares and verifies a local repository only. It does not create a
GitHub repository, configure a remote, push code, publish a binary, contact
third parties, or change the installed private application.

## Product Identity

- Public product name: `Remote DSH for macOS`.
- Executable name: `RemoteDSHApp`.
- Repository name: `remote-dsh-macos`.
- Default development bundle identifier: `org.example.remote-dsh-macos`.
- The README must describe the project as an unofficial community project that
  is not affiliated with or endorsed by DeepSeek.
- “DeepSeek Harness” may be used descriptively when naming the upstream runtime,
  but the public project must not present itself as an official DeepSeek app.

## Clean-History Boundary

The public repository is created in a new directory and initialized with a new
`main` branch. Files are copied selectively from the private source only after
their content is generalized. The private `.git` directory and commits are never
copied, merged, rewritten, or pushed.

The public repository must not contain:

- private development ledgers or `.superpowers` artifacts;
- live-acceptance reports, PIDs, session IDs, hashes, backup paths, or screenshots;
- the private acceptance workspace or its history;
- private launcher diffs or copies;
- a Git remote;
- generated `.app` bundles, build directories, credentials, SSH configuration,
  Keychain data, logs, or chat/session data.

## Privacy Requirements

No tracked file or Git commit may contain:

- a real local username, home directory, email address, GitHub account, host name,
  device name, server alias, or private network address;
- the private SSH alias or launcher name;
- any absolute path beginning with `/Users/` or `/home/`;
- a real API key, bearer token, password, private key, cookie, credential-store
  value, or authorization header;
- private provider/model names or private search-service configuration;
- private process IDs, session/workspace identifiers, filesystem hashes, backup
  filenames, or internal review evidence.

Tests must use temporary directories instead of fixed home paths. Neutral
identifiers such as `model-host` and `org.example.remote-dsh-macos` are allowed.

A public-tree scanner must inspect all tracked regular files and fail closed on
symlinks, unreadable entries, unsupported file types, personal denylist matches,
or high-confidence secret patterns. A separate history check must scan every
commit in the new repository before delivery.

## Public Configuration Contract

Finder-launched apps do not inherit a predictable shell environment, so the app
uses a property-list configuration file at:

`~/Library/Application Support/RemoteDSH/config.plist`

The repository ships only `Resources/config.example.plist`. It contains neutral
example values and no credential fields.

Required keys:

- `sshAlias: String` — an existing user-managed SSH alias, for example
  `model-host`.
- `sshLocalPort: Int` — the loopback port created by that alias, default example
  `18080`.
- `harnessPort: Int` — the local Harness Web Host port, default example `3080`.
- `harnessLauncherPath: String` — an absolute path or `~/` path to a
  user-managed executable that starts the configured Harness profile.

Optional key:

- `displayModelName: String` — a non-sensitive label used only in UI text.

Validation rules:

- `sshAlias` must contain only ASCII letters, digits, dot, underscore, and hyphen,
  must not start with a hyphen, and must be 1–128 characters.
- Both ports must be in `1...65535` and must differ.
- `harnessLauncherPath` expands only a leading `~/`, must resolve to an absolute
  regular executable file, and must not be the user’s home directory.
- Unknown keys are ignored for forward compatibility.
- Missing or invalid configuration produces a native error view explaining the
  exact configuration file and invalid field. No process is started.
- The configuration never stores model-provider credentials. Credentials remain
  the responsibility of the user-managed Harness profile.

## Runtime Behavior

The app preserves the private version’s safety model:

1. Probe `127.0.0.1:sshLocalPort`.
2. If absent, run `/usr/bin/ssh -N -o BatchMode=yes -o
   ExitOnForwardFailure=yes`, followed by the validated `sshAlias` value, and
   retain its exact process handle.
3. Probe and describe Harness at `http://127.0.0.1:harnessPort`.
4. If absent, run `harnessLauncherPath` with an allowlisted environment and
   `DEEPSEEK_HARNESS_NO_OPEN=1`, retaining its exact process handle.
5. Embed only the configured numeric IPv4 loopback origin in `WKWebView`.
6. Route genuine external HTTP/HTTPS links to the default browser and reject
   ambiguous loopback spellings, user info, unexpected ports, and redirects.
7. Register projects only through a native directory picker and reject the whole
   home directory, ordinary files, and missing paths.
8. On quit, terminate only exact child processes started by the app, Harness
   before SSH. Never use process-name sweeps or modify SSH configuration.
9. If valid services already exist, attach without assuming ownership and leave
   them running on quit.

Search providers, model-provider onboarding, SSH configuration generation,
credential management, auto-update, release download, telemetry, and browser
automation are outside this public v0.1 scope.

## Source Layout

The public repository contains:

- `Package.swift` — Swift package products and targets with no private paths.
- `Sources/RemoteDSHCore/` — configuration, validation, RPC, process ownership,
  port probing, navigation policy, and diagnostic sanitization.
- `Sources/RemoteDSHApp/` — AppKit lifecycle, window, menus, picker, and WebKit.
- `Tests/RemoteDSHCoreTests/` — copied and generalized behavioral coverage plus
  configuration tests.
- `Resources/Info.plist` — neutral public product metadata.
- `Resources/config.example.plist` — credential-free configuration example.
- `Scripts/build-app.sh` — destination-parameterized local build/install script.
- `Scripts/verify-bundle.sh` — verifies an explicitly supplied bundle path.
- `Scripts/verify-public-tree.sh` — fail-closed privacy and secret scanner.
- `README.md` — English-first overview with concise Chinese usage section.
- `LICENSE` — MIT license for the public wrapper code.
- `THIRD_PARTY_NOTICES.md` — identifies the upstream DeepSeek Harness MIT
  license and states that the v0.1 source repository does not embed its runtime.
- `SECURITY.md` — private vulnerability reporting guidance without a personal
  email address; GitHub Security Advisories are the preferred channel after a
  repository exists.
- `.gitignore` — build products, app bundles, local configuration, logs, session
  data, and macOS metadata.

Internal review packages, private rollback procedures, and the private fixture
are omitted.

## Build and Release Boundary

`Scripts/build-app.sh` requires an explicit destination ending in `.app`, builds
an arm64 release binary, assembles a candidate bundle, verifies it, and installs
only that exact destination. It may use the current user’s home at runtime but
must not contain a literal username or fixed private directory.

The public v0.1 deliverable is source-only. The initial repository-preparation
phase did not create any external release. After external publication was
separately approved, `v0.1.0` may be published as a Git tag and GitHub Release
containing release notes and GitHub-generated source archives only. An
ad-hoc-signed local bundle may be built for personal verification, but no App
bundle, DMG, Homebrew cask, updater, Developer ID claim, or notarization claim
is included in the public release.

## Documentation Requirements

The README must include:

- the unofficial-project disclaimer;
- the unique remote-model/SSH-tunnel use case;
- prerequisites: macOS 14+, Apple Silicon, Swift 6 toolchain, an existing SSH
  alias that creates the model tunnel, and a user-managed Harness launcher;
- exact configuration-file installation steps using `$HOME`, never a literal
  home directory;
- build, test, and local-run commands;
- process ownership and privacy guarantees;
- the source-only/ad-hoc-signing boundary;
- upstream DeepSeek Harness attribution and links;
- a statement that search is not supplied or promised by this app;
- no claims based on private machine names, private model names, or private live
  acceptance evidence.

## Testing Strategy

Development follows red-green-refactor.

New tests must prove:

- missing configuration fails before launching processes;
- neutral valid configuration decodes correctly;
- invalid SSH aliases, identical/out-of-range ports, non-executable launchers,
  and home-directory launchers are rejected;
- a leading `~/` launcher path expands from the runtime home;
- the generated command uses the configured alias and ports without accepting
  arbitrary SSH arguments;
- navigation remains restricted to the configured numeric loopback origin;
- diagnostic output redacts generic credential assignments;
- the public-tree scanner fails on a seeded personal identifier, private key,
  tracked symlink, and unreadable/unsupported entry, then passes on the final
  repository;
- changing redirect handling back to a shared session still makes the existing
  real-loopback redirect test fail.

Existing ownership, concurrency, timeout, Stop, retry, project-path, RPC, and
presentation tests are retained with neutral fixtures.

## Acceptance Gates

Before delivery, all of the following must pass on the new repository:

1. `git status --short` shows no uncommitted tracked changes.
2. `git remote -v` is empty.
3. The new repository has only a clean `main` history created for the public
   project.
4. The full Swift test runner reports zero failures and a real test count.
5. Debug and release builds succeed.
6. The generalized bundle builds in a temporary directory and passes bundle,
   signature, architecture, identifier, and secret checks.
7. `Scripts/verify-public-tree.sh` passes on the worktree.
8. A separate scan of every Git object and commit finds no personal denylist or
   high-confidence credential match.
9. `git diff --check` passes.
10. A final read-only review reports no Critical or Important finding.

## Delivery

Deliver the local path, commit ID, test/build/scan evidence, and a concise list
of deliberate omissions. Do not create a GitHub repository or push anything
until the user separately reviews the public tree and explicitly authorizes the
external publication action.
