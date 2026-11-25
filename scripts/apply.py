#!/usr/bin/env python3
"""Applies config.yaml (the root of the repository) to every app.

  python3 scripts/apply.py            everything
  python3 scripts/apply.py native     the native Apple apps only (Xcode's pre-build step)
  python3 scripts/apply.py flutter    the Flutter app only (iOS and Android)
  python3 scripts/apply.py desktop    the desktop app only (web/electron: name, id, version)
  python3 scripts/apply.py generate   only the generated files below (no links or projects)
  python3 scripts/apply.py versions [--check]   only the version, in the files in git that carry it
  python3 scripts/apply.py get flutter.share_extension    one value (for build scripts)
  python3 scripts/apply.py where cache|apps|build         a build location (absolute)

config.yaml holds the public values. config.local.yaml beside it (not in git, see
config.local.example.yaml) overrides any of them on this computer: your ids, team, signing
identity, share extensions, and build location. The two are merged when read; neither file
is written, and nothing made from them is committed.

Writes small generated files that the projects read (never edits code; none of them is in git):
  Apple/Identity.xcconfig                    native: bundle ids, version, signing, app groups
  flutter/app/ios/Flutter/Identity.xcconfig   Flutter iOS
  flutter/app/android/identity.properties     Android: applicationId, share target
  flutter/app/lib/app/identity.g.dart         Dart: the app's name
  web/electron/product.json                   the desktop app (React + Electron): name, id,
                                              version and build number
  windows/TwimShelf/product.json              the native Windows app's setup: version, "send to"
config.yaml's version into the files in git that carry one (flutter/app/pubspec.yaml,
server/Cargo.toml with Cargo.lock, extension/manifest.json, web/electron/package.json): commit them
with config.yaml.
the native Xcode project, from project.yml by XcodeGen (on a Mac, when project.yml changed)
the build location (build.dir: <dir>/cache for every cache, <dir>/apps for packages):
  the Xcode projects' Derived Data location (per-user project settings, not committed) and
      BuildLocation.xcconfig (the Rust core's cache for Xcode builds; not committed)
  links from the Flutter projects' build folders (build, .dart_tool, .gradle, Pods, .cxx, the
      Rust core libraries) into <dir>/cache
Each platform carries its own committed icons; apply.py does not generate or swap icons.
Only the Python standard library is used.
"""
import getpass, hashlib, json, os, plistlib, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / 'flutter/app'
STATE = ROOT / 'Apple/.applied.json'


def scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
        return value[1:-1]
    if value in ('true', 'false'):
        return value == 'true'
    return value


def load_yaml(path):
    """The subset config.yaml uses: nested maps by indentation, lists of scalars ("- item"),
    scalars, comments, quotes."""
    root = {}
    stack = [(-1, root, None, None)]   # (indent, container, its parent, its key in the parent)
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.split(' #')[0].rstrip() if not raw.lstrip().startswith('#') else ''
        if '"' in raw and ' #' in raw:
            # a quoted value may contain " #": cut the comment only after the closing quote
            m = re.match(r'^(\s*(?:-\s*|[^:]+:\s*)"[^"]*")', raw)
            line = m.group(1) if m else line
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        while stack[-1][0] >= indent:
            stack.pop()
        _, container, parent, key = stack[-1]
        if line.strip().startswith('- '):
            if isinstance(container, dict) and not container and parent is not None:
                container = parent[key] = []   # the key's value is a list, not a map
                stack[-1] = (stack[-1][0], container, parent, key)
            container.append(scalar(line.strip()[2:]))
            continue
        key, _, value = line.strip().partition(':')
        if value.strip() == '':
            container[key] = {}
            stack.append((indent, container[key], container, key))
            continue
        container[key] = scalar(value)
    return root


def merge(base, over):
    """config.local.yaml over config.yaml: maps merged key by key, any other value replaced."""
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def load_config():
    c = load_yaml(ROOT / 'config.yaml')
    local = ROOT / 'config.local.yaml'
    return merge(c, load_yaml(local)) if local.exists() else c


def write(path, text):
    """Writes only when the content differs (no rebuilds for nothing); True when it did."""
    p = ROOT / path
    if p.exists() and p.read_text(encoding='utf-8') == text:
        return False
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding='utf-8')
    return True


def check_id(what, value, android=False):
    pattern = r'[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+' if android else r'[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+'
    if not re.fullmatch(pattern, value):
        sys.exit(f'config.yaml: {what} "{value}" is not a valid identifier')


def file_hash(path):
    p = ROOT / path
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else ''


HEADER = '// Generated from config.yaml by scripts/apply.py: edit config.yaml, not this file.\n'


