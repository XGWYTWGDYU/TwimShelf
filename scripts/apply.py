#!/usr/bin/env python3
"""Applies config.yaml (the root of the repository) to every app.

  python3 scripts/apply.py            everything
  python3 scripts/apply.py native     the native Apple apps only (Xcode's pre-build step)
  python3 scripts/apply.py flutter    the Flutter app only
  python3 scripts/apply.py generate   only the generated files below (no links, icons or projects)
  python3 scripts/apply.py get flutter.share_extension    one value (for build scripts)
  python3 scripts/apply.py get icon_set                   the AppIcon set the apps use
  python3 scripts/apply.py where cache|apps|build         a build location (absolute)

config.yaml holds the public values. config.local.yaml beside it (not in git, see
config.local.example.yaml) overrides any of them on this computer: your ids, team, signing
identity, share extensions, build location and icon. The two are merged when read; neither file
is written, and nothing made from them is committed.

Writes small generated files that the projects read (never edits code; none of them is in git):
  native/Identity.xcconfig                    native: bundle ids, version, signing, app groups
  flutter/app/ios/Flutter/Identity.xcconfig   Flutter iOS
  flutter/app/macos/Runner/Configs/Identity.xcconfig   Flutter macOS
  flutter/app/android/identity.properties     Android: applicationId, share target
  flutter/app/linux/identity.cmake            Linux: application id, "open with"
  flutter/app/lib/app/identity.g.dart         Dart: the Linux application id
  flutter/installer/product.json              the Windows setup: "send to"
the native Xcode project, from project.yml by XcodeGen (on a Mac, when project.yml changed)
the build location (build.dir: <dir>/cache for every cache, <dir>/apps for packages):
  the Xcode projects' Derived Data location (per-user project settings, not committed) and
      BuildLocation.xcconfig (the Rust core's cache for Xcode builds; not committed)
  links from the Flutter projects' build folders (build, .dart_tool, .gradle, Pods, .cxx, the
      Rust core libraries) into <dir>/cache
and, when they changed, the icons: icon.png makes the native AppIcon set (committed: the web app's
and the browser extension's icons come from it); an icon of your own (`icon:` in
config.local.yaml) makes AppIconLocal beside it, which the apps then use. Every Flutter icon comes
from the set the apps use.
Only the Python standard library is used, plus Pillow when icons have to be made.
"""
import getpass, hashlib, json, os, plistlib, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / 'flutter/app'
STATE = ROOT / 'native/.applied.json'
ICON = 'icon.png'   # the repository's icon: the source of the committed AppIcon set
ICONS = 'native/Resources/Assets.xcassets'


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


def icon_source(c):
    """The icon the apps get: config.local.yaml's `icon:`, else the repository's icon.png."""
    p = Path(os.path.expanduser(str(c.get('icon') or ICON)))
    return (p if p.is_absolute() else ROOT / p).resolve()


def icon_set(c):
    """The AppIcon set the apps use (relative to the root): the committed one for icon.png."""
    return f"{ICONS}/{'AppIcon' if icon_source(c) == (ROOT / ICON).resolve() else 'AppIconLocal'}.appiconset"


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


