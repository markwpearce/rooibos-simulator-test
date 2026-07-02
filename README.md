# rooibos + brs-engine compatibility tests

A scratch BrighterScript project used to run [rooibos](https://github.com/rokucommunity/rooibos)
unit test suites off-device, under [brs-engine](https://github.com/lvcabral/brs-engine)'s headless
Node CLI (`brs-node` / `brs-cli`), to find out exactly where the two are incompatible.

## Setup

```bash
npm install
```

## Build + run

```bash
npm run build      # bsc -> build/
npm run test:brs   # brs-cli --root build source/Main.brs
# or both:
npm test
```

Note the exact invocation: `brs-cli --root build` **alone** drops into an interactive REPL rather
than auto-running the app (despite what brs-engine's docs imply) — you must pass the entry file
explicitly, relative to `--root`: `brs-cli --root build source/Main.brs`.

## Known brs-engine gaps

### 1. `m` not swapped to the receiver for a method call inside `TestRunner.run()`'s loop

**Suite:** `Basic.spec.bs` (blocks every suite — this crash happens before any suite gets to run)

**Repro:** `npm run build && npx brs-cli --root build source/Main.brs`

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

`TestRunner.run()` does:
```brightscript
suiteNames = m.runtimeConfig.getAllTestSuitesNames()   ' works
for each name in suiteNames
    suiteClass = m.runtimeConfig.getTestSuiteClassWithName(name)  ' crashes here
```

Both are calls to methods on the same `m.runtimeConfig` (a `RuntimeConfig` instance) object. The
first succeeds; the second crashes. Running with `brs-cli --debug` and inspecting state at the
crash (`var`) shows `m` has **19 fields**, including `reporter`, `rooibosTimer`, `suiteNames`, `i`,
`numSuites`, `testSuite` — those are `TestRunner.run()`'s own locals, not `RuntimeConfig`'s. This
means the interpreter executed `getTestSuiteClassWithName` **without swapping `m` to the
`RuntimeConfig` receiver** — it kept the caller's (`TestRunner`) `m`. `TestRunner` happens to
*also* have a field literally named `testSuites` (`m.testSuites = []`, set in its own
constructor), so `m.testSuites["BasicTests"]` resolves against the wrong object, returns
`invalid`, and coercing `invalid` to the method's declared `as object` return type throws the
observed error.

Minimal isolated repros of "call a method with no args, then a method with a typed arg, on the
same AA-based object, in a `for each` loop" (see session notes) do **not** reproduce this — so
the bug is sensitive to something in the surrounding `TestRunner.run()` control flow (most likely
the preceding `reporter.onBegin({runner: m})` call, or something about the SceneGraph
event-driven entry into `run()`), not to method-call `m`-binding in general.

**Where to look in brs-engine source** (`/Users/mpearce/redspace/roku/brs-engine`):
- `src/core/interpreter/index.ts`: `visitCall()` (~line 1242) computes `mPointer` from
  `callee.getContext()` right after evaluating the callee expression and its arguments; `call()`
  (~line 1894) does `subInterpreter.environment.setM(mPointer, false)` before invoking the callee.
- `src/core/brsTypes/Callable.ts`: `context` (~line 151) is a single **mutable field directly on
  the shared `Callable` object** (one object per named function declaration — every "instance" of
  a class sharing a method points at the exact same `Callable`), set via `setContext()` in
  `visitDottedGet()` in `index.ts` (~line 1327) immediately before the call reads it back. Anything
  that touches that same `Callable` object's `context` between the `DottedGet` eval and the `Call`
  eval (reentrancy, an interleaved SceneGraph field/tick callback, argument evaluation that
  triggers another access through the same function reference) would cause exactly this class of
  bug. Worth checking whether `execute()`'s per-statement `for (const ext of this.extensions.values()) { ext.tick?.(this) }`
  hook (called on *every* statement) can run BrightScript code that touches the same shared
  `Callable`/context in between.

**Status:** not yet root-caused to a specific line; next step is bisecting `TestRunner.run()`
(starting by removing the `reporter.onBegin(...)` loop) to find the minimal trigger.
