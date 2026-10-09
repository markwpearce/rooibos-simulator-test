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
mode with an explicit entry file doesn't load every file the way a zip does (see
[Known issues](#brs-cli-with-an-explicit-entry-file-doesnt-load-rooibos-test-suites)).
`brs-cli --root build` (no entry file) also works.

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
- `src/components/tasks/AsyncTask/` — a minimal component extending `Task`, used by the `AsyncTask`
  and `SGNodeTask` suites.
- `src/source/tests/` — the test suites: `Basic` (plain assertions), `AsyncTask` (starts a Task
  and polls a field), `SGNodeTask` (an `@SGNode` suite).

## Known issues

All 8 tests pass under `brs-cli`, `brs-desktop` and a real Roku device (brs-node 2.6.0,
brighterscript 0.73.5, rooibos-roku 5.17.0).

### `brs-cli` with an explicit entry file doesn't load rooibos test suites

`brs-cli --root build source/Main.brs` crashes with
`RuntimeConfig.brs(40,4-10): Type Mismatch. Unable to cast "<uninitialized>" to "Object"`. That
form only loads the file(s) you name, plus whatever components pull in through `<script>` tags. It
doesn't treat every `.brs` under `source/` as global scope the way a real Roku does, so rooibos's
generated test-suite classes are never loaded.

Both of the other invocation forms work: `brs-cli out/rooibos-tests.zip` (used by this repo) and
`brs-cli --root build` with no entry file.
