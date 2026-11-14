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
# config.yaml's version is in every file in git that carries one
python3 scripts/apply.py versions --check

# interface text: every key the apps use is in the catalog, and the Flutter app's copy is the
# catalog's export (a key added by hand to the copy would be lost by the next export)
python3 scripts/catalog.py check
python3 scripts/to_flutter.py --out "$out/l10n" >/dev/null
diff -r "$out/l10n" flutter/app/assets/l10n >/dev/null || { echo "flutter/app/assets/l10n differs from the catalog's export: run python3 scripts/to_flutter.py" >&2; exit 1; }
