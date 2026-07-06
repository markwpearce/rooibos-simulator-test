# rooibos + brs-engine compatibility tests

A scratch BrighterScript project used to run [rooibos](https://github.com/rokucommunity/rooibos)
unit test suites off-device, under [brs-engine](https://github.com/lvcabral/brs-engine)'s headless
Node CLI (`brs-node` / `brs-cli`), to find out exactly where the two are incompatible.

## Setup

```bash
npm install
```

## bsconfig layout

- `bsconfig.base.json` — shared settings (`rootDir`, `files`, `autoImportComponentScript`,
  `sourceMap`, `stagingDir`). Not used directly.
- `bsconfig.json` — extends the base config, adds the `rooibos-roku` plugin and rooibos runtime
  settings. This is the **default** config (what `bsc`, VSCode, and the `rokucommunity.brightscript`
  extension pick up automatically), staged to `build/`. Use this for anything test-related.
- `bsconfig.build.json` — extends the base config, no rooibos plugin, and excludes
  `source/tests/**` from `files`. Produces a clean, test-free build/package, staged to `dist/`.
  Exists so we have a non-rooibos baseline to isolate whether a given failure is rooibos-specific
  or a general brighterscript/brs-engine issue.

## Build + run

```bash
npm run build         # bsc                                  -> build/  (rooibos tests included)
npm run test:brs      # scripts/run-brs-tests.sh (see below)
npm test              # both of the above

npm run build:release # bsc --project bsconfig.build.json     -> dist/  (no rooibos, no tests)
npm run package        # same, plus --create-package          -> out/rooibos-simulator-test-release.zip
```

`npm run test:brs` runs `scripts/run-brs-tests.sh` rather than a plain `brs-cli` invocation — see
finding #1 below for why (short version: `brs-cli --root build source/Main.brs` alone silently
never loads the test suite files, so the script explicitly lists every `.brs` file under
`source/` as a workaround). With that workaround, **all suites currently pass**
(`[Rooibos Result]: PASS`).

## VSCode

- `.vscode/launch.json`:
  - **Roku Device: Debug Rooibos Tests** — runs the test build on a real Roku via the `rokucommunity.brightscript`
    extension (prompts for host/password interactively).
  - **brs-engine Simulator: Run** / **...: Debug (Micro Debugger)** — runs the test build via
    `scripts/run-brs-tests.sh` (see finding #1) in the integrated terminal (the debug variant
    forwards `--debug` for brs-engine's own Micro Debugger; real stdin/TTY is required, which is
    why these are `node`-type launches with `console: "integratedTerminal"`, not the `brightscript`
    debugger type).
- `.vscode/tasks.json`: `build` (default/test config) and `package` (release config + zip) tasks,
  wired as `preLaunchTask`s.

## Known brs-engine gaps

### 1. `brs-cli`'s explicit-file invocation mode never loads rooibos's own test suite files

**Status: worked around** (see `scripts/run-brs-tests.sh`) — no longer blocks testing.

**Original symptom** (`npm run build && npx brs-cli --root build source/Main.brs`):
```
pkg:/source/rooibos/RuntimeConfig.brs(37,4-10): Type Mismatch. Unable to cast "<uninitialized>" to "Object".
Backtrace:
#2  Function __rooibos_TestRunner_method_run() As Dynamic
   file/line: pkg:/source/rooibos/RuntimeConfig.brs(37)
#1  Function rooibos_init(testSceneName As String) As Void
   file/line: pkg:/source/rooibos/Rooibos.brs(29)
#0  Function main() As Void
   file/line: pkg:/source/Main.brs(2)
```

This was initially misdiagnosed (in an earlier version of this doc) as an `m`-binding bug in
`TestRunner.run()`. It isn't. **Root cause:** `brs-cli --root <dir> <entryFile>` — the invocation
you're forced into because bare `--root` alone drops into a REPL on `brs-node@2.2.0` — only loads
the file(s) you explicitly list, plus whatever the SceneGraph extension separately pulls in via
component `<script>` tags. It does **not** replicate real Roku's "every `.brs` file under
`source/` (recursively) is automatically global scope" semantics. Rooibos's own framework files
(`RuntimeConfig.brs`, `TestRunner.brs`, etc.) happen to get loaded anyway because BrighterScript's
`autoImportComponentScript`/`'import` resolution wires them into `RooibosScene.xml`'s script-tag
graph. But rooibos's *generated test suite classes* (e.g. our own
`source/tests/Basic.spec.bs` → global function `tests_BasicTests`) are plain global-scope files
with **no owning component**, so they're invisible under this invocation mode. Referencing
`tests_BasicTests` (the bare, uncalled function reference `RuntimeConfig.getTestSuiteClassMap()`
stores in its map) silently resolves to `Uninitialized` rather than erroring — confirmed directly
by instrumenting the generated code: `type(tests_BasicTests)` printed `<uninitialized>` from
`Main.brs`, before `Rooibos_init` even ran. `m.testSuites["BasicTests"]` then legitimately returns
that uninitialized value, and coercing it to the method's declared `as object` return type is
what actually throws. (`getAllTestSuitesNames()`, which only calls `.keys()`, doesn't touch the
value, so it "works" and misleadingly looked like the differentiator during initial triage.)

