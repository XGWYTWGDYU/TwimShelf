#!/usr/bin/env python3
"""Applies config.yaml (the root of the repository) to every app.

  python3 scripts/apply.py            everything
  python3 scripts/apply.py native     the native Apple apps only (Xcode's pre-build step)
  python3 scripts/apply.py flutter    the Flutter app only
  python3 scripts/apply.py get flutter.share_extension    one value (for build scripts)
  python3 scripts/apply.py where cache|apps|build         a build location (absolute)

Writes small generated files that the projects read (never edits code):
  native/Identity.xcconfig                    native: names, bundle ids, version, signing, app groups
  flutter/app/ios/Flutter/Identity.xcconfig   Flutter iOS
  flutter/app/macos/Runner/Configs/Identity.xcconfig   Flutter macOS
  flutter/app/android/identity.properties     Android: applicationId, name, share target
  flutter/app/linux/identity.cmake            Linux: application id, name
  flutter/app/windows/runner/identity.h       Windows: window title, file names
  flutter/installer/product.json                    the Windows setup
the build location (build.dir: <dir>/cache for every cache, <dir>/apps for packages):
  the Xcode projects' Derived Data location (per-user project settings, not committed) and
      BuildLocation.xcconfig (the Rust core's cache for Xcode builds; not committed)
  links from the Flutter projects' build folders (build, .dart_tool, .gradle, Pods, .cxx, the
      Rust core libraries) into <dir>/cache
and, when they changed, the icons (native AppIcon set, Flutter launcher icons), the Flutter Xcode
projects and the native Xcode project (only when a share extension is switched on or off).
Only the Python standard library is used, plus Pillow when icons have to be made.
"""
import getpass, hashlib, json, os, plistlib, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / 'flutter/app'
STATE = ROOT / 'native/.applied.json'


def load_yaml(path):
    """The subset config.yaml uses: nested maps by indentation, scalars, comments, quotes."""
    root, stack = {}, [(-1, None)]
    stack[0] = (-1, root)
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.split(' #')[0].rstrip() if not raw.lstrip().startswith('#') else ''
        if '"' in raw and ' #' in raw:
            # a quoted value may contain " #": cut the comment only after the closing quote
            m = re.match(r'^(\s*[^:]+:\s*"[^"]*")', raw)
            line = m.group(1) if m else line
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        key, _, value = line.strip().partition(':')
        while stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1]
        value = value.strip()
        if value == '':
            parent[key] = {}
            stack.append((indent, parent[key]))
            continue
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        elif value in ('true', 'false'):
            value = value == 'true'
        parent[key] = value
    return root


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


