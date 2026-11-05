#!/usr/bin/env python3
"""String catalog maintenance for TwimShelf.

  catalog.py add FILE.json   merge entries into native/Resources/Localizable.xcstrings
                             (or core/messages.json with --core)
  catalog.py check           fail on hard-coded user-visible text and incomplete catalogs

Entry file format (add):  {"key": {"en": "...", "zh-Hans": "...", "zh-Hant": "...", "ja": "...",
                                    "comment": "optional"}}
A value may be {"one": "...", "other": "..."} for plural variations (the count is the argument).
Swift formats use %@ (text), %lld (whole number), %.1f (decimal), positional %1$@ when reordered.
Core (Rust) messages use {name} placeholders.

What `check` treats as hard-coded text: a string literal with Han, kana or hangul characters in
app Swift code outside `#if DEBUG` blocks and outside lines marked `// i18n-exempt: <reason>`
(data formats, such as the legacy 推文内容.txt markers), and the same in core Rust code outside
test modules. English UI literals cannot be told from identifiers mechanically; review covers them.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XC = os.path.join(ROOT, "native/Resources/Localizable.xcstrings")
CORE = os.path.join(ROOT, "core/messages.json")
LANGS = ["en", "zh-Hans", "zh-Hant", "ja"]
CJK = re.compile(r"[\u3000-\u303f\uff00-\uffef\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?([@dDiuUxXoOfFeEgGcsaA])")


def load_xc():
    if not os.path.exists(XC):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    with open(XC, encoding="utf-8") as f:
        return json.load(f)


def save_xc(d):
    with open(XC, "w", encoding="utf-8") as f:
        f.write(json.dumps(d, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : ")) + "\n")


def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}


def to_loc(v):
    if isinstance(v, dict):
        return {"variations": {"plural": {k: unit(x) for k, x in v.items()}}}
    return unit(v)


def values_of(loc):
    """Every text of one localization (each plural form)."""
    if "stringUnit" in loc:
        return [loc["stringUnit"]["value"]]
    out = []
    for forms in loc.get("variations", {}).values():
        for f in forms.values():
            out += values_of(f)
    return out


def kinds(fmt):
    """Argument kinds by position: {1: 'o', 2: 'i'} (o = object, i = integer, f = double)."""
    out, nxt = {}, 1
    for m in SPEC.finditer(fmt.replace("%%", "")):
        pos = int(m.group(1)) if m.group(1) else nxt
        if not m.group(1):
            nxt += 1
        c = m.group(2)
        out[pos] = "o" if c in "@s" else ("f" if c in "fFeEgGaA" else "i")
    return out


def add(path, core=False):
    with open(path, encoding="utf-8") as f:
        entries = json.load(f)
    if core:
        d = json.load(open(CORE, encoding="utf-8")) if os.path.exists(CORE) else {}
        for k, e in entries.items():
            d[k] = {l: e[l] for l in ["zh-Hans", "en", "zh-Hant", "ja"]}
        with open(CORE, "w", encoding="utf-8") as f:
            f.write(json.dumps(d, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"{len(entries)} core messages merged ({len(d)} total)")
        return
    d = load_xc()
    for k, e in entries.items():
        missing = [l for l in LANGS if l not in e]
        if missing:
            sys.exit(f"{k}: missing {missing}")
        s = {"extractionState": "manual", "localizations": {l: to_loc(e[l]) for l in LANGS}}
        if e.get("comment"):
            s["comment"] = e["comment"]
        d["strings"][k] = s
    save_xc(d)
    print(f"{len(entries)} entries merged ({len(d['strings'])} total)")


def swift_files():
    for base in ["native/Shared", "native/iOS", "native/macOS", "native/ShareExtension"]:
        for dp, _, fs in os.walk(os.path.join(ROOT, base)):
            for f in fs:
                if f.endswith(".swift"):
                    yield os.path.join(dp, f)


LIT = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def code_lines(path, rust=False):
    """(line number, code without comments) outside DEBUG blocks / test modules."""
    lines = open(path, encoding="utf-8").read().split("\n")
    depth_debug, stack = 0, []
    in_block = False
    test_depth = None
    brace = 0
    for i, raw in enumerate(lines, 1):
        line = raw
        if in_block:
            if "*/" in line:
                line = line.split("*/", 1)[1]
                in_block = False
            else:
                continue
        st = line.strip()
        if not rust:
            if st.startswith("#if"):
                stack.append("DEBUG" in st and "!DEBUG" not in st)
                if stack[-1]:
                    depth_debug += 1
                continue
            if st.startswith("#else") and stack:
                if stack[-1]:
                    depth_debug -= 1
                stack[-1] = False
                continue
            if st.startswith("#endif") and stack:
                if stack.pop():
                    depth_debug -= 1
                continue
            if depth_debug > 0:
                continue
        else:
            if test_depth is None and re.match(r"\s*#\[cfg\(test\)\]", line):
                test_depth = "pending"
                continue
            if test_depth == "pending" and re.search(r"\bmod\b.*\{", line):
                test_depth = brace
            b = line.count("{") - line.count("}")
            if test_depth not in (None, "pending"):
                brace += b
                if brace <= test_depth:
                    test_depth = None
                continue
            brace += b
        if "i18n-exempt" in raw:
            continue
        # strip // comments outside literals
        out, j, inq = "", 0, False
        while j < len(line):
            c = line[j]
            if c == '"' and (j == 0 or line[j - 1] != "\\"):
                inq = not inq
            if not inq and line.startswith("//", j):
                break
            if not inq and line.startswith("/*", j):
                if "*/" in line[j:]:
                    j = line.index("*/", j) + 2
                    continue
                in_block = True
                break
            out += c
            j += 1
        yield i, out


def dart_files():
    for dp, _, fs in os.walk(os.path.join(ROOT, "flutter/app/lib")):
        for name in sorted(fs):
            if name.endswith(".dart"):
                yield os.path.join(dp, name)


# Match comments and Dart literals together, so comment markers inside literals
# stay intact. Include raw, single-quoted and multiline strings.
DART_TOKEN = re.compile(
    r"//[^\n]*|/\*.*?\*/|r?(?:\"\"\".*?\"\"\"|'''.*?'''|\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')",
    re.DOTALL,
)


def dart_source(path):
    source = open(path, encoding="utf-8").read()
    lines = source.splitlines()
    literals = []

    def token(match):
        value = match.group(0)
        if value.startswith(("//", "/*")):
            return "".join("\n" if char == "\n" else " " for char in value)
        number = source.count("\n", 0, match.start()) + 1
        if not any("i18n-exempt" in line for line in lines[number - 1:number + value.count("\n")]):
            literals.append((number, value))
        return value
    code = DART_TOKEN.sub(token, source)
    code = "".join(
        "".join("\n" if char == "\n" else " " for char in line)
        if "i18n-exempt" in original else line
        for original, line in zip(source.splitlines(), code.splitlines(keepends=True))
    )
    return code, literals


def check():
    problems = []
    d = load_xc()
    strings = d["strings"]
    for k, s in strings.items():
        locs = s.get("localizations", {})
        base = None
        for l in LANGS:
            if l not in locs:
                problems.append(f"catalog: {k} has no {l}")
                continue
            for v in values_of(locs[l]):
                if not v.strip() and not k.endswith((".aliases", ".separator")):
                    problems.append(f"catalog: {k} empty in {l}")
                kk = kinds(v)
                if base is None:
                    base = kk
                elif kk != base and not (l != "en" and set(kk.items()) <= set(base.items())):
                    problems.append(f"catalog: {k} {l} arguments {kk} differ from {base}")
    used = set()
    for p in swift_files():
        rel = os.path.relpath(p, ROOT)
        for n, code in code_lines(p):
            for m in re.finditer(r'\bL\(\s*"([^"\\]+)"', code):
                used.add(m.group(1))
                if m.group(1) not in strings and not m.group(1).endswith("."):
                    problems.append(f"{rel}:{n}: key {m.group(1)!r} not in the catalog")
            for m in LIT.finditer(code):
                if CJK.search(m.group(0)):
                    problems.append(f"{rel}:{n}: hard-coded text {m.group(0)[:60]}")
    for p in dart_files():
        rel = os.path.relpath(p, ROOT)
        code, literals = dart_source(p)
        for m in re.finditer(r"\bL\(\s*([\"'])([^\"'\\]+)\1", code):
            key = m.group(2)
            used.add(key)
            if key not in strings and not key.endswith("."):
                number = code.count("\n", 0, m.start()) + 1
                problems.append(f"{rel}:{number}: key {key!r} not in the catalog")
        for number, literal in literals:
            if CJK.search(literal):
                problems.append(f"{rel}:{number}: hard-coded text {literal[:60]}")
    # keys built at run time (prefix + name) are listed with `i18n-keys:` comments
    dynamic = set()
    for p in list(swift_files()) + list(dart_files()):
        for line in open(p, encoding="utf-8"):
            for m in re.finditer(r"i18n-keys:\s*([\w.\-*, ]+)", line):
                dynamic |= {x.strip() for x in m.group(1).split(",") if x.strip()}
    unused = [k for k in strings if k not in used and not any(k.startswith(x.rstrip("*")) for x in dynamic if x.endswith("*")) and k not in dynamic]
    # core
    core = json.load(open(CORE, encoding="utf-8")) if os.path.exists(CORE) else {}
    core_used = set()
    for dp, _, fs in os.walk(os.path.join(ROOT, "core")):
        if "/target" in dp or "/tests" in dp:
            continue
        for f in fs:
            if not f.endswith(".rs") or f in ("tests.rs", "messages.rs"):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, ROOT)
            for n, code in code_lines(p, rust=True):
                for m in re.finditer(r'(?<![\w_])tr!\(\s*"([^"\\]+)"', code):
                    core_used.add(m.group(1))
                    if m.group(1) not in core:
                        problems.append(f"{rel}:{n}: core key {m.group(1)!r} not in messages.json")
                for m in LIT.finditer(code):
                    if CJK.search(m.group(0)):
                        problems.append(f"{rel}:{n}: hard-coded text {m.group(0)[:60]}")
    for k, v in core.items():
        for l in ["zh-Hans", "en", "zh-Hant", "ja"]:
            if not v.get(l, "").strip():
                problems.append(f"messages.json: {k} has no {l}")
    for p in problems:
        print(p)
    if unused:
        print(f"note: {len(unused)} catalog keys not referenced literally: {', '.join(sorted(unused)[:20])}{' …' if len(unused) > 20 else ''}")
    core_unused = [k for k in core if k not in core_used]
    if core_unused:
        print(f"note: {len(core_unused)} core keys not referenced literally: {', '.join(sorted(core_unused)[:20])}")
    print(f"{len(problems)} problems; {len(strings)} app keys, {len(core)} core keys")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["add"]:
        add(a[-1], core="--core" in a)
    elif a[:1] == ["check"]:
        check()
    else:
        print(__doc__)
        sys.exit(2)