**This is already fixed upstream, just not released yet.** Commit `7839671e` ("feat(cli): run a
folder app from `--root` alone (#771) (#960)", 2026-06-28, in `lvcabral/brs-engine`) adds
`findSourceFiles()`/`discoverFromRoot` to `src/core/index.ts`'s `createPayloadFromFiles()`, which
recursively scans `<root>/source` and runs `brs-cli --root <dir>` **with zero file args** as a
real full-app run instead of dropping to the REPL. Verified locally: building brs-node from
`/Users/mpearce/redspace/roku/brs-engine` HEAD and running `node .../brs.cli.js --root build`
(no entry file) makes the `tests_BasicTests`/`RuntimeConfig` crash disappear entirely — it
progresses to a *different*, unrelated, pre-existing WIP bug in that same checkout (`ENOENT`
loading `/common:/fonts/system-fonts.json` in the SceneGraph extension's `Font`/`initSystemFonts`,
reproducible independent of this fix). That confirms the fix works; it just isn't in a published
`brs-node` version yet, and the currently-broken dev build can't be used as a substitute today.

**Current workaround** (`scripts/run-brs-tests.sh`, wired to `npm run test:brs`): explicitly
enumerate every `.brs` file under `build/source/` and pass them all as positional args to
`brs-cli --root build` — this makes the CLI include all of them in the global scope regardless of
component ownership, working around the gap on the currently-released `brs-node@2.2.0`. With this
workaround, all 6 assertions in `Basic.spec.bs` pass (`[Rooibos Result]: PASS`). Once `brs-node`
publishes a release containing the `--root`-alone fix, this workaround (and the script) can be
deleted in favor of plain `brs-cli --root build`.

### 2. `brs-node`'s published npm package is missing `read.sh` (breaks `--debug` micro debugger input)

Running `brs-cli --debug` and interacting with the Micro Debugger (or the plain REPL) fails with:
```
/bin/sh: <project>/node_modules/brs-node/bin/read.sh: No such file or directory
The current environment doesn't support interactive reading from TTY.
```

Root cause: `brs-node` depends on `readline-sync`, which shells out to a sidecar script
(`read.sh` on POSIX, `read.ps1`/`read.cs.js` on Windows) bundled inside its own package to do
synchronous raw terminal reads — confirmed present at
`brs-engine/node_modules/readline-sync/lib/read.sh` in the source monorepo. The webpack bundle
(`packages/node/bin/brs.node.js`) inlines the *logic* that references `__dirname + '/read.sh'`,
but the actual helper script never gets copied into `packages/node/bin/` at build time, and
`packages/node/package.json`'s `"files"` array (`["bin/", "assets/", "types/src/core/", "CHANGELOG.md"]`)
doesn't reference it either — so it's absent from both the local build output and the published
npm package. This breaks any interactive terminal input in `brs-cli` (REPL, Micro Debugger
prompts) wherever `readline-sync` needs its shell-out fallback (observed on macOS/zsh).

**Fix location:** `brs-engine/packages/node/webpack.config.js` (or equivalent build script) needs
a copy step for `node_modules/readline-sync/lib/read.sh` (and the Windows equivalents) into
`packages/node/bin/`, and `packages/node/package.json`'s `files` array needs updating if those
aren't already under `bin/`.

### 3. (unreleased HEAD only) SceneGraph `Font`/`initSystemFonts` can't find `common:/fonts/system-fonts.json`

Not something we hit on the released `brs-node@2.2.0` — only surfaced while verifying finding #1's
upstream fix by building `/Users/mpearce/redspace/roku/brs-engine` HEAD locally (both `npm run
build -w brs-node` dev and `npm run release -w brs-node` production configs). Any SceneGraph node
that triggers default-font registration (e.g. `RooibosScene`'s `Label`) crashes:
```
Exception [Error]: ENOENT: No such file or directory, open '/common:/fonts/system-fonts.json'
    at initSystemFonts (brs-sg.node.js:10974:28)
    at new Font (brs-sg.node.js:10914:9)
    ...
    at new Label (brs-sg.node.js:12821:14)
```
Reproduces identically regardless of `--root`-alone vs explicit-file invocation, and regardless of
`cwd` when invoking `node .../brs.cli.js` directly — so unrelated to finding #1's fix, and looks
like an in-progress/incomplete piece of whatever's currently at HEAD (`common:/` volume not
populated with the fonts asset in this checkout state). Worth a fresh look before relying on a
build past `e7cfd962` for testing.
