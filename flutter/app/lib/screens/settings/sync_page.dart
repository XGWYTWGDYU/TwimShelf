import 'dart:async';


import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import '../../app/sync_model.dart';
import '../../l10n/l10n.dart';
import '../../mascot/mascot.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';
import '../../platform/os.dart';

/// 局域网同步: the account, the account's devices, pairing — the native apps' 同步 page.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.onDeleteEverything, required this.sync});
  final SyncModel sync;
  final Future<void> Function() onDeleteEverything;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

/// The icon and the plain name of a device's type (product names: not translated).
(IconData, String?) deviceType(String? kind) => switch (kind) {
      'mac' => (Icons.laptop_mac, 'macOS'),
      'iphone' => (Icons.phone_iphone, 'iPhone'),
      'ipad' => (Icons.tablet_mac, 'iPad'),
      'android-phone' => (Icons.phone_android, 'Android'),
      'android-tablet' => (Icons.tablet_android, 'Android'),
      'windows' => (Icons.desktop_windows, 'Windows'),
      'linux' => (Icons.computer, 'Linux'),
      _ => (Icons.devices_other, null),
    };

/// A device's icon; in the mascot mode the crab with a phone or a computer.
Widget deviceIcon(String? kind, {Color? color}) => MascotIcon(
      switch (kind) {
        'iphone' || 'android-phone' => 'mobile',
        'mac' || 'windows' || 'linux' => 'laptop',
        _ => null,
      },
      fallback: Icon(deviceType(kind).$1, color: color),
    );

class _SyncPageState extends State<SyncPage> {
  SyncModel get sync => widget.sync;

