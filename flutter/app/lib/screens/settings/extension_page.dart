import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import '../../l10n/l10n.dart';
import '../../platform/os.dart';
import '../../services/extension_receiver.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';

/// 浏览器扩展: binds the TwimShelf extension of a Chromium browser to this device (a code shown
/// here, typed or pasted there), and lists the browsers bound so far.
class ExtensionPage extends StatefulWidget {
  const ExtensionPage({super.key});

  @override
  State<ExtensionPage> createState() => _ExtensionPageState();
}

class _ExtensionPageState extends State<ExtensionPage> {
  List<Map<String, dynamic>> _clients = [];
  Map<String, dynamic>? _pairing;
  String? _error;
  Timer? _poll;
  /// The browsers before the code was shown: the new one is announced when it binds.
  Set<String> _before = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_pairing != null) Core.extensionPairCancel();
    super.dispose();
  }

  void _load() {
    try {
      final s = Core.extensionClients();
      final clients = [for (final c in (s['clients'] as List)) c as Map<String, dynamic>];
      final pairing = s['pairing'] as Map<String, dynamic>?;
      if (_pairing != null && pairing == null) {
        _poll?.cancel();
        _poll = null;
        final added = clients.where((c) => !_before.contains(c['id'])).toList();
        if (added.isNotEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L('ext.code.done', [added.first['name']]))));
        }
      }
      setState(() {
        _clients = clients;
        _pairing = pairing;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _bind() {
    try {
      // the web build: the browser reaches the server at the address this page came from (the
      // server inside a container does not know it)
      final addresses = OS.isWeb ? [Uri.base.hasPort ? '${Uri.base.host}:${Uri.base.port}' : '${Uri.base.host}:${Uri.base.scheme == 'https' ? 443 : 80}'] : null;
      _before = {for (final c in _clients) c['id'] as String};
      Core.extensionPairBegin(addresses);
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _load());
      _load();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _remove(Map<String, dynamic> c) async {
    final name = c['name'] as String;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(L('ext.remove.title', [name])),
        content: Text(L('ext.remove.message')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L('common.cancel'))),
          FilledButton(key: const ValueKey('extRemoveGo'), onPressed: () => Navigator.pop(d, true), child: Text(L('ext.remove.confirm'))),
        ],
      ),
    );
    if (go != true) return;
    try {
      Core.extensionRemove(c['id'] as String);
    } catch (e) {
      setState(() => _error = '$e');
    }
    _load();
  }

  static String _date(int seconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _codeCard(BuildContext context) {
    final p = _pairing!;
    final code = p['code'] as String;
    final link = p['link'] as String;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(L('ext.code.title'), style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          SelectableText(contextMenuBuilder: appTextMenu,
            '${code.substring(0, 3)} ${code.substring(3)}',
            key: const ValueKey('extCode'),
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 4, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(L('ext.code.howto'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(contextMenuBuilder: appTextMenu, link, key: const ValueKey('extLink'), maxLines: 3, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(L('ext.code.expires'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
            FilledButton.tonalIcon(
              key: const ValueKey('extCopy'),
              icon: const Icon(Icons.copy, size: 18),
              label: Text(L('ext.code.copy')),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L('ext.code.copied'))));
              },
            ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final receiver = ExtensionReceiver.instance;
    final footer = OS.isWeb
        ? L('ext.footer.web')
        : receiver.port != null
            ? L('ext.footer.desktop', ['${receiver.port}'])
            : L('ext.unavailable', [receiver.problem ?? '']);
    return Scaffold(
      appBar: AppBar(title: Text(L('ext.title'))),
      body: ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 4), child: Text(L('ext.intro'))),
        if (_pairing != null)
          _codeCard(context)
        else
          SettingsSection(children: [
            ListTile(
              key: const ValueKey('extBind'),
              leading: const SettingsIcon(Icons.add_link),
              title: Text(L('ext.bind')),
              enabled: OS.isWeb || receiver.port != null,
              onTap: _bind,
            ),
          ]),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        SettingsSection(title: L('ext.clients'), footer: footer, children: [
          if (_clients.isEmpty) ListTile(title: Text(L('ext.state.none'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          for (final c in _clients)
            ListTile(
              leading: const SettingsIcon(Icons.extension),
              title: Text(c['name'] as String),
              subtitle: Text(L('ext.client.detail', [_date((c['added'] as num).toInt()), _date((c['seen'] as num).toInt())])),
              trailing: IconButton(tooltip: L('ext.remove.confirm'), icon: const Icon(Icons.link_off), onPressed: () => _remove(c)),
            ),
        ]),
      ]),
    );
  }
}

/// The settings row's detail: how many browsers are bound.
String extensionSummary() {
  try {
    final n = (Core.extensionClients()['clients'] as List).length;
    return n == 0 ? L('ext.state.none') : L('ext.state.count', ['$n']);
  } catch (_) {
    return L('ext.state.none');
  }
}