def locations(c):
    """build.dir from config.yaml (TL_BUILD_DIR overrides it, for CI), made absolute."""
    d = os.environ.get('TL_BUILD_DIR') or c.get('build', {}).get('dir') or 'build'
    b = Path(os.path.expanduser(d))
    b = b if b.is_absolute() else ROOT / b
    return {'build': b, 'cache': b / 'cache', 'apps': b / 'apps'}


def is_link(p):
    """A symbolic link, or on Windows a junction."""
    try:
        return p.is_symlink() or bool(getattr(os.lstat(p), 'st_reparse_tag', 0))
    except OSError:
        return False


def remove_link(p):
    if sys.platform == 'win32':
        os.rmdir(p)  # removes the link, never what it points to
    else:
        p.unlink()


def link(path, target):
    """`path` (in the source tree) becomes a link to `target` (in the cache). What a real folder
    already holds moves along; a link elsewhere (an older location) is pointed here."""
    p, t = ROOT / path, Path(target)
    t.mkdir(parents=True, exist_ok=True)
    if is_link(p):
        if Path(os.readlink(p).removeprefix('\\\\?\\')) == t:
            return
        remove_link(p)
    elif p.exists():
        for item in p.iterdir():
            dest = t / item.name
            if not dest.exists():
                shutil.move(str(item), str(dest))
        shutil.rmtree(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == 'win32':
        # a junction: it needs no special right, and CMake refuses to unpack archives through a
        # symbolic link (llama.cpp, media_kit)
        subprocess.check_call(['cmd', '/c', 'mklink', '/J', str(p), str(t)], stdout=subprocess.DEVNULL)
    else:
        os.symlink(t, p, target_is_directory=True)





def hooks():
    """git runs .githooks (scripts/check_private.py: this computer's values stay out of git)."""
    if not (ROOT / '.git').exists() or not shutil.which('git'):
        return
    r = subprocess.run(['git', 'config', 'core.hooksPath'], cwd=ROOT, capture_output=True, text=True)
    if r.stdout.strip() != '.githooks':
        subprocess.run(['git', 'config', 'core.hooksPath', '.githooks'], cwd=ROOT, check=False)


def paths(c):
    """Every build of every app writes its caches under <dir>/cache and its packages to <dir>/apps."""
    loc = locations(c)
    cache = loc['cache']
    for d in (cache, loc['apps']):
        d.mkdir(parents=True, exist_ok=True)
    location = HEADER + f'TL_CACHE_DIR = {cache}\n'
    write('Apple/BuildLocation.xcconfig', location)
    # Xcode's Derived Data (products, intermediates, Swift package checkouts, index): the
    # project's own setting for this user (File › Project Settings › Derived Data), which Xcode
    # and xcodebuild both follow. Xcode reads it when it opens the project.
    for workspace, name in (('TwimShelf.xcodeproj/project.xcworkspace', 'native'),
                            ('flutter/app/ios/Runner.xcworkspace', 'flutter-ios')):
        if not (ROOT / workspace).exists():
            continue
        f = ROOT / workspace / 'xcuserdata' / f'{getpass.getuser()}.xcuserdatad' / 'WorkspaceSettings.xcsettings'
        settings = plistlib.loads(f.read_bytes()) if f.exists() else {}
        want = {'DerivedDataLocationStyle': 'AbsolutePath', 'DerivedDataCustomLocation': str(cache / 'xcode' / name)}
        if any(settings.get(k) != v for k, v in want.items()):
            settings.update(want)
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(plistlib.dumps(settings))
    write('flutter/app/ios/Flutter/BuildLocation.xcconfig', location)
    flutter = cache / 'flutter'
    for pkg in ('app', 'tl_core', 'tl_native', 'tl_llama'):
        link(f'flutter/{pkg}/.dart_tool', flutter / pkg / 'dart_tool')
    link('flutter/app/build', flutter / 'app' / 'build')
    link('flutter/app/android/.gradle', flutter / 'app' / 'gradle-project')
    # (not Pods: CocoaPods finds the Flutter files relative to where Pods really is, so it stays
    # beside its project; it is the installed dependency project, not build output)
    link('flutter/tl_llama/android/.cxx', flutter / 'tl_llama' / 'android-cxx')
    # the Rust core's libraries for the Flutter app (scripts/flutter/build_core.sh)
    libs = cache / 'core-libs'
    link('flutter/tl_core/apple', libs / 'apple')
    link('flutter/tl_core/android/src/main/jniLibs', libs / 'android')


def need_team(section, team, wanted):
    """A share extension hands files over through an App Group, which only works signed by a team:
    with ad-hoc signing even the app's own container for the group cannot be written."""
    if wanted and not team:
        sys.exit(f'config.yaml: a share extension on Apple platforms needs {section}.development_team')


def mac_signing(team, identity=''):
    """(style, identity) of a Mac build: an identity given in config.yaml, automatic signing with
    a team, otherwise ad-hoc, which builds and runs on this Mac without any Apple account."""
    if identity:
        return 'Manual', identity
    return ('Automatic', 'Apple Development') if team else ('Manual', '-')


def native(c):
    """Apple/Identity.xcconfig: ids, version, signing, app groups, share extensions."""
    n = c['native']
    check_id('native.bundle_id', n['bundle_id'])
    share_ios, share_mac = bool(n.get('share_extension_ios')), bool(n.get('share_extension_mac'))
    team = n.get('development_team', '')
    need_team('native', team, share_ios or share_mac)
    style, identity = mac_signing(team, n.get('mac_signing_identity', ''))
    # an app group is written differently on iOS and the Mac. With no share extension the app has
    # no entitlements at all, so that any Apple account (or on the Mac, none) can sign it.
    group_ios = f"group.{n['bundle_id']}" if share_ios else ''
    group_mac = f"{team}.{n['bundle_id']}" if share_mac else ''
    write('Apple/Identity.xcconfig', HEADER + '\n'.join([
        f"TL_BUNDLE_ID = {n['bundle_id']}",
        f"MARKETING_VERSION = {c['version']}",
        f"CURRENT_PROJECT_VERSION = {c['build_number']}",
        f"TL_TEAM = {team}",
        f"TL_APP_GROUP_IOS = {group_ios}",
        f"TL_IOS_ENTITLEMENTS = {'Apple/iOS/TwimShelf.entitlements' if share_ios else ''}",
        f"TL_APP_GROUP_MAC = {group_mac}",
        f"TL_MAC_ENTITLEMENTS = {'Apple/macOS/TwimShelf.entitlements' if share_mac else ''}",
        f"TL_MAC_SIGN_IDENTITY = {identity}",
        f"TL_MAC_SIGN_STYLE = {style}",
        # the share extension is always built; when it is off it is not signed and not embedded
        f"TL_SHARE_EXCLUDE_IOS = {'' if share_ios else 'TwimShelfShare.appex'}",
        f"TL_SHARE_SIGNING_IOS = {'YES' if share_ios else 'NO'}",
        f"TL_SHARE_EXCLUDE_MAC = {'' if share_mac else 'TwimShelfShare.appex'}",
        f"TL_SHARE_SIGNING_MAC = {'YES' if share_mac else 'NO'}",
    ]) + '\n// where builds go: build.dir in config.yaml (generated by the same script)\n#include? "BuildLocation.xcconfig"\n')


def native_project(state):
    """TwimShelf.xcodeproj from project.yml (XcodeGen), when it is missing, project.yml changed or
    a file was added to or removed from Apple/ (XcodeGen lists every source file by name)."""
    if sys.platform != 'darwin':
        return
    names = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Apple').rglob('*')
                   if p.is_file() and p.name != '.DS_Store' and not p.name.endswith('.xcconfig'))
    stamp = hashlib.sha256((file_hash('project.yml') + '\n' + '\n'.join(names)).encode()).hexdigest()
    if (ROOT / 'TwimShelf.xcodeproj/project.pbxproj').exists() and state.get('project') == stamp:
        return
    if not shutil.which('xcodegen'):
        sys.exit('config: the Xcode project is made from project.yml by XcodeGen: brew install xcodegen (./build.sh --check)')
    subprocess.check_call(['xcodegen', 'generate', '--quiet'], cwd=ROOT)
    state['project'] = stamp
    print('config: TwimShelf.xcodeproj made from project.yml')