def link(path, target):
    """`path` (in the source tree) becomes a link to `target` (in the cache). What a real folder
    already holds moves along; a link elsewhere (an older location) is pointed here."""
    p, t = ROOT / path, Path(target)
    t.mkdir(parents=True, exist_ok=True)
    if p.is_symlink():
        if Path(os.readlink(p)) == t:
            return
        p.unlink()
    elif p.exists():
        for item in p.iterdir():
            dest = t / item.name
            if not dest.exists():
                shutil.move(str(item), str(dest))
        shutil.rmtree(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.symlink(t, p, target_is_directory=True)
    except OSError:
        if sys.platform != 'win32':
            raise
        # Windows without Developer Mode: a junction needs no special right
        subprocess.check_call(['cmd', '/c', 'mklink', '/J', str(p), str(t)], stdout=subprocess.DEVNULL)


def unlink(path):
    """A link made by an earlier version of this script goes back to a real folder (with what
    the cache held)."""
    p = ROOT / path
    if not p.is_symlink():
        return
    target = Path(os.readlink(p))
    p.unlink()
    if target.exists():
        shutil.move(str(target), str(p))


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
            # not on Windows: CMake refuses to unpack archives (llama.cpp) through a link, so
            # there the Flutter build stays a real folder beside its project (ignored by Git)
            if sys.platform == 'win32':
                unlink(f'flutter/{pkg}/build')
            else:
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


def native(c, state):
    n = c['native']
    check_id('native.bundle_id', n['bundle_id'])
    share_ios, share_mac = bool(n.get('share_extension_ios')), bool(n.get('share_extension_mac'))
    team = n.get('development_team', '')
    need_team('native', team, share_ios or share_mac)
    style, identity = mac_signing(team, n.get('mac_signing_identity', ''))
    # an app group is written differently on iOS and the Mac. With no share extension the app has
    # no entitlements at all, so that any Apple account (or on the Mac, none) can sign it.
    group_ios = (n.get('app_group_ios') or f"group.{n['bundle_id']}") if share_ios else ''
    group_mac = (n.get('app_group_mac') or f"{team}.{n['bundle_id']}") if share_mac else ''
    write('native/Identity.xcconfig', HEADER + '\n'.join([
        f"TL_APP_NAME = {n['name']}",
        f"TL_BUNDLE_ID = {n['bundle_id']}",
        f"MARKETING_VERSION = {c['version']}",
        f"CURRENT_PROJECT_VERSION = {c['build_number']}",
        f"TL_TEAM = {team}",
        f"TL_APP_GROUP_IOS = {group_ios}",
        f"TL_IOS_ENTITLEMENTS = {'native/iOS/TwimShelf.entitlements' if share_ios else ''}",
        f"TL_APP_GROUP_MAC = {group_mac}",
        f"TL_MAC_ENTITLEMENTS = {'native/macOS/TwimShelf.entitlements' if share_mac else ''}",
        f"TL_MAC_SIGN_IDENTITY = {identity}",
        f"TL_MAC_SIGN_STYLE = {style}",
        f"TL_URL_SCHEME_BASE = {n.get('url_scheme', 'twimshelf')}",
    ]) + '\n// where builds go: build.dir in config.yaml (generated by the same script, not committed)\n#include? "BuildLocation.xcconfig"\n')
    # the share extension's name in the share sheet: a system string, the app's name written into it
    plist = ROOT / 'native/ShareExtension/InfoPlist.xcstrings'
    old = state.get('native_name', 'TwimShelf')
    if old != n['name'] and plist.exists():
        plist.write_text(plist.read_text(encoding='utf8').replace(old, n['name']), encoding='utf8')
    state['native_name'] = n['name']
    app_icon_set(c)
    # the share extension is a target the apps embed or not: project.yml says which (its two
    # embedding lines); the Xcode project is generated again only when that changes
    share = {'iOS': share_ios, 'macOS': share_mac}
    project = ROOT / 'project.yml'
    text = project.read_text(encoding='utf-8')
    def embed(m):
        target = f'TwimShelf-{m.group(2)}Share'
        deps = f'[{{ target: {target}, embed: true, codeSign: true }}]' if share[m.group(2)] else '[]'
        return f'{m.group(1)}dependencies: {deps}   # share-extension ({target})'
    new = re.sub(r'^(\s*)dependencies: \[.*\]   # share-extension(?: \(TwimShelf-)?(iOS|macOS)?.*$',
                 lambda m: embed(m) if m.group(2) else m.group(0), text, flags=re.M)
    if new != text:
        project.write_text(new, encoding='utf-8')
        if shutil.which('xcodegen'):
            subprocess.check_call(['xcodegen', 'generate', '--quiet'], cwd=ROOT)
            print('config: the share extension changed; the Xcode project was generated again (build once more if Xcode was building)')
        else:
            sys.exit('config: the share extension changed: run this again with XcodeGen installed (brew install xcodegen)')


def app_icon_set(c):
    """The native AppIcon set (committed, the source of every other icon) from `icon` of
    config.yaml; made again only when that file changed, so most builds need no image library."""
    tool = ROOT / 'scripts/flutter/make_icons.py'
    stamp = ROOT / 'native/Resources/Assets.xcassets/AppIcon.appiconset/source.sha256'
    current = file_hash(c['icon'])
    if not current:
        sys.exit(f"config.yaml: icon {c['icon']} does not exist")
    if not stamp.exists() or stamp.read_text().strip() != current:
        r = subprocess.run([sys.executable, str(tool), '--app-icon', str(ROOT / c['icon'])])
        if r.returncode != 0:
            sys.exit('config: the AppIcon set could not be made (scripts/flutter/make_icons.py)')
        stamp.write_text(current + '\n')


def embed_flutter_share(platform, on, dependency, appex, anchor=None):
    """The share extension of a Flutter Apple project is a target that Runner embeds or not."""
    path = ROOT / f'flutter/app/{platform}/Runner.xcodeproj/project.pbxproj'
    text = path.read_text(encoding='utf-8')
    dep = f'\t\t\t\t{dependency} /* PBXTargetDependency */,\n'
    file = f'\t\t\t\t{appex} /* ShareExtension.appex in Embed Foundation Extensions */,\n'
    new = text.replace(dep, '').replace(file, '')
    if on:
        new = re.sub(r'(/\* Embed Foundation Extensions \*/ = \{.*?files = \(\n)', lambda m: m.group(1) + file, new, count=1, flags=re.S)
        new = re.sub(r'(/\* Runner \*/ = \{\s+isa = PBXNativeTarget;.*?dependencies = \(\n)', lambda m: m.group(1) + dep, new, count=1, flags=re.S)
    if new != text:
        path.write_text(new, encoding='utf-8')


def flutter(c, state):
    f = c['flutter']
    check_id('flutter.apple_bundle_id', f['apple_bundle_id'])
    check_id('flutter.android_package', f['android_package'], android=True)
    check_id('flutter.desktop_id', f['desktop_id'])
    share = bool(f.get('share_extension'))
    share_ios, share_mac = bool(f.get('share_extension_ios')), bool(f.get('share_extension_mac'))
    team = f.get('development_team', '')
    need_team('flutter', team, share_ios or share_mac)
    write('flutter/app/ios/Flutter/Identity.xcconfig', HEADER + '\n'.join([
        f"TL_APP_NAME = {f['apple_name']}",
        f"PRODUCT_BUNDLE_IDENTIFIER = {f['apple_bundle_id']}",
        f"DEVELOPMENT_TEAM = {team}",
        f"TL_FLUTTER_BUNDLE = {f['apple_bundle_id']}",
        # no share extension, no entitlements: any Apple account, free ones too, can sign the app
        f"TL_APP_GROUP = {'group.' + f['apple_bundle_id'] if share_ios else ''}",
        f"TL_ENTITLEMENTS = {'Runner/Runner.entitlements' if share_ios else ''}",
    ]) + '\n// where builds go: build.dir in config.yaml (not committed)\n#include? "BuildLocation.xcconfig"\n')
    style, identity = mac_signing(team)
    write('flutter/app/macos/Runner/Configs/Identity.xcconfig', HEADER + '\n'.join([
        f"TL_APP_NAME = {f['apple_name']}",
        f"PRODUCT_BUNDLE_IDENTIFIER = {f['apple_bundle_id']}",
        f"DEVELOPMENT_TEAM = {team}",
        f"TL_FLUTTER_BUNDLE = {f['apple_bundle_id']}",
        f"TL_APP_GROUP = {team + '.' + f['apple_bundle_id'] if share_mac else ''}",
        f"TL_SIGN_STYLE = {style}",
        f"TL_SIGN_IDENTITY = {identity}",
    ]) + '\n// where builds go: build.dir in config.yaml (not committed)\n#include? "BuildLocation.xcconfig"\n')
    embed_flutter_share('ios', share_ios, 'B6AE517A5F24232B87FB1E50', 'F7CBAE714DD315375E21A053')
    embed_flutter_share('macos', share_mac, '0D7163DF1C17EE3EA47B803E', '354403B1F7EB93A77796F896')
    # the Mac runner is always sandboxed: only its App Group comes and goes
    for name in ('DebugProfile', 'Release'):
        path = ROOT / f'flutter/app/macos/Runner/{name}.entitlements'
        entitlements = plistlib.loads(path.read_bytes())
        before = dict(entitlements)
        if share_mac:
            entitlements['com.apple.security.application-groups'] = ['$(TL_APP_GROUP)']
        else:
            entitlements.pop('com.apple.security.application-groups', None)
        if entitlements != before:
            path.write_bytes(plistlib.dumps(entitlements))
    pubspec = ROOT / 'flutter/app/pubspec.yaml'
    text = pubspec.read_text(encoding='utf-8')
    new = re.sub(r'^version: .*$', f"version: {c['version']}+{c['build_number']}", text, count=1, flags=re.M)
    if new != text:
        pubspec.write_text(new, encoding='utf-8')
    write('flutter/app/lib/app/identity.g.dart', HEADER + '\n'.join([
        "import 'dart:io';",
        '',
        '/// This build\'s name, as the system shows it.',
        f"String get appName => Platform.isIOS || Platform.isMacOS ? {json.dumps(f['apple_name'], ensure_ascii=False)} : {json.dumps(f['name'], ensure_ascii=False)};",
        '',
        '/// The application id on Linux: menu entry, icon, window class.',
        f"const desktopId = {json.dumps(f['desktop_id'])};",
    ]) + '\n')
    write('flutter/app/android/identity.properties', '# ' + HEADER[3:] + '\n'.join([
        f"applicationId={f['android_package']}",
        f"appName={f['name']}",
        f"shareEnabled={'true' if share else 'false'}",
    ]) + '\n')
    write('flutter/app/linux/identity.cmake', '# ' + HEADER[3:] + '\n'.join([
        f'set(TL_APPLICATION_ID "{f["desktop_id"]}")',
        f'set(TL_APP_NAME "{f["name"]}")',
        f'set(TL_SHARE_ENABLED {"ON" if share else "OFF"})',
    ]) + '\n')
    write('flutter/app/windows/runner/identity.h', HEADER + '#pragma once\n' + '\n'.join([
        f'#define TL_APP_NAME_W L"{f["name"]}"',
        f'#define TL_APP_NAME "{f["name"]}"',
    ]) + '\n')
    product = {'id': re.sub(r'[^A-Za-z0-9.]', '', f['name']) or 'App', 'name': f['name'], 'publisher': f['name'],
               'executable': 'TwimShelf.exe', 'file': re.sub(r'\s+', '', f['name']), 'version': '0', 'sendTo': share}
    write('flutter/installer/product.json', json.dumps(product, indent=2, ensure_ascii=False) + '\n')
    # every icon of the Flutter apps comes from the AppIcon set; without them there is no build
    app_icon_set(c)
    tool = ROOT / 'scripts/flutter/make_icons.py'
    stamp = file_hash(c['icon']) + file_hash('scripts/flutter/make_icons.py')
    if state.get('flutter_icon') != stamp or subprocess.run([sys.executable, str(tool), '--check'], stdout=subprocess.DEVNULL).returncode != 0:
        r = subprocess.run([sys.executable, str(tool)])
        if r.returncode != 0:
            sys.exit('config: the Flutter icons could not be made (scripts/flutter/make_icons.py)')
        state['flutter_icon'] = stamp


def main():
    c = load_yaml(ROOT / 'config.yaml')
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
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    paths(c)
    if which in ('all', 'native'):
        native(c, state)
    if which in ('all', 'flutter'):
        flutter(c, state)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


if __name__ == '__main__':
    main()
