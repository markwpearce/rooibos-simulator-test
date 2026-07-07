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

### 4. `@SGNode(...)`-annotated Rooibos suites hang forever the moment their backing Task starts

**Status: reproduced under both `brs-cli` and `brs-desktop`; root cause narrowed to brs-engine's
Task↔render-thread rendezvous protocol, not yet fixed.**

This is a minimized repro of a livelock originally found in a much larger production app (Bell
Media's Crave Roku channel), where every `@async` test suite backed by a `@SGNode(...)`-annotated
node (Rooibos's mechanism for running a test suite *as* an instance of a given SceneGraph node
type, so the suite's own code executes inside that node's context/thread) hung indefinitely as
soon as the node's underlying Task actually started. Reproduced here with a two-file, dependency-free
minimal case:

- `src/components/tasks/AsyncTask/AsyncTask.xml` + `.bs` — trivial `Task`-extending component,
  `functionName="doWork"`, `doWork()` just sets `m.top.result = "done"` (no async work, no network
  I/O, no third-party libraries).
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

**Symptom:** the suite's `It:` line prints, the `AsyncTask` Task worker spawns
(`[task:api] Calling Task worker: 1, AsyncTask`), and then nothing else ever happens — no
`END It`, no pass/fail, no `[Rooibos Result]`. Confirmed hung (not just slow) under `brs-cli` (still
running/unresponsive after manual kill) and under `brs-desktop` (same hang; brs-desktop's own
watchdog eventually kills and relaunches the whole app after ~78s, which just repeats the hang from
scratch rather than recovering). A completely non-`@SGNode`, plain-suite version using the
idiomatic `observeFieldScoped` + `m.done()` async pattern (`AsyncTask.spec.bs`) does **not**
reproduce this — it's specifically the suite-runs-as-a-Task-node execution model that triggers it.

**Root cause (partially traced, not fixed):** every `@SGNode`/`@async` suite reports completion via
`rooibos-roku`'s `BaseTestSuite.bs::testSuiteDone()`, which does
`m.testRunner.top.rooibosTestResult = {...}` — a field write on a node reference (`m.testRunner`,
captured on the main test-runner thread) from *inside* the SGNode-task's own thread. Instrumenting
brs-engine's `Task.ts`/`SGRoot.ts` (`processThreadUpdate`, `resolveNode`, `handleThreadUpdate` in
`api/task.ts`) directly confirms: the worker thread's `processThreadUpdate()` polling loop spins
indefinitely at `currentVersion=0` (i.e. never sees a real pending update land), and separately,
the address a cross-thread `type:"node"` write targets was observed differing from the address of
the same logical node as mirrored via other thread-sync paths (`m.global.*` field mirroring vs.
whatever path produced `m.testRunner`). Whether this is (a) an address-identity mismatch across two
independent serialization events for "the same" node, or (b) a lost-update race in the single-slot
version-flag buffer used for the task→render rendezvous channel, wasn't conclusively separated —
both were observed and may compound. Diagnostic instrumentation was added directly to a local
`brs-engine` checkout (`~/redspace/roku/brs-engine`, `Task.ts`/`SGRoot.ts`, search for
`DIAG`/`sg-diag`) to gather this evidence; not yet reverted.

**Confirmed NOT the cause:** Rooibos's `catchCrashes` config option — disabling it in the original
production-app repro made no difference, and this minimal repro doesn't set it at all.

**Update — a second, distinct mechanism found while narrowing this down with the minimal repro.**
More targeted instrumentation (logging every `getScene()` call, and every `control="run"`/
`checkTaskRun()` worker-spawn event, with thread id + node address) on this minimal repro revealed
something that doesn't fit the "two Task threads racing" story above:

- `m.top.getScene()`, called from inside the generated `rooibosRunSuite()` handler, executes with
  `sgRoot.threadId=0` (i.e. on the *render* thread, not a separate Task worker) and returns
  successfully (`shouldRendezvous()` is `false`, so it just returns the already-known local scene —
  no cross-thread call even attempted). So for this `@SGNode` suite, at least the initial
  suite-setup-and-run phase is **not actually running on a separate OS thread** at the point the
  `It:` assertion executes and prints — contrary to what "runs as an instance of the Task node
  type" would suggest.
- The *actual* Task-worker spawn we see in the log (`[task:api] Calling Task worker: 1,
  AsyncTask`) turns out to be a **delayed, unrelated event**: instrumenting `setControlField()`
  (fires when `control` is set to `"run"`) shows exactly one `control="run"` event for the *entire*
  run, timestamped during the earlier, separate `AsyncTaskTests` suite (the plain
  `observeFieldScoped` one) — and the corresponding `checkTaskRun()` worker-spawn (`postMessage`)
  for that *same node address* doesn't fire until partway through the third suite
  (`SGNodeTaskTests`), two suites later. `SGNodeTaskTests`'s own node never triggers a
  `control="run"` event at all in the captured log.
- Root cause of *that* delay, confirmed by reading the source directly: `SGRoot.processTasks()`
  (which calls `checkTaskRun()`/`processThreadUpdate()` for every active Task) is only invoked from
  `RoSGScreen.getNewEvents()` — i.e. **only when the interpreter yields control via a `wait()` call
  on the screen's message port.** Any code path that runs a long synchronous stretch of
  BrightScript without hitting a `wait()` starves *all* Task processing for its entire duration,
  regardless of which thread(s) are conceptually involved. A Task created and started inside one
  test method has no guarantee its worker will even be spawned before that test method returns.

This is a real, independently-confirmed architectural gap (cooperative scheduling tied to explicit
`wait()` yield points, rather than Tasks progressing independently the way they do against real
Roku's genuine OS threads) — but it does **not** yet fully explain why `SGNodeTaskTests` itself
hangs, since its own node/thread never shows up going through the instrumented `control="run"` →
`checkTaskRun()` path at all. Two candidate explanations remain open: either `@SGNode` node-test
activation uses a different code path than the normal `control="run"` flow (not yet located), or
the hang is a blocking `Atomics.wait()` (confirmed: `SharedObject.waitVersion()` →
`Atomics.wait()`, a true OS-level block, not a cooperative yield) called from a thread that is
*also* solely responsible for eventually delivering the value it's blocking on — which would be a
genuine, unrecoverable self-deadlock distinct from the address-mismatch theory above, and would
explain why this specific case never resolves no matter how long you wait, while a busier app
(like the original production repro) might merely appear "very slow" for cases that don't hit the
same self-wait.