def flutter(c):
    """The Flutter app's generated files: ids, team, app groups, share extensions, version."""
    f = c['flutter']
    check_id('flutter.apple_bundle_id', f['apple_bundle_id'])
    check_id('flutter.android_package', f['android_package'], android=True)
    share = bool(f.get('share_extension'))
    share_ios = bool(f.get('share_extension_ios'))
    team = f.get('development_team', '')
    need_team('flutter', team, share_ios)

    def share_lines(on):
        # the share extension is always built; when it is off it is not signed and not embedded
        return [f"TL_SHARE_SIGNING = {'YES' if on else 'NO'}"] + ([] if on else ['EXCLUDED_SOURCE_FILE_NAMES = ShareExtension.appex'])

    write('flutter/app/ios/Flutter/Identity.xcconfig', HEADER + '\n'.join([
        f"PRODUCT_BUNDLE_IDENTIFIER = {f['apple_bundle_id']}",
        f"DEVELOPMENT_TEAM = {team}",
        f"TL_FLUTTER_BUNDLE = {f['apple_bundle_id']}",
        # no share extension, no entitlements: any Apple account, free ones too, can sign the app
        f"TL_APP_GROUP = {'group.' + f['apple_bundle_id'] if share_ios else ''}",
        f"TL_ENTITLEMENTS = {'Runner/Runner.entitlements' if share_ios else ''}",
    ] + share_lines(share_ios)) + '\n// where builds go: build.dir in config.yaml\n#include? "BuildLocation.xcconfig"\n')
    write('flutter/app/lib/app/identity.g.dart', HEADER + "const appName = 'TwimShelf';\n")
    write('flutter/app/android/identity.properties', '# ' + HEADER[3:] + '\n'.join([
        f"applicationId={f['android_package']}",
        f"shareEnabled={'true' if share else 'false'}",
    ]) + '\n')