def unlink(path):
    """A link made by an earlier version of this script goes back to a real folder (with what
    the cache held)."""
    p = ROOT / path
    if not is_link(p):
        return
    target = Path(os.readlink(p).removeprefix('\\\\?\\'))
    remove_link(p)
    if target.exists():
        shutil.move(str(target), str(p))


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
    def xc(name, extra=''):
        return HEADER + '\n'.join([
            f'TL_CACHE_DIR = {cache}',
        ]) + '\n' + extra
    write('native/BuildLocation.xcconfig', xc('native'))
    # Xcode's Derived Data (products, intermediates, Swift package checkouts, index): the
    # project's own setting for this user (File › Project Settings › Derived Data), which Xcode
    # and xcodebuild both follow. Xcode reads it when it opens the project.
    for workspace, name in (('TwimShelf.xcodeproj/project.xcworkspace', 'native'),
                            ('flutter/app/ios/Runner.xcworkspace', 'flutter-ios'),
                            ('flutter/app/macos/Runner.xcworkspace', 'flutter-macos')):
        if not (ROOT / workspace).exists():
            continue
        f = ROOT / workspace / 'xcuserdata' / f'{getpass.getuser()}.xcuserdatad' / 'WorkspaceSettings.xcsettings'
        settings = plistlib.loads(f.read_bytes()) if f.exists() else {}
        want = {'DerivedDataLocationStyle': 'AbsolutePath', 'DerivedDataCustomLocation': str(cache / 'xcode' / name)}
        if any(settings.get(k) != v for k, v in want.items()):
            settings.update(want)
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(plistlib.dumps(settings))
    write('flutter/app/ios/Flutter/BuildLocation.xcconfig', xc('flutter-ios'))
    write('flutter/app/macos/Runner/Configs/BuildLocation.xcconfig', xc('flutter-macos'))
    flutter = cache / 'flutter'
    for pkg in ('app', 'installer', 'tl_core', 'tl_native', 'tl_llama'):
        link(f'flutter/{pkg}/.dart_tool', flutter / pkg / 'dart_tool')
        if pkg in ('app', 'installer'):
            link(f'flutter/{pkg}/build', flutter / pkg / 'build')
    link('flutter/app/android/.gradle', flutter / 'app' / 'gradle-project')
    # not Pods: CocoaPods finds the Flutter files relative to where Pods really is, so it stays
    # beside its project (it is the installed dependency project, not build output)
    for plat in ('ios', 'macos'):
        unlink(f'flutter/app/{plat}/Pods')
    link('flutter/tl_llama/android/.cxx', flutter / 'tl_llama' / 'android-cxx')
    # the Rust core's libraries for the Flutter app (scripts/flutter/build_core.sh)
    libs = cache / 'core-libs'
    link('flutter/tl_core/apple', libs / 'apple')
    link('flutter/tl_core/android/src/main/jniLibs', libs / 'android')
    link('flutter/tl_core/windows/lib', libs / 'windows')
    link('flutter/tl_core/linux/lib', libs / 'linux')


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
    """native/Identity.xcconfig: ids, version, signing, app groups, icon, share extensions."""
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
    write('native/Identity.xcconfig', HEADER + '\n'.join([
        f"TL_BUNDLE_ID = {n['bundle_id']}",
        f"MARKETING_VERSION = {c['version']}",
        f"CURRENT_PROJECT_VERSION = {c['build_number']}",
        f"TL_TEAM = {team}",
        f"TL_APP_ICON = {Path(icon_set(c)).stem}",
        f"TL_APP_GROUP_IOS = {group_ios}",
        f"TL_IOS_ENTITLEMENTS = {'native/iOS/TwimShelf.entitlements' if share_ios else ''}",
        f"TL_APP_GROUP_MAC = {group_mac}",
        f"TL_MAC_ENTITLEMENTS = {'native/macOS/TwimShelf.entitlements' if share_mac else ''}",
        f"TL_MAC_SIGN_IDENTITY = {identity}",
        f"TL_MAC_SIGN_STYLE = {style}",
        # the share extension is always built; when it is off it is not signed and not embedded
        f"TL_SHARE_EXCLUDE_IOS = {'' if share_ios else 'TwimShelfShare.appex'}",
        f"TL_SHARE_SIGNING_IOS = {'YES' if share_ios else 'NO'}",
        f"TL_SHARE_EXCLUDE_MAC = {'' if share_mac else 'TwimShelfShare.appex'}",
        f"TL_SHARE_SIGNING_MAC = {'YES' if share_mac else 'NO'}",
    ]) + '\n// where builds go: build.dir in config.yaml (generated by the same script)\n#include? "BuildLocation.xcconfig"\n')


def native_project(state):
    """TwimShelf.xcodeproj from project.yml (XcodeGen), when it is missing or project.yml changed."""
    if sys.platform != 'darwin':
        return
    stamp = file_hash('project.yml')
    if (ROOT / 'TwimShelf.xcodeproj/project.pbxproj').exists() and state.get('project') == stamp:
        return
    if not shutil.which('xcodegen'):
        sys.exit('config: the Xcode project is made from project.yml by XcodeGen: brew install xcodegen (./build.sh --check)')
    subprocess.check_call(['xcodegen', 'generate', '--quiet'], cwd=ROOT)
    state['project'] = stamp
    print('config: TwimShelf.xcodeproj made from project.yml')


def app_icon_sets(c):
    """The AppIcon set made from icon.png (committed), and AppIconLocal from an icon of your own;
    each made again only when its source changed, so most builds need no image library."""
    tool = ROOT / 'scripts/flutter/make_icons.py'
    local = ROOT / ICONS / 'AppIconLocal.appiconset'
    for source, folder in (((ROOT / ICON).resolve(), ROOT / ICONS / 'AppIcon.appiconset'),
                           (icon_source(c), local)):
        if folder == local and icon_set(c) != f'{ICONS}/AppIconLocal.appiconset':
            shutil.rmtree(local, ignore_errors=True)   # back to the repository's icon
            continue
        if not source.exists():
            sys.exit(f'config: the icon {source} does not exist')
        stamp = folder / 'source.sha256'
        current = hashlib.sha256(source.read_bytes()).hexdigest()
        if not stamp.exists() or stamp.read_text().strip() != current:
            r = subprocess.run([sys.executable, str(tool), '--app-icon', str(source), '--set', str(folder)])
            if r.returncode != 0:
                sys.exit('config: the AppIcon set could not be made (scripts/flutter/make_icons.py)')
            stamp.write_text(current + '\n')


