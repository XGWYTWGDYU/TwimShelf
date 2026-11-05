import 'dart:convert';

import 'package:test/test.dart';
import 'package:tl_core/tl_core.dart';

/// The names core/src/hub.rs serializes.
void main() {
  test('a page of results', () {
    final p = HubPage.fromJson(jsonDecode(r'''{"device": {"memory_bytes": 16000000000, "free_bytes": null, "mobile": false},
      "items": [{"repo": "a/b", "format": "gguf", "architecture": "qwen2vl", "params": 3000000000, "downloads": 5, "likes": 1, "license": "mit",
                 "sha": "x", "claims_uncensored": true, "estimated_bytes": 2250000000, "tier": "recommended"}],
      "hidden": [{"repo": "a/c", "reason": "why"}], "next": null}''') as Map<String, dynamic>);
    expect(p.device.memory_bytes, 16000000000);
    expect(p.device.free_bytes, isNull);
    final r = p.items.single;
    expect((r.repo, r.architecture, r.params, r.claims_uncensored, r.estimated_bytes, r.tier), ('a/b', 'qwen2vl', 3000000000, true, 2250000000, 'recommended'));
    expect((p.hidden.single.repo, p.hidden.single.reason), ('a/c', 'why'));
  });

  test("a repo's detail", () {
    final d = HubDetail.fromJson(jsonDecode(r'''{"repo": {"repo": "a/b", "format": "mlx", "architecture": null, "params": null, "downloads": 0, "likes": 0, "license": null,
        "sha": null, "claims_uncensored": false, "estimated_bytes": null, "tier": "unknown"}, "revision": "abc",
      "variants": [{"label": "4bit", "weights": null, "projector": null, "bytes": 3, "tier": "usable", "suggested": true, "enough_space": false, "folder": "a--b"}],
      "skipped": [{"name": "x.gguf", "reason": "why"}], "problem": null}''') as Map<String, dynamic>);
    final v = d.variants.single;
    expect((d.revision, v.label, v.weights, v.bytes, v.tier, v.suggested, v.enough_space, v.folder), ('abc', '4bit', null, 3, 'usable', true, false, 'a--b'));
    expect(d.skipped.single.name, 'x.gguf');
    expect(d.problem, isNull);
  });
}
