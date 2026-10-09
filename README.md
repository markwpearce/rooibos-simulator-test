# rooibos + brs-engine compatibility tests

A scratch BrighterScript project for running [rooibos](https://github.com/rokucommunity/rooibos)
test suites off-device, under [brs-engine](https://github.com/lvcabral/brs-engine)'s headless Node
CLI (`brs-node`/`brs-cli`) and its Electron desktop app
([brs-desktop](https://github.com/lvcabral/brs-desktop)), to pin down exactly where rooibos and
brs-engine disagree.

Requires Node 22+ (needed by `brs-node`).

## Setup

```bash
npm install
```

## Running tests

```bash
npm run build:test-zip   # bsc --create-package --out-file ...  -> out/rooibos-tests.zip
npm run test:brs          # brs-cli out/rooibos-tests.zip
npm test                  # build:test-zip + test:brs
```

Tests run from a **zip package**, not the unzipped `build/` folder — `brs-cli`'s folder-invocation
mode with an explicit entry file doesn't load every file the way a zip does (see [Finding 3](#3-brs-clis-explicit-file-invocation-doesnt-load-rooibos-test-suites-still-reproduces)).
`brs-cli --root build` (no entry file) also works on brs-node 2.6.0+.

To run against **brs-desktop** instead of `brs-cli`, launch it with ECP + telnet + the web
installer enabled, then sideload the zip:

```bash
# in a brs-desktop checkout
npm start -- --ecp --rc --web --pwd=rokudev

# back in this repo — sideload + launch
node -e "
const { RokuDeploy } = require('roku-deploy');
new RokuDeploy().publish({ host: '127.0.0.1', password: 'rokudev', outDir: './out', outFile: 'rooibos-tests' })
"
# the app launches on sideload; read results from telnet 127.0.0.1:8085
# (connect before sideloading, or you'll miss the start of the output)
```

To run on a **real Roku device**, use the `Roku Device: Debug Rooibos Tests` VS Code launch config
(prompts for host/password).

## Project layout

- `bsconfig.base.json` — shared settings (`rootDir`, `files`, `autoImportComponentScript`,
  `stagingDir`). Not used directly.
- `bsconfig.json` — the **default** config: base + rooibos plugin/settings, staged to `build/`.
  Use this for anything test-related.
- `bsconfig.build.json` — base config, no rooibos, no `source/tests/**`, staged to `dist/`. A
  clean, test-free baseline for isolating whether a failure is rooibos-specific.
- `src/components/tasks/AsyncTask/` — a minimal component extending `Task`, used by the suites below.
- `src/source/tests/` — the test suites: `Basic` (plain assertions), `AsyncTask` (starts a Task
  and polls a field), `SGNodeTask` (an `@SGNode` suite).

## Findings

**Current state (brs-node 2.6.0, brighterscript 0.73.5, rooibos-roku 5.17.0):** all 8 tests pass
under `brs-cli`, `brs-desktop` and a real Roku device, including the `@SGNode` and Task suites.
Each finding below was reproduced on brs-node 2.2.0 and re-checked on 2.6.0. Only finding 3 still
reproduces, and it doesn't affect the zip-based workflow.

### 1. `@SGNode(...)` suites deadlocked (resolved)

**Status:** fixed in brs-node 2.6.0. `SGNodeTask.spec.bs` passes. On 2.2.0 it hung forever after
the `>>>>>> It: ...` header, with no crash, no timeout, and no `[Rooibos Result]`.

Any suite annotated `@SGNode(...)` hung, even a trivial synchronous one:

```brightscript
' src/source/tests/SGNodeTask.spec.bs
@SGNode("AsyncTask")
@suite("SGNodeTaskTests")
class SGNodeTaskTests extends tests.BaseTestSuite
  @it("passes trivially while running as a Task node")
  function _()
    m.assertTrue(true)
  end function
end class
```

**Root cause on 2.2.0:** rooibos runs every test of a node-test suite through a Promise
(`TestGroup.bs::runNextAsync()`), and the Promises library dispatches `.then()`/`.catch()`/
`.finally()` via a `Timer` node on the "next tick". On 2.2.0 that tick (`SGRoot.processTimers()`,
and `SGRoot.processTasks()` too) was only reachable from `RoSGScreen.getNewEvents()`, which only
runs when BrightScript calls `wait()`/`GetMessage()`. The only such loop
(`TestRunner.bs::runNodeTest()`) sat one level up the call stack from the suite, and the suite
never returned to it. So the promise needed a tick that could only come from the call stack it
was blocking.

### 2. `brs-cli` and `brs-desktop` disagreed on plain Task field-sync completion (resolved)

**Status:** `AsyncTask.spec.bs` now passes under `brs-cli` 2.6.0, `brs-desktop` and a real device.
On 2.2.0 it failed under `brs-cli` (the Task's `result` field never showed as `"done"` before the
timeout) but passed under `brs-desktop`.

### 3. `brs-cli`'s explicit-file invocation doesn't load rooibos test suites (still reproduces)

`brs-cli --root build source/Main.brs` still crashes on 2.6.0 with
`RuntimeConfig.brs(40,4-10): Type Mismatch. Unable to cast "<uninitialized>" to "Object"`. That
form only loads the file(s) you name, plus whatever components pull in through `<script>` tags. It
doesn't treat every `.brs` under `source/` as global scope the way a real Roku does, so rooibos's
generated test-suite classes are never loaded.

Both of the other invocation forms work on 2.6.0:
- `brs-cli out/rooibos-tests.zip`, which this repo uses.
- `brs-cli --root build` with no entry file. This mode scans `source/` and runs the full app
  (upstream [#960](https://github.com/lvcabral/brs-engine/pull/960)). On 2.2.0 it opened the REPL
  instead.

### 4. Published `brs-node` was missing `read.sh`, which broke the REPL and `--debug` (resolved)

**Status:** fixed in brs-node 2.6.0. Both the REPL and `brs-cli <zip> --debug` work again on
macOS. On 2.2.0 they failed with
`/bin/sh: .../node_modules/brs-node/bin/read.sh: No such file or directory`, because
`readline-sync` shells out to a sidecar script that the package didn't ship.

### 5. SceneGraph `Font` init couldn't find `common:/fonts/system-fonts.json` (not seen in a release)

This only showed up on an unreleased brs-engine HEAD build (past `e7cfd962`): creating a `Label`
crashed with `ENOENT`. It doesn't happen on 2.6.0, where `RooibosScene` (which has a `Label`)
starts normally.