def flutter(c):
    """The Flutter app's generated files: ids, team, app groups, share extensions, version."""
    f = c['flutter']
    check_id('flutter.apple_bundle_id', f['apple_bundle_id'])
    check_id('flutter.android_package', f['android_package'], android=True)
    check_id('flutter.desktop_id', f['desktop_id'])
    share = bool(f.get('share_extension'))
    share_ios, share_mac = bool(f.get('share_extension_ios')), bool(f.get('share_extension_mac'))
    team = f.get('development_team', '')
    need_team('flutter', team, share_ios or share_mac)

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
    style, identity = mac_signing(team)
    write('flutter/app/macos/Runner/Configs/Identity.xcconfig', HEADER + '\n'.join([
        f"PRODUCT_BUNDLE_IDENTIFIER = {f['apple_bundle_id']}",
        f"DEVELOPMENT_TEAM = {team}",
        f"TL_FLUTTER_BUNDLE = {f['apple_bundle_id']}",
        f"TL_APP_GROUP = {team + '.' + f['apple_bundle_id'] if share_mac else ''}",
        # the Mac runner is always sandboxed: the -share entitlements add its App Group
        f"TL_ENTITLEMENTS_SUFFIX = {'-share' if share_mac else ''}",
        f"TL_SIGN_STYLE = {style}",
        f"TL_SIGN_IDENTITY = {identity}",
    ] + share_lines(share_mac)) + '\n// where builds go: build.dir in config.yaml\n#include? "BuildLocation.xcconfig"\n')
    pubspec = ROOT / 'flutter/app/pubspec.yaml'
    text = pubspec.read_text(encoding='utf-8')
    new = re.sub(r'^version: .*$', f"version: {c['version']}+{c['build_number']}", text, count=1, flags=re.M)
    if new != text:
        pubspec.write_text(new, encoding='utf-8')
    write('flutter/app/lib/app/identity.g.dart', HEADER + '\n'.join([
        "const appName = 'TwimShelf';",
        '',
        '/// The application id on Linux: menu entry, icon, window class.',
        f"const desktopId = {json.dumps(f['desktop_id'])};",
    ]) + '\n')
    write('flutter/app/android/identity.properties', '# ' + HEADER[3:] + '\n'.join([
        f"applicationId={f['android_package']}",
        f"shareEnabled={'true' if share else 'false'}",
    ]) + '\n')
    write('flutter/app/linux/identity.cmake', '# ' + HEADER[3:] + '\n'.join([
        f'set(TL_APPLICATION_ID "{f["desktop_id"]}")',
        f'set(TL_SHARE_ENABLED {"ON" if share else "OFF"})',
    ]) + '\n')
    product = {'id': 'TwimShelf', 'name': 'TwimShelf', 'publisher': 'TwimShelf',
               'executable': 'TwimShelf.exe', 'file': 'TwimShelf', 'version': '0', 'sendTo': share}
    write('flutter/installer/product.json', json.dumps(product, indent=2, ensure_ascii=False) + '\n')


def flutter_icons(c, state):
    """Every icon of the Flutter apps, from the set the apps use (and the committed web and
    extension icons from the committed set); made again when a source changed or one is missing."""
    tool = ROOT / 'scripts/flutter/make_icons.py'
    env = dict(os.environ, TL_ICON_SET=str(ROOT / icon_set(c)))
    stamp = file_hash(f'{icon_set(c)}/icon-1024.png') + file_hash(f'{ICONS}/AppIcon.appiconset/icon-1024.png') + file_hash('scripts/flutter/make_icons.py')
    if state.get('flutter_icon') != stamp or subprocess.run([sys.executable, str(tool), '--check'], stdout=subprocess.DEVNULL, env=env).returncode != 0:
        r = subprocess.run([sys.executable, str(tool)], env=env)
        if r.returncode != 0:
            sys.exit('config: the Flutter icons could not be made (scripts/flutter/make_icons.py)')
        state['flutter_icon'] = stamp


def main():
    c = load_config()
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which == 'where':
        print(locations(c)[sys.argv[2]])
        return
    if which == 'get':
        if sys.argv[2] == 'icon_set':
            print(ROOT / icon_set(c))
            return
        v = c
        for k in sys.argv[2].split('.'):
            v = v[k]
        print(str(v).lower() if isinstance(v, bool) else v)
        return
    if which == 'generate':
        native(c)
        flutter(c)
        return
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if which in ('all', 'native'):
        native(c)              # XcodeGen checks the project's xcconfig exists: written first
        native_project(state)
    paths(c)
    hooks()
    if which in ('all', 'native', 'flutter'):
        app_icon_sets(c)
    if which in ('all', 'flutter'):
        flutter(c)
        flutter_icons(c, state)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


if __name__ == '__main__':
    main()