  Future<void> _showCode() async {
    final String code;
    try {
      code = sync.beginPairing();
    } catch (e) {
      _toast(L('sync.error', ['$e']));
      return;
    }
    if (!mounted) return;
    final shown = DateTime.now();
    await showDialog<void>(
      context: context,
      builder: (c) => ListenableBuilder(
        listenable: sync,
        builder: (c, _) {
          // until the first status after showing it, the code has its full five minutes
          final st = sync.status;
          final fresh = st?.pairing_code == code;
          final expired = st != null && st.pairing_code == null && DateTime.now().difference(shown).inSeconds > 2;
          final left = fresh ? st!.pairing_seconds_left ?? 0 : 300;
          return AlertDialog(
            title: Text(L('sync.showCode')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(L('sync.showCode.detail')),
              const SizedBox(height: 16),
              if (expired)
                Text(L('sync.code.expired'), key: const ValueKey('sync-code-expired'), textAlign: TextAlign.center)
              else ...[
                SelectableText(contextMenuBuilder: appTextMenu, code, key: const ValueKey('sync-code'), style: Theme.of(c).textTheme.displaySmall?.copyWith(letterSpacing: 6)),
                const SizedBox(height: 8),
                Text(L('sync.code.expires', [left ~/ 60, left % 60]), style: Theme.of(c).textTheme.bodySmall),
              ],
            ]),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.done')))],
          );
        },
      ),
    );
    sync.cancelPairing();
  }

  Future<void> _join(DiscoveredPeer peer) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('sync.joinOf', [peer.name])),
        content: TextField(contextMenuBuilder: appTextMenu, 
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 6,
          decoration: InputDecoration(hintText: L('sync.enterCode')),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(L('sync.join'))),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    try {
      sync.join(peer, code);
    } catch (e) {
      _toast(L('sync.error', ['$e']));
    }
  }

  Future<void> _leave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('sync.leave.title')),
        content: Text(L('sync.leave.message')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel'))),
          TextButton(
            key: const ValueKey('sync-leave-delete'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, 'delete'),
            child: Text(L('sync.leave.deleteAll')),
          ),
          FilledButton(key: const ValueKey('sync-leave-keep'), onPressed: () => Navigator.pop(c, 'keep'), child: Text(L('sync.leave.keep'))),
        ],
      ),
    );
    if (choice == 'keep') await sync.leave();
    // the same as 清除所有数据 in 设置, with its confirmation: it leaves the account too
    if (choice == 'delete' && mounted) await widget.onDeleteEverything();
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  String _peerLine(DiscoveredPeer p, PeerInfo? info) {
    final state = p.reachable ? L('sync.online') : L('sync.offline');
    if (info == null || info.last_sync == 0) return state;
    final at = DateTime.fromMillisecondsSinceEpoch(info.last_sync * 1000);
    final now = DateTime.now();
    final ml = MaterialLocalizations.of(context);
    final when = at.year == now.year && at.month == now.month && at.day == now.day
        ? ml.formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))
        : ml.formatShortDate(at);
    final err = info.last_error;
    return err != null ? '$state · ${L('sync.failed', [err])}' : '$state · ${L('sync.syncedAgo', [when])}';
  }

  /// No network that carries device discovery (not merely no devices yet): the core says why
  /// as a catalog key (the Local Network permission, no usable network).
  Widget? _networkProblem(DiscoveryStatus? d) {
    if (d == null || !d.running || (d.network_ok && d.error == null)) return null;
    // the system's permission: a button to where it is switched on (iOS, macOS)
    final settings = d.error == 'sync.err.noLocalNetwork' && (OS.isIOS || OS.isMacOS)
        ? Uri.parse(OS.isIOS ? 'app-settings:' : 'x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork')
        : null;
    return ListTile(
      key: const ValueKey('sync-no-network'),
      leading: Icon(Icons.wifi_off, color: Theme.of(context).colorScheme.error),
      title: Text(L('sync.noLocalNetwork')),
      subtitle: Text(L(d.error ?? 'sync.err.paused')),
      trailing: settings == null ? null : TextButton(onPressed: () => launchUrl(settings), child: Text(L('sync.openSettings'))),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final s = sync.status;
          final d = sync.discovery;
          final children = <Widget>[];
          if (s == null) {
            children.add(SettingsSection(children: [ListTile(title: Text(L('sync.state.reading')))]));
          } else if (!sync.joined) {
            // one group per account: the devices of one account are one choice, not strangers
            final groups = sync.joinableAccounts;
            String groupTitle((String, List<DiscoveredPeer>) g) =>
                [L('sync.accountId', [g.$1.substring(0, g.$1.length.clamp(0, 8)).toUpperCase()]), g.$2.map((p) => p.name).join(L('list.separator'))].join(' · ');
            Widget joinTile(DiscoveredPeer p) => ListTile(
                  leading: deviceIcon(p.kind),
                  title: Text(p.name),
                  subtitle: deviceType(p.kind).$2 == null ? null : Text(deviceType(p.kind).$2!),
                  trailing: Text(L('sync.joinEllipsis')),
                  onTap: () => _join(p),
                );
            children.addAll([
              SettingsSection(title: L('sync.first'), footer: L('sync.first.footer'), children: [
                ListTile(key: const ValueKey('sync-create'), leading: const Icon(Icons.add_circle_outline), title: Text(L('sync.create')), onTap: sync.createAccount),
              ]),
              SettingsSection(
                  title: groups.length == 1 ? '${L('sync.joinExisting')} · ${groupTitle(groups.first)}' : L('sync.joinExisting'),
                  footer: groups.length > 1 ? null : L('sync.joinExisting.footer'),
                  children: [
                    ?_networkProblem(d),
                    if (groups.isEmpty && _networkProblem(d) == null) ListTile(leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)), title: Text(L('sync.searching'))),
                    if (groups.length == 1) for (final p in groups.first.$2) joinTile(p),
                    if (s.join.running) ListTile(title: Text(L('sync.pairing'))),
                    if (s.join.error != null) ListTile(title: Text(L('sync.joinFailed')), subtitle: Text(s.join.error!)),
                  ]),
              if (groups.length > 1)
                for (final (i, g) in groups.indexed)
                  SettingsSection(title: groupTitle(g), footer: i == groups.length - 1 ? L('sync.joinExisting.footer') : null, children: [for (final p in g.$2) joinTile(p)]),
            ]);
          } else {
            final peers = sync.accountPeers;
            children.addAll([
              SettingsSection(title: L('sync.status'), footer: L('sync.joined.message'), children: [
                ListTile(
                  leading: Icon(s.syncing > 0 ? Icons.sync : Icons.cloud_done_outlined),
                  title: Text(s.syncing > 0 ? L('sync.syncingEllipsis') : L('sync.state.on')),
                  subtitle: Text([L('sync.thisDevice'), ?deviceType(SyncModel.deviceKind).$2, s.device_name].join(' · ')),
                ),
                ?_networkProblem(d),
                ListTile(key: const ValueKey('sync-now'), leading: const Icon(Icons.sync), title: Text(L('sync.now')), onTap: sync.syncNow),
              ]),
              SettingsSection(title: L('sync.devices'), footer: L('sync.devices.footer'), children: [
                if (peers.isEmpty) ListTile(title: Text(L('sync.noOthers'))),
                for (final p in peers)
                  ListTile(
                    leading: deviceIcon(p.kind, color: p.reachable ? null : Theme.of(context).disabledColor),
                    title: Text(p.name),
                    subtitle: Text([?deviceType(p.kind).$2, _peerLine(p, s.peers.where((x) => x.device == p.device).firstOrNull)].join(' · ')),
                  ),
              ]),
              SettingsSection(title: L('sync.addDevice'), footer: L('sync.addDevice.footer'), children: [
                ListTile(key: const ValueKey('sync-show-code'), leading: const Icon(Icons.pin_outlined), title: Text(L('sync.showCodeEllipsis')), onTap: _showCode),
              ]),
              SettingsSection(footer: L('sync.leave.footer'), children: [
                ListTile(
                  key: const ValueKey('sync-leave'),
                  leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
                  title: Text(L('sync.leaveEllipsis'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: _leave,
                ),
              ]),
            ]);
          }
          return Scaffold(
            appBar: AppBar(title: Text(L('common.lanSync'))),
            body: SafeArea(top: false, bottom: false, child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: children)),
          );
        },
      );
}