def desktop(c):
    """The desktop app (web/electron, React + Electron): what it is called, its application id
    (menu entry, icon name, window class; on Linux also where the Flutter app it replaces kept its
    library), and the version and build number it shows (About, the packages). product.json is not
    in git; web/electron/icon.png is committed directly."""
    if not (ROOT / 'web/electron/package.json').exists():
        return
    d = c.get('desktop', {})
    check_id('desktop.app_id', d['app_id'])
    product = {'name': 'TwimShelf', 'appId': d['app_id'], 'desktopId': d['app_id'],
               'version': str(c['version']), 'buildNumber': str(c['build_number']),
               'updateRepo': os.environ.get('TL_UPDATE_REPO', '')}
    write('web/electron/product.json', json.dumps(product, indent=2, ensure_ascii=False) + '\n')


def windows(c):
    """The native Windows app (windows/TwimShelf): what its setup installs (product.json, beside the
    program as payload.json), and its build folders and the core's library in build.dir. Nothing
    where the sources have no Windows app (the Docker image copies only what it builds)."""
    if not (ROOT / 'windows/TwimShelf/TwimShelf.csproj').exists():
        return
    w = c.get('windows', {})
    product = {'id': 'TwimShelf', 'name': 'TwimShelf', 'publisher': 'TwimShelf',
               'executable': 'TwimShelf.exe', 'file': 'TwimShelf', 'version': str(c['version']),
               'sendTo': bool(w.get('share_extension', True))}
    write('windows/TwimShelf/product.json', json.dumps(product, indent=2, ensure_ascii=False) + '\n')
    cache = locations(c)['cache']
    link('windows/TwimShelf/bin', cache / 'windows' / 'bin')
    link('windows/TwimShelf/obj', cache / 'windows' / 'obj')
    link('windows/TwimShelf/lib', cache / 'core-libs' / 'windows')


# Files in git that carry the version: (file, pattern with the version as its second group, what
# the version is written as). config.yaml's `version` is the only place it is set.
VERSIONED = (
    ('flutter/app/pubspec.yaml', r'^(version: )(.*)$', '{version}+{build_number}'),
    ('server/Cargo.toml', r'^(version = ")([^"]*)(")', '{version}'),
    ('Cargo.lock', r'^(name = "tl-server"\nversion = ")([^"]*)(")', '{version}'),
    ('extension/manifest.json', r'^(  "version": ")([^"]*)(")', '{version}'),
    ('web/electron/package.json', r'^(  "version": ")([^"]*)(")', '{version}'),
)


def versions(c, check=False):
    """Writes config.yaml's version into the files above (those that are here: the Docker image
    builds with a part of the repository). With `check`, changes nothing and names what differs."""
    stale = []
    for path, pattern, form in VERSIONED:
        p = ROOT / path
        if not p.exists():
            continue
        want = form.format(version=c['version'], build_number=c['build_number'])
        text = p.read_text(encoding='utf-8')
        m = re.search(pattern, text, flags=re.M)
        if not m:
            sys.exit(f'config: no version found in {path}')
        if m.group(2) == want:
            continue
        stale.append(f'{path}: {m.group(2)}, config.yaml says {want}')
        if not check:
            with open(p, 'w', encoding='utf-8', newline='') as f:
                f.write(text[:m.start(2)] + want + text[m.end(2):])
    return stale


def main():
    c = load_config()
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which == 'where':
        print(locations(c)[sys.argv[2]])
        return
    if which == 'get':
        v = c
        for k in sys.argv[2].split('.'):
            v = v[k]
        print(str(v).lower() if isinstance(v, bool) else v)
        return
    if which == 'versions':
        stale = versions(c, check='--check' in sys.argv)
        if stale and '--check' in sys.argv:
            sys.exit('\n'.join(stale) + '\nrun: python3 scripts/apply.py versions')
        return
    versions(c)
    if which == 'generate':
        native(c)
        flutter(c)
        desktop(c)
        windows(c)
        return
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if which in ('all', 'native'):
        native(c)              # XcodeGen checks the project's xcconfig exists: written first
        native_project(state)
    paths(c)
    hooks()
    if which in ('all', 'flutter'):
        flutter(c)
    if which in ('all', 'desktop'):
        desktop(c)
    if which in ('all', 'windows'):
        windows(c)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


if __name__ == '__main__':
    main()
