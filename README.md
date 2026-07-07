# rooibos + brs-engine compatibility tests

A scratch BrighterScript project for running [rooibos](https://github.com/rokucommunity/rooibos)
test suites off-device, under [brs-engine](https://github.com/lvcabral/brs-engine)'s headless Node
CLI (`brs-node`/`brs-cli`) and its Electron desktop app
([brs-desktop](https://github.com/lvcabral/brs-desktop)), to pin down exactly where rooibos and
brs-engine disagree.

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
mode doesn't load every file the way a zip does (see [Finding 3](#3-brs-clis-explicit-file-invocation-doesnt-load-rooibos-test-suites-resolved)).

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
# then POST http://127.0.0.1:8060/launch/dev and read results from telnet 127.0.0.1:8085
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
- `src/components/tasks/AsyncTask/` — minimal `Task`-extending component used by the repros below.
- `src/source/tests/` — the test suites themselves (see Findings).

## Findings

### The big one: `@SGNode(...)` suites deadlock — Promise `.then()` needs a tick that never comes

**Status:** root cause confirmed by reading both codebases end to end; not fixed.

Any Rooibos suite annotated `@SGNode(...)` (runs the suite *as* an instance of a given SceneGraph
node) hangs forever, permanently — no crash, no timeout, no `[Rooibos Result]`. Reproduced with a
two-file, dependency-free minimal case:

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

(`AsyncTask` is just a trivial `Task`-extending component — `@SGNode(...)` requires its target to
be a real Task type, but this repro never actually needs the Task to do anything.)

**Symptom:** the `>>>>>> It: ...` header prints; the matching `<<<< END It: ...` never does.
Confirmed under both `brs-cli` and `brs-desktop` (brs-desktop's own watchdog eventually kills and
relaunches the app after ~78s, which just repeats the hang).

**Root cause**, traced step by step through `rooibos-roku` and `brs-engine` source:

1. For *any* node-test suite, every individual test — `@async` or not — is run through a Promise:
   `TestGroup.bs::runNextAsync()` does
   `rooibos.promises.chain(test.deferred, ...).then(...).catch(...).finally(...)`.
2. For a plain synchronous (non-`@async`) test, `rooibos.Test.bs::run()` correctly auto-resolves
   that promise immediately: `rooibos.promises.resolve(invalid, m.deferred)`.
3. But resolving a promise doesn't invoke `.then()` synchronously. Every `.then()`/`.catch()`/
   `.finally()` in the Promises library (`roku_modules/rooibos_promises/promises.brs`) is
   dispatched via `rooibos_promises_internal_delay()`, which creates a `Timer` node to fire the
   callback on the "next tick."
4. That tick is `SGRoot.processTimers()`, reachable *only* from `RoSGScreen.getNewEvents()`
   (`brs-engine/src/extensions/scenegraph/components/RoSGScreen.ts`) — which itself only runs when
   BrightScript code calls `wait()`/`GetMessage()` on a message port.
5. `TestRunner.bs::runNodeTest()` creates the node and enters
   `while true: event = wait(0, port): ... end while`, waiting for the node's `rooibosTestResult`
   field to change.
6. The entire suite — including the step-1 Promise registration — runs **synchronously, inside one
   call** triggered from that same loop, and never calls `wait()` itself before returning.

The Timer from step 3 can only fire via the tick from step 4, but the only `wait()` loop able to
produce that tick (step 5) is one level up the call stack from the code blocking on the Timer's
result (step 6) — and that call never returns to let the loop iterate again. **The promise needs a
tick to resolve, and the only place that tick can run is the exact call stack the promise is
blocking.** A trivial synchronous assertion is enough to reproduce it; no real async work needed.

This is the same mechanism behind the original production hang (Bell Media's Crave app,
`CraveApiTests` suite, `@SGNode("CraveApi")`): a real network Task genuinely completes its HTTP
call on its own thread via `promises.chain(promise).then(sub(app) ... m.testSuite.done() ...)`, but
nothing can ever service the Timer that would deliver that result into the suite's blocked call
stack. (`SGRoot.processTasks()`, which drives real Task activation/messaging, is *also* only
reachable from that same `RoSGScreen.getNewEvents()` call — so genuinely async Task work is starved
by the identical mechanism, Promise indirection or not.)

Ruled out along the way, in case they look promising to whoever picks this up next: Rooibos's
`catchCrashes` option (no effect either way); `RoSGNode.getScene()`'s cross-thread rendezvous
(returns correctly — this suite never actually leaves the render thread); and a suspected
`Task.ts` address-identity mismatch for cross-thread node writes (real, but not the cause of *this*
hang — may still be worth a look for suites with genuinely separate Task threads exchanging node
references).

### Other findings

#### 1. `brs-cli` vs `brs-desktop` disagree on plain Task field-sync completion

**Status:** open, not yet investigated further.

`AsyncTask.spec.bs` — a plain (non-`@SGNode`) suite that starts a Task and polls its `result` field
with `assertAsyncField`/`wait()` — does not hang on either runtime, but they disagree on the
outcome: **PASS** under `brs-desktop`, **FAIL** under `brs-cli`. The Task worker spawns in both
cases; `brs-cli` just never observes `result` change to `"done"` within the timeout.

#### 2. `brs-cli`'s explicit-file invocation doesn't load rooibos test suites (resolved)

Running `brs-cli --root build source/Main.brs` throws a type-mismatch trying to run
`RuntimeConfig.getTestSuiteClassWithName()`, because `--root <dir> <entryFile>` only loads the
file(s) you name plus whatever a component's `<script>` tags pull in — it doesn't replicate real
Roku's "every `.brs` under `source/` is global scope" behavior, so rooibos's generated test-suite
classes (plain global functions with no owning component) are invisible.

**Already fixed upstream, not yet released:** `lvcabral/brs-engine` commit `7839671e` makes
`brs-cli --root <dir>` (no entry file) scan `source/` recursively and run a real full-app load.
Verified locally against a HEAD build.

**Workaround used here:** run from a `.zip` package instead (`npm run test:brs`) — zips are loaded
as complete apps with no root/entry-file distinction, so this sidesteps the gap entirely rather
than working around it, and isn't something to unwind later.

#### 3. `brs-node`'s published npm package is missing `read.sh` (breaks `--debug`)

`brs-cli --debug` (or the plain REPL) fails on macOS/zsh with:
```
/bin/sh: <project>/node_modules/brs-node/bin/read.sh: No such file or directory
The current environment doesn't support interactive reading from TTY.
```
`brs-node` depends on `readline-sync`, which shells out to `read.sh` for synchronous terminal
reads. The webpack bundle references it via `__dirname + '/read.sh'`, but the file itself never
gets copied into `packages/node/bin/` at build time (present in `node_modules/readline-sync/lib/`
but absent from `packages/node/package.json`'s `files` array).

**Fix location:** add a copy step for `readline-sync`'s `read.sh`/`read.ps1`/`read.cs.js` into
`packages/node/bin/` in brs-engine's Node package build.

#### 4. (unreleased HEAD only) SceneGraph `Font` init can't find `common:/fonts/system-fonts.json`

Only seen while verifying finding 2's fix on a HEAD build past `e7cfd962`. Any node that triggers
default-font registration (e.g. a `Label`) crashes with `ENOENT: .../common:/fonts/system-fonts.json`.
Reproduces regardless of invocation mode — looks like an in-progress/incomplete asset-mounting
change at that point in history, unrelated to finding 2.
