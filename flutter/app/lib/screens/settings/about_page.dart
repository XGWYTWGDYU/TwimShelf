import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tl_core/tl_core.dart';

import '../../app/identity.g.dart';
import '../../app/prefs.dart';
import '../../l10n/l10n.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';

/// 关于: the app's icon, name and version. Ten taps on the icon bring out what is only for
/// looking into a problem (checking the media, the log, exporting the diagnostics) until ten more
/// put it away.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.onExportDiagnostics, required this.logFile});
  final VoidCallback onExportDiagnostics;
  final String logFile;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  int _taps = 0;
  final _info = PackageInfo.fromPlatform();
  IntegritySummary? _integrity;
  Timer? _verifyPoll;

  @override
  void initState() {
    super.initState();
    if (Prefs.instance.aboutExtras) _loadIntegrity();
  }

  @override
  void dispose() {
    _verifyPoll?.cancel();
    super.dispose();
  }

  void _iconTapped() {
    _taps++;
    if (_taps < 10) return;
    _taps = 0;
    final on = !Prefs.instance.aboutExtras;
    Prefs.instance.aboutExtras = on;
    if (on) {
      _loadIntegrity();
    } else {
      _verifyPoll?.cancel();
      _verifyPoll = null;
    }
    setState(() {});
  }

  Future<void> _loadIntegrity() async {
    final s = await coreRunAsync(Core.integritySummary);
    if (!mounted) return;
    setState(() => _integrity = s);
    final running = s.last?.running ?? false;
    if (running && _verifyPoll == null) {
      _verifyPoll = Timer.periodic(const Duration(seconds: 1), (_) => _loadIntegrity());
    } else if (!running) {
      _verifyPoll?.cancel();
      _verifyPoll = null;
    }
  }

  String _integrityText(IntegritySummary s) {
    final last = s.last;
    if (last == null) return L('verify.never', [s.unchecked]) + (s.bad > 0 ? L('verify.knownBad', [s.bad]) : '');
    if (last.running) return L('verify.checking', [last.checked, last.total]);
    // stopped half-way or failed: that is what it says, whatever older checks found
    if (last.completed_at == 0 || last.outcome == 'interrupted' || last.outcome == 'failed' || last.outcome == 'cancelled') {
      return L('verify.stopped', [last.outcome == 'failed' ? L('verify.failed') : L('verify.interrupted'), last.checked, last.total]);
    }
    if (s.bad > 0) return L('verify.foundBad', [s.bad, s.unchecked]);
    if (s.unchecked > 0) return L('verify.newSince', [s.unchecked]);
    if (last.outcome != 'succeeded') return L('verify.lastBad', [last.bad]);
    return L('verify.lastOK').trim();
  }

  void _toggleCheck(bool verifying) {
    if (verifying) {
      Core.cancelVerify();
    } else {
      try {
        Core.startVerify();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L('settings.checkFailed'))));
      }
    }
    _loadIntegrity();
  }

  void _openLog() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _LogPage(file: widget.logFile)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final integrity = _integrity;
    final verifying = integrity?.last?.running ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(L('settings.about'))),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
          const SizedBox(height: 32),
          Center(
            child: GestureDetector(
              key: const ValueKey('aboutIcon'),
              onTap: _iconTapped,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 24, offset: const Offset(0, 8))],
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(26), child: Image.asset('assets/app_icon.png', width: 112, height: 112)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Center(child: Text(appName, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700))),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(L('about.tagline'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 14),
          FutureBuilder<PackageInfo>(
            future: _info,
            builder: (context, info) => Center(
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Text(
                    info.data == null ? ' ' : '${L('about.version', [info.data!.version])} · ${L('about.build', [info.data!.buildNumber])}',
                    key: const ValueKey('aboutVersion'),
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          if (Prefs.instance.aboutExtras)
            SettingsSection(title: L('settings.section.maintenance'), footer: L('settings.maintenance.footer'), children: [
              ListTile(
                key: const ValueKey('aboutCheck'),
                leading: SettingsIcon(verifying ? Icons.stop : Icons.verified_user, danger: verifying,
                    // the check ran and found everything in order
                    mascot: !verifying && integrity?.last != null && integrity!.bad == 0 && integrity.unchecked == 0 ? 'shield' : null),
                title: Text(verifying ? L('settings.stopCheck') : L('settings.check')),
                onTap: () => _toggleCheck(verifying),
              ),
              ListTile(
                key: const ValueKey('aboutIntegrity'),
                leading: const SettingsIcon(Icons.report),
                title: Text(L('settings.integrity')),
                subtitle: Text(integrity == null ? L('settings.checkUnreadable') : _integrityText(integrity)),
              ),
              ListTile(key: const ValueKey('aboutLog'), leading: const SettingsIcon(Icons.article_outlined), title: Text(L('about.logs')), onTap: _openLog),
              ListTile(key: const ValueKey('exportDiagnostics'), leading: const SettingsIcon(Icons.medical_services_outlined), title: Text(L('settings.exportDiagnostics')), onTap: widget.onExportDiagnostics),
            ]),
        ]),
      ),
    );
  }
}

class _LogPage extends StatefulWidget {
  const _LogPage({required this.file});
  final String file;
  @override
  State<_LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<_LogPage> {
  late final Future<String> _text = _read();

  /// The newest lines first; the file is capped at 2 MB by the core.
  Future<String> _read() async {
    try {
      final lines = await File(widget.file).readAsLines();
      return lines.reversed.take(500).join('\n');
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(L('about.logs')),
          actions: [
            FutureBuilder<String>(
              future: _text,
              builder: (context, t) => IconButton(
                tooltip: L('viewer.copy'),
                icon: const Icon(Icons.copy),
                onPressed: (t.data ?? '').isEmpty ? null : () => Clipboard.setData(ClipboardData(text: t.data!)),
              ),
            ),
          ],
        ),
        body: FutureBuilder<String>(
          future: _text,
          builder: (context, t) => t.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : t.data!.isEmpty
                  ? Center(child: Text(L('about.logs.empty')))
                  : SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + MediaQuery.paddingOf(context).bottom),
                      child: SelectableText(contextMenuBuilder: appTextMenu, t.data!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
        ),
      );
}
