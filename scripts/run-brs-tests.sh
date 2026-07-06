#!/usr/bin/env bash
# Workaround for a brs-node@2.2.0 limitation: `brs-cli --root <dir> <entryFile>`
# (explicit-file invocation) does not auto-discover the rest of `source/` as
# global scope - it only loads files reachable via a SceneGraph component's
# <script> tag graph. Rooibos's own generated test suite classes are plain
# global-scope files with no owning component, so they never get loaded and
# any reference to them resolves to Uninitialized. See README.md finding #1.
#
# The fix (auto-discovering the whole `source/` tree from `--root` alone) is
# already committed upstream (lvcabral/brs-engine@7839671e) but not yet
# published to npm. Until it is, explicitly list every .brs file under
# source/ as a positional arg - this makes brs-cli include them all in the
# global scope, working around the gap without needing an unreleased build.
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
while IFS= read -r file; do
    files+=("$file")
done < <(find build/source -name "*.brs" | sed 's|^build/||' | sort)

exec npx brs-cli --root build "${files[@]}" "$@"
