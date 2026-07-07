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
npm run build          # bsc                                  -> build/  (rooibos tests included, unzipped)
npm run build:test-zip  # bsc --create-package --out-file ...  -> out/rooibos-tests.zip
npm run test:brs        # brs-cli out/rooibos-tests.zip
npm test                # build:test-zip + test:brs

npm run build:release  # bsc --project bsconfig.build.json     -> dist/  (no rooibos, no tests)
npm run package         # same, plus --create-package          -> out/rooibos-simulator-test-release.zip
```

We run tests via a **zip package**, not the unzipped `build/` folder — see finding #1 below for
why (short version: `brs-cli`'s explicit-entry-file invocation, which is what running a plain
folder forces you into, doesn't load every file under `source/`; a zip is a self-contained
package brs-engine loads in full, so this sidesteps the problem entirely rather than working
around it). `npm run build` (unzipped, staged to `build/`) still exists for the on-device debug
config below, which needs a real staging folder to deploy from, not a zip.

## VSCode

- `.vscode/launch.json`:
  - **Roku Device: Debug Rooibos Tests** — runs the test build on a real Roku via the `rokucommunity.brightscript`
    extension (prompts for host/password interactively).
  - **brs-engine Simulator: Run** / **...: Debug (Micro Debugger)** — builds `out/rooibos-tests.zip`
    and runs it via `brs-cli` in the integrated terminal (the debug variant passes `--debug` for
    brs-engine's own Micro Debugger; real stdin/TTY is required, which is why these are
    `node`-type launches with `console: "integratedTerminal"`, not the `brightscript` debugger
    type).
- `.vscode/tasks.json`: `build` (unzipped test config), `build-test-zip` (zipped test config), and
  `package` (release config + zip) tasks, wired as `preLaunchTask`s.

## Known brs-engine gaps

### 1. `brs-cli`'s explicit-file invocation mode never loads rooibos's own test suite files

**Status: resolved** (run from a `.zip` package instead of a bare folder) — no longer blocks testing.

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

**Current solution** (`npm run test:brs`, i.e. `brs-cli out/rooibos-tests.zip`): rather than
working around the folder-invocation gap by enumerating files, sidestep it entirely by running a
`.zip` package instead. `brs-cli <file>.zip` (`src/cli/index.ts`'s "Run App Package file" branch,
`loadAppZip`) treats the zip as a complete, self-contained app and loads everything inside it —
there's no `--root`/explicit-entry-file distinction for zips, so rooibos's test suite classes are
included the same way `RuntimeConfig.brs` always was. We already had `bsc --create-package` wired
up for the release build (finding was: don't reuse the *release* config's zip, since it excludes
rooibos and tests — see the `bsconfig` layout section above); `npm run build:test-zip` produces
the equivalent zip from the **testing** config instead, via `bsc --create-package --out-file
./out/rooibos-tests.zip`. With this, all 6 assertions in `Basic.spec.bs` pass
(`[Rooibos Result]: PASS`), and there's no workaround script to eventually retire — this is just
the normal way to run a packaged BrightScript app, unrelated to whether/when `brs-node` publishes
the `--root`-alone fix.

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

### 4. `@SGNode(...)`-annotated Rooibos suites hang forever because Promise `.then()` dispatch needs a tick that never comes

**Status: reproduced under both `brs-cli` and `brs-desktop`; root cause confirmed by direct source
reading (both brs-engine and rooibos-roku), not yet fixed.**

**tl;dr:** every `.then()`/`.catch()`/`.finally()` in the BrightScript Promises library
(`roku_modules/rooibos_promises/promises.brs`) schedules its callback via a `Timer` node
(`rooibos_promises_internal_delay()` → `createObject("roSGNode", "Timer")`). Timer processing
(`SGRoot.processTimers()`) only runs from `RoSGScreen.getNewEvents()`, which itself only runs when
BrightScript code calls `wait()` on a message port. Rooibos's `@SGNode`-annotated ("node test")
suites run their *entire* body — setup, the test method, and any `promises.chain(...).then(...)` —
synchronously inside a single observer callback, itself invoked from one iteration of
`TestRunner.bs::runNodeTest()`'s own `wait(0, port)` loop, and **that call never returns** to let
the *next* iteration of that loop process the pending timer. The promise needs a tick to resolve;
the only place that tick can run is the exact call stack blocked waiting on the promise. Circular,
unbreakable deadlock — independent of whether real cross-thread Task work is involved at all.

This is a minimized repro of a livelock originally found in a much larger production app (Bell
Media's Crave Roku channel), where every `@async` test suite backed by a `@SGNode(...)`-annotated
node hung indefinitely. The production suite (`CraveApiTests`, `@SGNode("CraveApi")`) hits this via
a real network Task and `promises.chain(promise).then(sub(app) ... m.testSuite.done() ...)` — the
Task genuinely completes its HTTP call on its own thread, but nothing can ever service the Timer
that would deliver that result back into the suite's blocked call stack. Reproduced here with a
two-file, dependency-free minimal case that needs no real Task work at all, since the deadlock is
in the Promise/Timer plumbing every node-test test goes through regardless
(`rooibos.Test.bs::run()` auto-resolves a deferred promise even for plain synchronous, non-`@async`
tests — see below):

- `src/components/tasks/AsyncTask/AsyncTask.xml` + `.bs` — trivial `Task`-extending component,
  `functionName="doWork"`, `doWork()` just sets `m.top.result = "done"` (unused by this specific
  repro path, but keeps the component a genuine Task type as `@SGNode(...)` requires).
- `src/source/tests/SGNodeTask.spec.bs` — `@SGNode("AsyncTask")`-annotated suite with a single
  trivially-`true` assertion:
  ```brightscript
  @SGNode("AsyncTask")
  @suite("SGNodeTaskTests")
  class SGNodeTaskTests extends tests.BaseTestSuite
    @it("passes trivially while running as a Task node")
    function _()
      m.assertTrue(true)
    end function
  end class
  ```

**Symptom:** the suite's `It:` *header* line prints (`>>>>>> It: ...`), but the matching `<<<< END
It:` never does — no pass/fail, no `[Rooibos Result]`, no crash, just silence. Confirmed hung (not
just slow) under both `brs-cli` and `brs-desktop` (brs-desktop's own watchdog eventually kills and
relaunches the whole app after ~78s, which just repeats the hang from scratch). A completely
non-`@SGNode`, plain-suite version using the idiomatic `observeFieldScoped` + `m.done()` async
pattern (`AsyncTask.spec.bs`) does **not** reproduce this — it's specifically the
suite-runs-as-a-node-test execution model that triggers it.

**Confirmed root cause, traced end to end through both codebases:**

1. `TestGroup.bs::runNextAsync()` — for *any* node-test suite (`m.testSuite.isNodeTest = true`),
   every individual test, `@async` or not, goes through
   `rooibos.promises.chain(test.deferred, ...).then(...).catch(...).finally(...)` (line ~162).
2. `rooibos.Test.bs::run()` (lines 76–80) — for a plain synchronous test, this correctly
   auto-resolves: `rooibos.promises.resolve(invalid, m.deferred)`. So far so good — the promise
   *is* resolved.
3. But resolving a promise doesn't invoke its `.then()` synchronously. Every `.then()`/`.catch()`/
   `.finally()` in `roku_modules/rooibos_promises/promises.brs` is dispatched via
   `rooibos_promises_internal_delay()` (line 661), which does
   `timer = createObject("roSGNode", "Timer")` and schedules the callback for ~0.1ms later —
   i.e. "next tick," by design.
4. That "next tick" is `SGRoot.processTimers()`, called only from
   `RoSGScreen.getNewEvents()` (`brs-engine/src/extensions/scenegraph/components/RoSGScreen.ts`),
   which itself is only invoked when BrightScript code calls `wait()`/`GetMessage()` on the
   screen's message port.
5. `TestRunner.bs::runNodeTest()` creates the node, sets `node.rooibosRunSuite = true` (an
   `observeFieldScoped` field, dispatched asynchronously — *itself* delivered on the *next*
   `wait(0, port)` iteration of `runNodeTest()`'s own loop), then enters
   `while true: event = wait(0, port): ... end while` waiting for the node's `rooibosTestResult`
   field to change.
6. The generated `rooibosRunSuite()` handler that fires from that field-observer callback runs the
   *entire* suite — `Rooibos_TestRunner(...)`, `testSuite.run()`, all the way down into step 1's
   `promises.chain(...).then(...)` registration — **synchronously, in one call**, without ever
   calling `wait()` itself.

Put together: the Timer scheduled in step 3 can only fire via a `wait()`-driven tick (step 4), but
the only `wait()` loop in the picture (`runNodeTest()`'s, step 5) is one level up the call stack
from the code that's blocking on that Timer's result (step 6) — and that call never returns to let
the loop iterate again. The promise needs a tick to resolve; the only place that tick can run is
the exact call stack the promise is blocking. This reproduces with a trivially-synchronous
assertion because it doesn't require real async Task work to trigger — merely going through
Rooibos's node-test/Promise machinery at all is sufficient. Confirmed independently on the
brs-engine side too: `SGRoot.processTasks()` (Task activation/message processing) is *also* only
reachable from this same `RoSGScreen.getNewEvents()` call, so any genuinely async Task work
(like the production repro's real network call) would be starved by the identical mechanism even
if the Promise/Timer indirection weren't involved.

**Confirmed NOT the cause:** Rooibos's `catchCrashes` config option — disabling it in the original
production-app repro made no difference, and this minimal repro doesn't set it at all. Also ruled
out along the way: `RoSGNode.getScene()`'s cross-thread rendezvous (returns correctly, and this
particular suite never leaves the render thread in the first place — confirmed via
`shouldRendezvous()`/`sgRoot.threadId` instrumentation), and a suspected `Task.ts` address-identity
mismatch for `type:"node"` cross-thread writes (real, and still worth a look for cases with
genuinely separate Task threads exchanging node references, but not what causes *this* specific
hang).

Diagnostic instrumentation was added directly to a local `brs-engine` checkout
(`~/redspace/roku/brs-engine`, `Task.ts`/`SGRoot.ts`/`RoSGNode.ts`, search for `DIAG`) to gather
this evidence; not yet reverted.
