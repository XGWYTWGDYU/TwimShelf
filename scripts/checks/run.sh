#!/bin/bash
# Swift-side regression checks for logic in native/Shared that has no unit-test target: each harness
# is compiled against the real source file, with small stand-ins for Core, the keychain and the
# model engine. Exits non-zero when a check fails.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swiftc -module-cache-path "$out/cache" -o "$out/key" scripts/checks/external_key_binding/main.swift native/Shared/AI/ExternalModels.swift native/Shared/L10n.swift
"$out/key"

swiftc -module-cache-path "$out/cache" -parse-as-library -o "$out/queue" native/Shared/L10n.swift scripts/checks/ai_queue_progress/main.swift native/Shared/AI/AutoTagger.swift
SCENARIO=unreadable "$out/queue"
SCENARIO=model "$out/queue"

python3 scripts/checks/frontend_contracts/run.py
python3 scripts/checks/icons.py
