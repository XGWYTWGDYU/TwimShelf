import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/local_models.dart';
import '../../l10n/l10n.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';

/// Where the store's answers come from: the core, off the drawing thread (they wait on the network).
class ModelHubApi {
  const ModelHubApi();
  HubDevice? device() => Core.hubDevice();
  Future<HubPage> search(String format, String query, bool uncensored, String? next) => coreRunAsync(() => Core.hubSearch(format, query, uncensored, next));
  Future<HubDetail> repo(String format, String repo) => coreRunAsync(() => Core.hubRepo(format, repo));
}

String _size(int bytes) => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB'; // i18n-exempt: unit symbols
// as the device is sold: 24 GB, not 25.8
String _memory(int bytes) => '${(bytes / (1 << 30)).round()} GB'; // i18n-exempt: unit symbol
String _params(int n) => '${(n / 1e9).toStringAsFixed(1)}B'; // i18n-exempt: unit symbol
String _shortName(String repo) => repo.split('/').last;
String _tierTitle(String tier) => L('hub.tier.$tier'); // i18n-exempt: keys hub.tier.*

(IconData, Color) _tierIcon(String tier, ColorScheme scheme) => switch (tier) {
      'recommended' => (Icons.verified, Colors.green),
      'usable' => (Icons.error_outline, Colors.orange),
      'tooLarge' => (Icons.block, scheme.error),
      _ => (Icons.help_outline, scheme.onSurfaceVariant),
    };

Future<bool> _confirm(BuildContext context, String title, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
          FilledButton(key: const ValueKey('hub-confirm'), onPressed: () => Navigator.pop(d, true), child: Text(L('common.download'))),
        ],
      ),
    ) ==
    true;

/// A running download (with its cancel) or the last one's failure.
class _DownloadState extends StatelessWidget {
  const _DownloadState({required this.local, this.repo});
  final LocalModels local;
  /// Only about this repo; every download when null.
  final String? repo;

  @override
  Widget build(BuildContext context) {
    final dl = local.download;
    if (dl == null || (repo != null && dl.repo != repo)) return const SizedBox.shrink();
    if (dl.running) {
      return ListTile(
        key: const ValueKey('hub-progress'),
        leading: const Icon(Icons.downloading),
        title: Text(_shortName(dl.repo)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 6),
          LinearProgressIndicator(value: dl.total_bytes == 0 || dl.verifying ? null : dl.done_bytes / dl.total_bytes),
          const SizedBox(height: 4),
          Text(dl.verifying ? L('models.verifying') : dl.total_bytes == 0 ? L('models.connecting') : '${_size(dl.done_bytes)} / ${_size(dl.total_bytes)}'),
        ]),
        trailing: IconButton(tooltip: L('models.cancelDownload'), icon: const Icon(Icons.close), onPressed: local.cancelDownload),
      );
    }
    final e = dl.error;
    if (e == null) return const SizedBox.shrink();
    return ListTile(leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error), title: Text(L('models.downloadFailed')), subtitle: Text(e));
  }
}

/// The model store: the models this app offers, and a search of Hugging Face filtered down to
/// what this device can run. Every platform downloads from here; importing, exporting and pulling
/// from other devices are for Apple devices alone and stay on the models page.
class ModelHubPage extends StatefulWidget {
  const ModelHubPage({super.key, required this.local, this.api = const ModelHubApi()});
  final LocalModels local;
  final ModelHubApi api;

  @override
  State<ModelHubPage> createState() => _ModelHubPageState();
}

class _ModelHubPageState extends State<ModelHubPage> {
  final _search = TextEditingController();
  HubDevice? _device;
  List<HubRepo> _items = const [];
  List<HubHidden> _hidden = const [];
  String? _next;
  String? _error;
  String _query = '';
  bool _loading = false, _searched = false, _onlyFit = true, _uncensored = false;
  // an answer to an earlier search that arrives late is not shown over a newer one
  int _generation = 0;

  LocalModels get local => widget.local;
  bool get _browsing => _query.trim().isEmpty && !_uncensored;
  List<HubRepo> get _shown => _onlyFit ? _items.where((r) => r.tier != 'tooLarge').toList() : _items;

