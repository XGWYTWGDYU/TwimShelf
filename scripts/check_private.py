#!/usr/bin/env python3
"""Keeps this computer's own values out of git: the ids, team, signing identity and build location
in config.local.yaml (where they differ from config.yaml), and the patterns listed under its
`private:` (a name, an e-mail address, a user name). Without a config.local.yaml there is nothing
to look for.

  python3 scripts/check_private.py commit   what is staged, and the author (the pre-commit hook)
  python3 scripts/check_private.py push     the commits about to be pushed (the pre-push hook;
                                            the refs come on standard input, as git gives them)
  python3 scripts/check_private.py all      every tracked file

scripts/apply.py points git at .githooks, so the hooks run in every checkout that has been built.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import apply  # noqa: E402  (the same reader and merge the builds use)

# where personal values live in config.local.yaml
SECTIONS = ('native', 'flutter')


def patterns():
    local = ROOT / 'config.local.yaml'
    if not local.exists():
        return []
    public, mine = apply.load_yaml(ROOT / 'config.yaml'), apply.load_yaml(local)
    found = []
    for section in SECTIONS:
        for key, value in (mine.get(section) or {}).items():
            if isinstance(value, str) and len(value) >= 4 and value != (public.get(section) or {}).get(key):
                found.append((f'{section}.{key}', re.escape(value)))
    build = (mine.get('build') or {}).get('dir')
    if isinstance(build, str) and build != (public.get('build') or {}).get('dir'):
        found.append(('build.dir', re.escape(build)))
    for p in mine.get('private') or []:
        found.append(('private', str(p)))
    return [(name, re.compile(p.encode('utf-8'))) for name, p in found]


def git(*args, input=None):
    return subprocess.run(['git', *args], cwd=ROOT, input=input, capture_output=True, check=True).stdout


def scan(label, data, rules, problems):
    for name, rule in rules:
        if rule.search(data):
            problems.append(f'{label}: matches {name} ({rule.pattern.decode("utf-8", "replace")})')


def staged(rules, problems):
    for path in git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').decode().split('\0'):
        if path:
            scan(path, path.encode() + b'\n' + git('show', f':{path}'), rules, problems)
    scan('the commit author', git('var', 'GIT_AUTHOR_IDENT') + git('var', 'GIT_COMMITTER_IDENT'), rules, problems)


def pushed(rules, problems):
    zero = '0' * 40
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) != 4 or parts[1] == zero:
            continue   # a deleted ref
        local, remote = parts[1], parts[3]
        span = [local, '--not', '--remotes'] if remote == zero else [f'{remote}..{local}']
        for commit in git('rev-list', *span).decode().split():
            scan(f'commit {commit[:9]} (author, message)', git('log', '-1', '--format=%an %ae%n%cn %ce%n%B', commit), rules, problems)
            scan(f'commit {commit[:9]} (changes)', git('show', '--format=', '--binary', commit), rules, problems)


def tracked(rules, problems):
    for path in git('ls-files', '-z').decode().split('\0'):
        if path and (ROOT / path).is_file():
            scan(path, path.encode() + b'\n' + (ROOT / path).read_bytes(), rules, problems)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'
    rules = patterns()
    if not rules:
        return
    problems = []
    {'commit': staged, 'push': pushed, 'all': tracked}[mode](rules, problems)
    if problems:
        print('Personal information would go into git (config.local.yaml lists it):', file=sys.stderr)
        print('\n'.join(f'  {p}' for p in problems), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