  @override
  void initState() {
    super.initState();
    _device = widget.api.device();
    _run(fresh: true);
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _run({required bool fresh}) async {
    final run = fresh ? ++_generation : _generation;
    final next = fresh ? null : _next;
    setState(() {
      if (fresh) {
        _items = const [];
        _hidden = const [];
        _next = null;
      }
      _loading = true;
      _error = null;
    });
    try {
      final p = await widget.api.search(local.format, _query, _uncensored, next);
      if (!mounted || run != _generation) return;
      final seen = _items.map((r) => r.repo).toSet();
      setState(() {
        _items = [..._items, ...p.items.where((r) => !seen.contains(r.repo))];
        _hidden = [..._hidden, ...p.hidden];
        _next = p.next;
        _device = p.device;
      });
    } catch (e) {
      if (!mounted || run != _generation) return;
      setState(() => _error = '$e');
    }
    if (mounted && run == _generation) {
      setState(() {
        _loading = false;
        _searched = true;
      });
    }
  }

  Future<void> _offer(CatalogEntry c) async {
    if (!await _confirm(context, L('models.download.title', [c.name]), L('models.download.message', [c.note, _size(c.bytes)]))) return;
    try {
      local.installCurated(c);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${L('models.download.failed')}: $e')));
    }
  }

  Widget _curatedTile(CatalogEntry c, ColorScheme scheme) {
    final here = local.find(c.folder) != null;
    final (icon, color) = here ? (Icons.check_circle, Colors.green) : _tierIcon(c.tier, scheme);
    return ListTile(
      key: ValueKey('hub-curated-${c.folder}'),
      leading: Icon(icon, color: color),
      title: Text(c.name),
      subtitle: Text(here ? L('hub.installed') : [c.note, _tierTitle(c.tier), _size(c.bytes)].join(' · ')),
      trailing: here ? null : IconButton(tooltip: L('common.download'), icon: const Icon(Icons.download), onPressed: local.download?.running == true ? null : () => _offer(c)),
    );
  }

  Widget _repoTile(HubRepo r, ColorScheme scheme) {
    final (icon, color) = _tierIcon(r.tier, scheme);
    return ListTile(
      key: ValueKey('hub-repo-${r.repo}'),
      leading: Icon(icon, color: color),
      title: Text(_shortName(r.repo)),
      subtitle: Text([
        _tierTitle(r.tier),
        if (r.estimated_bytes != null) L('hub.estimate', [_size(r.estimated_bytes!)]),
        if (r.params != null) _params(r.params!),
        if (r.architecture != null) r.architecture!,
        if (r.claims_uncensored) L('hub.claim'),
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ModelHubRepoPage(local: local, api: widget.api, repo: r.repo))),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: local,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          final d = _device;
          final unknown = L('hub.unknown');
          final over = _onlyFit ? _items.length - _shown.length : 0;
          return Scaffold(
            appBar: AppBar(title: Text(L('hub.title'))),
            body: SafeArea(
              top: false,
              bottom: false,
              child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(contextMenuBuilder: appTextMenu, 
                    key: const ValueKey('hub-search'),
                    controller: _search,
                    autocorrect: false,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(hintText: L('hub.search.placeholder'), prefixIcon: const Icon(Icons.search), border: const OutlineInputBorder()),
                    onSubmitted: (text) {
                      _query = text;
                      _run(fresh: true);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 8, runSpacing: 4, children: [
                    FilterChip(key: const ValueKey('hub-fit'), label: Text(L('hub.filter.fit')), selected: _onlyFit, onSelected: (v) => setState(() => _onlyFit = v)),
                    FilterChip(
                      key: const ValueKey('hub-claim'),
                      label: Text(L('hub.filter.uncensored')),
                      selected: _uncensored,
                      onSelected: (v) {
                        _uncensored = v;
                        _run(fresh: true);
                      },
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    [
                      L('hub.device', [d?.memory_bytes == null ? unknown : _memory(d!.memory_bytes!), d?.free_bytes == null ? unknown : _size(d!.free_bytes!)]),
                      if (local.devices != null && local.devices!.isNotEmpty) L('models.local.devices', [local.devices!]),
                      L('hub.device.footer'),
                    ].join('\n'),
                    key: const ValueKey('hub-device'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                _DownloadState(local: local),
                if (_browsing)
                  SettingsSection(title: L('hub.curated'), footer: L('hub.curated.footer'), children: [for (final c in local.catalog) _curatedTile(c, scheme)]),
                SettingsSection(title: _browsing ? L('hub.popular') : L('hub.results'), footer: L('hub.results.footer'), children: [
                  for (final r in _shown) _repoTile(r, scheme),
                  if (_loading) ListTile(key: const ValueKey('hub-loading'), leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)), title: Text(L('hub.loading'))),
                  if (_error != null) ...[
                    ListTile(key: const ValueKey('hub-error'), leading: Icon(Icons.warning_amber_rounded, color: scheme.error), title: Text(_error!)),
                    ListTile(leading: const Icon(Icons.refresh), title: Text(L('models.retry')), onTap: () => _run(fresh: true)),
                  ] else if (_searched && !_loading && _shown.isEmpty)
                    ListTile(key: const ValueKey('hub-empty'), leading: const Icon(Icons.search_off), title: Text(L('hub.empty'))),
                  if (over > 0)
                    ListTile(key: const ValueKey('hub-over'), leading: const Icon(Icons.memory), title: Text(L('hub.overMemory', [over])), onTap: () => setState(() => _onlyFit = false)),
                  if (_next != null && !_loading)
                    ListTile(key: const ValueKey('hub-more'), leading: const Icon(Icons.expand_more), title: Text(L('hub.more')), onTap: () => _run(fresh: false)),
                ]),
                // never left out silently: which ones, and why
                if (_hidden.isNotEmpty)
                  SettingsSection(children: [
                    ExpansionTile(
                      key: const ValueKey('hub-hidden'),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      leading: const Icon(Icons.visibility_off_outlined),
                      title: Text(L('hub.hidden', [_hidden.length])),
                      children: [for (final h in _hidden) ListTile(dense: true, title: SelectableText(contextMenuBuilder: appTextMenu, h.repo), subtitle: Text(h.reason))],
                    ),
                  ]),
              ]),
            ),
          );
        },
      );
}

/// One repo of the store: what it is, each version with its real size, and what is not offered.
class ModelHubRepoPage extends StatefulWidget {
  const ModelHubRepoPage({super.key, required this.local, required this.repo, this.api = const ModelHubApi()});
  final LocalModels local;
  final String repo;
  final ModelHubApi api;

  @override
  State<ModelHubRepoPage> createState() => _ModelHubRepoPageState();
}

class _ModelHubRepoPageState extends State<ModelHubRepoPage> {
  HubDetail? _detail;
  String? _error;

  LocalModels get local => widget.local;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await widget.api.repo(local.format, widget.repo);
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _offer(HubDetail d, HubVariant v) async {
    if (!await _confirm(context, L('models.download.title', [_shortName(widget.repo)]), L('hub.download.message', [v.label, _size(v.bytes)]))) return;
    try {
      local.installVariant(d, v);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${L('models.download.failed')}: $e')));
    }
  }

  Widget _variant(HubDetail d, HubVariant v, ColorScheme scheme) {
    final here = local.find(v.folder) != null;
    final (icon, color) = here ? (Icons.check_circle, Colors.green) : _tierIcon(v.tier, scheme);
    return ListTile(
      key: ValueKey('hub-variant-${v.label}'),
      leading: Icon(icon, color: color),
      title: Text(v.suggested ? L('hub.variant.suggested', [v.label]) : v.label),
      subtitle: Text(here ? L('hub.installed') : v.enough_space ? '${_tierTitle(v.tier)} · ${_size(v.bytes)}' : L('hub.variant.noSpace', [_size(v.bytes)])),
      trailing: here || !v.enough_space ? null : IconButton(tooltip: L('common.download'), icon: const Icon(Icons.download), onPressed: local.download?.running == true ? null : () => _offer(d, v)),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: local,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          final d = _detail;
          return Scaffold(
            appBar: AppBar(title: Text(_shortName(widget.repo))),
            body: SafeArea(
              top: false,
              bottom: false,
              child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
                SettingsSection(footer: L('hub.unverified.footer'), children: [
                  ListTile(title: Text(L('hub.detail.repo')), subtitle: SelectableText(contextMenuBuilder: appTextMenu, widget.repo)),
                  if (d?.repo.architecture != null) ListTile(title: Text(L('hub.detail.architecture')), trailing: Text(d!.repo.architecture!)),
                  if (d?.repo.params != null) ListTile(title: Text(L('hub.detail.parameters')), trailing: Text(_params(d!.repo.params!))),
                  if (d != null) ListTile(title: Text(L('hub.detail.license')), trailing: Text(d.repo.license ?? L('hub.unknown'))),
                  if (d != null) ListTile(title: Text(L('hub.detail.downloads')), trailing: Text('${d.repo.downloads}')),
                  if (d?.repo.claims_uncensored == true) ListTile(leading: const Icon(Icons.sell_outlined), title: Text(L('hub.claim'))),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: Text(L('hub.detail.openPage')),
                    onTap: () => launchUrl(Uri.https('huggingface.co', '/${widget.repo}'), mode: LaunchMode.externalApplication),
                  ),
                ]),
                _DownloadState(local: local, repo: widget.repo),
                if (_error != null)
                  SettingsSection(children: [
                    ListTile(key: const ValueKey('hub-error'), leading: Icon(Icons.warning_amber_rounded, color: scheme.error), title: Text(_error!)),
                    ListTile(leading: const Icon(Icons.refresh), title: Text(L('models.retry')), onTap: _load),
                  ])
                else if (d == null)
                  ListTile(leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)), title: Text(L('hub.loading')))
                else ...[
                  if (d.problem != null)
                    SettingsSection(children: [
                      ListTile(key: const ValueKey('hub-problem'), leading: Icon(Icons.block, color: scheme.error), title: Text(L('hub.detail.cannotInstall')), subtitle: Text(d.problem!)),
                    ]),
                  if (d.variants.isNotEmpty)
                    SettingsSection(title: L('hub.detail.versions'), footer: L('hub.detail.versions.footer'), children: [for (final v in d.variants) _variant(d, v, scheme)]),
                  if (d.skipped.isNotEmpty)
                    SettingsSection(title: L('hub.detail.skipped'), children: [for (final s in d.skipped) ListTile(dense: true, title: Text(s.name), subtitle: Text(s.reason))]),
                ],
              ]),
            ),
          );
        },
      );
}
