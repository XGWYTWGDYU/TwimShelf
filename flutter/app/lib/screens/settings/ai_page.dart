import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import '../../actions/search_export.dart';
import '../../ai/auto_tagger.dart';
import '../../ai/external_models.dart';
import '../../ai/local_models.dart';
import '../../app/sync_model.dart';
import '../../l10n/l10n.dart';
import '../../widgets/choice_menu.dart';
import '../../mascot/mascot.dart';
import '../settings_page.dart';
import 'model_hub_page.dart';
import '../../widgets/text_menu.dart';
import '../../platform/files.dart';

/// 打标签: automatic tagging of new media, the model that tags, a run over the whole library, the
/// on-device models (MLX on Apple devices, llama.cpp elsewhere) and the OpenAI-compatible
/// services the user added.
class AiPage extends StatelessWidget {
  const AiPage({super.key, required this.models, required this.ai, required this.tagger, this.sync});
  final ExternalModels models;
  final ExternalAI ai;
  final AutoTagger tagger;
  /// For pulling models from the account's other Apple devices.
  final SyncModel? sync;
  LocalModels get local => LocalModels.instance;

  Future<void> _add(BuildContext context) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ExternalModelPage(models: models, ai: ai, model: ExternalModel.create()),
      ));

  Future<void> _retagAll(BuildContext context, String model) async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('models.retag.oldTitle')),
        content: Text(L('models.retag.oldMessage')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(L('models.retag.replace'))),
          FilledButton(onPressed: () => Navigator.pop(c, false), child: Text(L('models.retag.keep'))),
        ],
      ),
    );
    if (replace != null) tagger.retagAll(model: model, replaceOld: replace);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([models, tagger, local]),
        builder: (context, _) {
          final all = models.all;
          final taggers = [
            for (final m in local.installed.where((m) => m.vision)) (m.id, local.title(m)),
            for (final m in all) (m.id, m.title),
          ];
          final active = models.activeTaggerId;
          final scheme = Theme.of(context).colorScheme;
          final error = tagger.lastError;
          return Scaffold(
            appBar: AppBar(title: Text(L('models.tagging'))),
            body: SafeArea(
              top: false,
              bottom: false,
              child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
                if (taggers.isEmpty)
                  SettingsSection(children: [
                    ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: Text(L('models.none.title')), subtitle: Text(L('models.none.message'))),
                  ])
                else
                  SettingsSection(title: L('models.tagging'), children: [
                    SwitchListTile(
                      key: const ValueKey('ai-autotag'),
                      title: Text(L('models.autoTag')),
                      value: models.autoTag,
                      onChanged: (v) async {
                        HapticFeedback.selectionClick();
                        await models.setAutoTag(v);
                        if (v) await tagger.startIfEnabled(asked: true);
                      },
                    ),
                    ListTile(
                      title: Text(L('models.defaultTagger')),
                      trailing: ChoiceMenu<String>(
                        key: const ValueKey('ai-tagger'),
                        value: taggers.any((m) => m.$1 == active) ? active : null,
                        hint: L('models.noneInstalled'),
                        items: [for (final m in taggers) (m.$1, m.$2)],
                        onChanged: (id) async {
                          await models.setActiveTagger(id);
                          await tagger.startIfEnabled(asked: true);
                        },
                      ),
                    ),
                    // paused, nothing runs, and this is the way back
                    if (tagger.running || tagger.paused)
                      ListTile(
                        key: const ValueKey('ai-run'),
                        leading: tagger.paused ? const Icon(Icons.pause_circle_outline) : const MascotIcon('camera', size: 30, fallback: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                        title: Text(tagger.title.isEmpty ? L('models.inProgress') : tagger.title),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (tagger.total > 0) ...[
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: tagger.done / tagger.total),
                            const SizedBox(height: 4),
                            Text(tagger.paused ? '${L('activity.paused')} · ${tagger.done} / ${tagger.total}' : '${tagger.done} / ${tagger.total}'),
                          ] else if (tagger.paused)
                            Text(L('activity.paused')),
                          const SizedBox(height: 4),
                          Text(L('models.tagging.controls'), style: Theme.of(context).textTheme.bodySmall),
                        ]),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            key: const ValueKey('ai-pause'),
                            tooltip: tagger.paused ? L('models.tagging.continue') : L('mac.pause'),
                            icon: Icon(tagger.paused ? Icons.play_arrow : Icons.pause),
                            onPressed: tagger.paused ? tagger.resume : tagger.pause,
                          ),
                          IconButton(
                            key: const ValueKey('ai-stop'),
                            tooltip: L('models.stopTagging'),
                            icon: const Icon(Icons.stop),
                            onPressed: tagger.stop,
                          ),
                        ]),
                      ),
                    if (error is ExternalFailure)
                      ListTile(leading: Icon(Icons.error_outline, color: scheme.error), title: Text(error.message)),
                    _FailuresTile(tagger: tagger),
                    if (active != null && !tagger.running)
                      ListTile(leading: const Icon(Icons.refresh), title: Text(L('models.retagAllEllipsis')), onTap: () => _retagAll(context, active)),
                  ]),
                _LocalModelsSection(local: local, active: active, models: models, onRetag: (m) => _retagAll(context, m), onDeleted: (id) async {
                  if (id == active) await models.setActiveTagger(null);
                }),
                if (LocalModels.apple && local.supported) _AppleOnlySection(local: local, sync: sync),
                SettingsSection(title: L('models.external'), children: [
                  for (final m in all)
                    _ModelCard(
                      key: ValueKey('ai-model-${m.id}'),
                      leading: Icon(m.origin.startsWith('https') ? Icons.cloud_outlined : Icons.dns_outlined),
                      title: m.title,
                      subtitle: m.id == active ? '${L('models.defaultPrefix')}${m.host}' : m.host,
                      children: [
                        _ExternalForm(models: models, ai: ai, model: m, isNew: false),
                        _PromptEditor(models: models, model: m.id, onRetag: (id) => _retagAll(context, id)),
                        ListTile(
                          key: ValueKey('ai-delete-${m.id}'),
                          leading: Icon(Icons.delete_outline, color: scheme.error),
                          title: Text(L('models.external.delete'), style: TextStyle(color: scheme.error)),
                          onTap: () async {
                            await models.remove(m.id);
                            if (active == m.id) await models.setActiveTagger(null);
                          },
                        ),
                      ],
                    ),
                  ListTile(
                    key: const ValueKey('ai-add'),
                    leading: const Icon(Icons.add),
                    title: Text(L('models.addExternalEllipsis')),
                    onTap: () => _add(context),
                  ),
                ]),
              ]),
            ),
          );
        },
      );
}

String _size(int bytes) => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB'; // i18n-exempt: unit symbols

/// What is installed here, a download under way, and the way to the model store.
class _LocalModelsSection extends StatelessWidget {
  const _LocalModelsSection({required this.local, required this.active, required this.models, required this.onRetag, required this.onDeleted});
  final LocalModels local;
  final String? active;
  final ExternalModels models;
  final Future<void> Function(String model) onRetag;
  final Future<void> Function(String id) onDeleted;

  Future<void> _delete(BuildContext context, ModelInfo m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(L('models.delete.title', [local.title(m)])),
        content: Text(L('models.delete.message')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error), onPressed: () => Navigator.pop(d, true), child: Text(L('common.delete'))),
        ],
      ),
    );
    if (ok != true) return;
    await local.delete(m.id);
    await onDeleted(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!local.supported) {
      return SettingsSection(title: L('models.local'), children: [
        ListTile(leading: const Icon(Icons.memory), title: Text(L('models.local.unsupported'))),
      ]);
    }
    final dl = local.download;
    final footer = [
      if (!LocalModels.apple) L('models.local.footer.gguf'),
      if (local.devices != null && local.devices!.isNotEmpty) L('models.local.devices', [local.devices!]),
    ].join('\n');
    final extra = local.installed.where((m) => local.catalogFor(m.id) == null).toList();
    return SettingsSection(title: L('models.local'), footer: footer.isEmpty ? null : footer, children: [
      for (final c in local.catalog)
        if (local.find(c.folder) case final installed?)
          _ModelCard(
            key: ValueKey('local-${c.folder}'),
            leading: Icon(Icons.auto_awesome, color: scheme.primary),
            title: c.name,
            subtitle: [c.note, L('models.installed', [_size(installed.bytes)]), if (installed.id == active) L('models.defaultPrefix').trim()].join(' · '),
            children: [
              if (installed.vision) _PromptEditor(models: models, model: installed.id, onRetag: onRetag),
              ListTile(
                key: ValueKey('local-delete-${c.folder}'),
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text(L('common.delete'), style: TextStyle(color: scheme.error)),
                onTap: () => _delete(context, installed),
              ),
            ],
          ),
      // from the store's search, imported or pulled: models that are not in the catalog
      for (final m in extra)
        _ModelCard(
          key: ValueKey('local-${m.id}'),
          leading: Icon(m.vision ? Icons.auto_awesome : Icons.manage_search, color: scheme.primary),
          title: local.title(m),
          subtitle: [L('models.installed', [_size(m.bytes)]), if (m.id == active) L('models.defaultPrefix').trim()].join(' · '),
          children: [
            if (m.vision) _PromptEditor(models: models, model: m.id, onRetag: onRetag),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(L('common.delete'), style: TextStyle(color: scheme.error)),
              onTap: () => _delete(context, m),
            ),
          ],
        ),
      if (dl != null && dl.running)
        ListTile(
          key: const ValueKey('local-progress'),
          leading: const Icon(Icons.downloading),
          title: Text(dl.repo.split('/').last),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 6),
            LinearProgressIndicator(value: dl.total_bytes == 0 || dl.verifying ? null : dl.done_bytes / dl.total_bytes),
            const SizedBox(height: 4),
            Text(dl.verifying ? L('models.verifying') : dl.total_bytes == 0 ? L('models.connecting') : '${_size(dl.done_bytes)} / ${_size(dl.total_bytes)}'),
          ]),
          trailing: IconButton(tooltip: L('models.cancelDownload'), icon: const Icon(Icons.close), onPressed: local.cancelDownload),
        ),
      if (dl != null && !dl.running && dl.error != null)
        ListTile(leading: Icon(Icons.error_outline, color: scheme.error), title: Text(L('models.downloadFailed')), subtitle: Text(dl.error!)),
      ListTile(
        key: const ValueKey('local-store'),
        leading: Icon(Icons.storefront_outlined, color: scheme.primary),
        title: Text(L('hub.title')),
        subtitle: Text(L('hub.entry.detail')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ModelHubPage(local: local))),
      ),
    ]);
  }
}

/// MLX models between Apple devices: import a folder or ZIP, export one, pull one from another
/// Apple device of the account. Not offered on Android, Windows or Linux.
class _AppleOnlySection extends StatefulWidget {
  const _AppleOnlySection({required this.local, this.sync});
  final LocalModels local;
  final SyncModel? sync;

  @override
  State<_AppleOnlySection> createState() => _AppleOnlySectionState();
}

class _AppleOnlySectionState extends State<_AppleOnlySection> {
  List<(DiscoveredPeer, ModelInfo)>? _offers;
  bool _querying = false;
  LocalModels get local => widget.local;

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'ZIP', extensions: ['zip'])]); // i18n-exempt: file type name
    if (file == null) return;
    _toast(L('models.importing'));
    try {
      await local.import(await pickedPath(file));
      _toast(L('models.imported'));
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _export(ModelInfo m) async {
    // no save dialog on iOS: a temporary file, then the share sheet
    final to = await outputPath('${m.id}.zip');
    if (to == null) return;
    try {
      await local.export(m.id, to);
      await deliver(to);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _query() async {
    final peers = (widget.sync?.accountPeers ?? const <DiscoveredPeer>[])
        // MLX models: other Apple devices only
        .where((p) => p.reachable && const ['mac', 'iphone', 'ipad'].contains(p.kind))
        .toList();
    setState(() => _querying = true);
    final have = local.installed.map((m) => m.id).toSet();
    final offers = <(DiscoveredPeer, ModelInfo)>[];
    for (final p in peers) {
      try {
        for (final m in await Core.syncPeerModelsAsync(p.host!, p.port!)) {
          if (m.format == 'mlx' && !have.contains(m.id) && !offers.any((o) => o.$2.id == m.id)) offers.add((p, m));
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _offers = offers;
      _querying = false;
    });
  }

  Future<void> _pull(DiscoveredPeer p, ModelInfo m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(L('models.pull.title', [p.name])),
        content: Text(L('models.pull.message', [local.title(m), _size(m.bytes)])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L('models.pull'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      local.watch();
      await Core.syncPullModelAsync(p.host!, p.port!, m.id, local.title(m), m.bytes);
      local.refresh();
      if (!mounted) return;
      setState(() => _offers = _offers?.where((o) => o.$2.id != m.id).toList());
    } catch (e) {
      _toast('${L('models.pull.failed')}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final offers = _offers;
    return SettingsSection(title: L('models.appleOnly'), footer: L('models.appleOnly.footer'), children: [
      ListTile(key: const ValueKey('local-import'), leading: const Icon(Icons.file_open_outlined), title: Text(L('models.import.button')), onTap: _import),
      for (final m in local.installed)
        ListTile(leading: const Icon(Icons.ios_share), title: Text(L('models.exportZip')), subtitle: Text(local.title(m)), onTap: () => _export(m)),
      if (widget.sync != null) ...[
        ListTile(
          key: const ValueKey('local-peers'),
          leading: _querying ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.devices),
          title: Text(_querying ? L('models.peers.querying') : L('models.peers.query')),
          onTap: _querying ? null : _query,
        ),
        if (offers != null && offers.isEmpty) ListTile(title: Text(L('models.peers.nothing'))),
        for (final (p, m) in offers ?? const <(DiscoveredPeer, ModelInfo)>[])
          ListTile(
            leading: const Icon(Icons.download_for_offline_outlined),
            title: Text(local.title(m)),
            subtitle: Text('${p.name} · ${_size(m.bytes)}'),
            trailing: TextButton(onPressed: () => _pull(p, m), child: Text(L('models.pull'))),
          ),
      ],
    ]);
  }
}

/// One external model: address, model name, key; 测试连接 sends the small gray test image.
/// Adding an external model: its connection, on a page of its own. Once added it is a card.
class ExternalModelPage extends StatelessWidget {
  const ExternalModelPage({super.key, required this.models, required this.ai, required this.model});
  final ExternalModels models;
  final ExternalAI ai;
  final ExternalModel model;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(L('models.addExternal'))),
        body: SafeArea(
          top: false,
          bottom: false,
          child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
            _ExternalForm(models: models, ai: ai, model: model, isNew: true, onSaved: () => Navigator.pop(context)),
          ]),
        ),
      );
}

/// A model that is here, as a card: the tap or the arrow opens it to show its prompt and what
/// else can be done with it.
class _ModelCard extends StatelessWidget {
  const _ModelCard({super.key, required this.leading, required this.title, this.subtitle, required this.children});
  final Widget leading;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: leading,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: children,
      );
}

/// A model's prompt, in its card. Saved, it applies from now on or to everything right away.
class _PromptEditor extends StatefulWidget {
  const _PromptEditor({required this.models, required this.model, required this.onRetag});
  final ExternalModels models;
  final String model;
  final Future<void> Function(String model) onRetag;

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final _system = TextEditingController();
  late final _question = TextEditingController();
  late final _existing = TextEditingController();
  late final _vocabulary = TextEditingController();
  late final _context = TextEditingController();
  late AiPrompt _saved;

  @override
  void initState() {
    super.initState();
    _fill(_saved = widget.models.promptFor(widget.model));
    widget.models.addListener(_changed);
  }

  @override
  void dispose() {
    widget.models.removeListener(_changed);
    for (final c in [_system, _question, _existing, _vocabulary, _context]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(AiPrompt p) {
    _system.text = p.system;
    _question.text = p.prompt;
    _existing.text = p.existing;
    _vocabulary.text = p.vocabulary;
    _context.text = p.context;
  }

  AiPrompt get _edited => AiPrompt(system: _system.text, prompt: _question.text, context: _context.text, existing: _existing.text, vocabulary: _vocabulary.text);
  bool _same(AiPrompt a, AiPrompt b) => a.system == b.system && a.prompt == b.prompt && a.context == b.context && a.existing == b.existing && a.vocabulary == b.vocabulary;

  /// Another device's change comes in: it shows, unless something is being typed here.
  void _changed() {
    final now = widget.models.promptFor(widget.model);
    if (_same(now, _saved)) return;
    if (_same(_edited, _saved)) setState(() => _fill(now));
    _saved = now;
  }

  Future<void> _save() async {
    final p = _edited;
    if (_same(p, _saved)) return;
    _saved = p;
    await widget.models.savePromptFor(widget.model, p);
    if (!mounted) return;
    final now = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('prompt.saved')),
        content: Text(L('prompt.saved.retag')),
        actions: [
          TextButton(key: const ValueKey('promptLater'), onPressed: () => Navigator.pop(c, false), child: Text(L('prompt.saved.later'))),
          FilledButton(key: const ValueKey('promptNow'), onPressed: () => Navigator.pop(c, true), child: Text(L('prompt.saved.now'))),
        ],
      ),
    );
    if (now == true) await widget.onRetag(widget.model);
  }

  Widget _field(TextEditingController c, String label, String help, Key key) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: TextField(contextMenuBuilder: appTextMenu, 
          key: key,
          controller: c,
          minLines: 1,
          maxLines: 6,
          decoration: InputDecoration(labelText: label, helperText: help, helperMaxLines: 3, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text(L('models.promptSection'), style: Theme.of(context).textTheme.titleSmall)),
        _field(_system, L('prompt.system'), L('prompt.system.footer'), const ValueKey('promptSystem')),
        _field(_question, L('prompt.question'), L('prompt.question.footer'), const ValueKey('promptQuestion')),
        _field(_existing, L('prompt.existing'), L('prompt.existing.footer'), const ValueKey('promptExisting')),
        _field(_vocabulary, L('prompt.libraryTags'), L('prompt.libraryTags.footer'), const ValueKey('promptVocabulary')),
        _field(_context, L('prompt.postText'), L('prompt.postText.footer'), const ValueKey('promptContext')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(children: [
            TextButton(key: const ValueKey('promptReset'), onPressed: () => setState(() => _fill(widget.models.defaults)), child: Text(L('mac.prompt.reset'))),
            const Spacer(),
            FilledButton(key: const ValueKey('promptSave'), onPressed: _save, child: Text(L('mac.prompt.save'))),
          ]),
        ),
      ]);
}

/// An external model's connection: on the page that adds one, and in its card.
class _ExternalForm extends StatefulWidget {
  const _ExternalForm({required this.models, required this.ai, required this.model, required this.isNew, this.onSaved});
  final ExternalModels models;
  final ExternalAI ai;
  final ExternalModel model;
  final bool isNew;
  final VoidCallback? onSaved;

  @override
  State<_ExternalForm> createState() => _ExternalFormState();
}

class _ExternalFormState extends State<_ExternalForm> {
  late final _name = TextEditingController(text: widget.model.name);
  late final _url = TextEditingController(text: widget.model.url);
  late final _model = TextEditingController(text: widget.model.model);
  final _key = TextEditingController();
  bool _hasKey = false, _testing = false;
  String? _result;
  bool _ok = false;
  AiCancellation? _test;

  @override
  void initState() {
    super.initState();
    if (!widget.isNew) {
      widget.models.apiKey(widget.model).then((k) {
        if (mounted) setState(() => _hasKey = (k ?? '').isNotEmpty);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _test?.cancel();
    for (final c in [_name, _url, _model, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  ExternalModel get _edited => ExternalModel(id: widget.model.id, name: _name.text.trim(), url: _url.text.trim(), model: _model.text.trim());

  String? _problem() {
    if (_url.text.trim().isEmpty) return L('models.external.needURL');
    if ((_key.text.isNotEmpty || _hasKey) && _model.text.trim().isEmpty) return L('models.external.needModel');
    return null;
  }

  Future<bool> _save() async {
    final p = _problem();
    if (p != null) {
      setState(() {
        _result = p;
        _ok = false;
      });
      return false;
    }
    try {
      final m = _edited;
      await widget.models.save(m);
      if (_key.text.isNotEmpty) {
        await widget.models.setApiKey(m, _key.text.trim());
        _key.clear();
        _hasKey = true;
      }
      return true;
    } on ExternalFailure catch (e) {
      setState(() {
        _result = e.message;
        _ok = false;
      });
    } catch (_) {
      setState(() {
        _result = L('models.external.err.url');
        _ok = false;
      });
    }
    return false;
  }

  Future<void> _runTest() async {
    if (!await _save()) return;
    final c = _test = AiCancellation();
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final tags = await widget.ai.test(_edited, cancellation: c);
      _ok = true;
      _result = '${L('models.external.successColon')}${tags.isEmpty ? L('models.external.noTags') : tags.join(L('list.separator'))}';
    } on ExternalFailure catch (e) {
      _ok = false;
      _result = '${L('models.external.failureColon')}${e.message}';
    } catch (_) {
      _ok = false;
      _result = '${L('models.external.failureColon')}${L('common.notDone')}';
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget field(TextEditingController c, String hint, {Key? key, bool secret = false, TextInputType? type}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: TextField(contextMenuBuilder: appTextMenu, 
            key: key,
            controller: c,
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: !secret,
            keyboardType: type,
            decoration: InputDecoration(labelText: hint, border: const OutlineInputBorder()),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text(L('models.external.connection'), style: Theme.of(context).textTheme.titleSmall)),
      field(_name, L('models.external.name'), key: const ValueKey('ai-name')),
      field(_url, L('models.external.urlPlaceholder'), key: const ValueKey('ai-url'), type: TextInputType.url),
      field(_model, L('models.external.model'), key: const ValueKey('ai-model')),
      field(_key, _hasKey ? '${L('models.external.key')} ••••••' : L('models.external.key'), key: const ValueKey('ai-key'), secret: true),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Text(L('models.external.connection.footer'), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(children: [
          TextButton.icon(
            key: const ValueKey('ai-test'),
            icon: _testing ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.network_check),
            label: Text(_testing ? L('models.external.testing') : L('models.external.test')),
            onPressed: _testing ? null : _runTest,
          ),
          const Spacer(),
          FilledButton(
            key: const ValueKey('ai-save'),
            onPressed: () async {
              if (await _save()) widget.onSaved?.call();
            },
            child: Text(L('common.save')),
          ),
        ]),
      ),
      if (_result != null)
        ListTile(
          key: const ValueKey('ai-result'),
          leading: Icon(_ok ? Icons.check_circle_outline : Icons.error_outline, color: _ok ? scheme.primary : scheme.error),
          title: SelectableText(contextMenuBuilder: appTextMenu, _result!),
        ),
    ]);
  }
}

/// 这台设备无法分析: the media given up on, why, and another try for all of them.
class _FailuresTile extends StatefulWidget {
  const _FailuresTile({required this.tagger});
  final AutoTagger tagger;
  @override
  State<_FailuresTile> createState() => _FailuresTileState();
}

class _FailuresTileState extends State<_FailuresTile> {
  List<AiFailure> _failures = const [];

  @override
  void initState() {
    super.initState();
    widget.tagger.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.tagger.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final f = await coreRunAsync(Core.aiFailures);
    if (mounted && f.length != _failures.length) setState(() => _failures = f);
  }

  Future<void> _show() async {
    final shown = _failures.take(30).map((f) => L('models.failure.line', [f.media_id.substring(0, f.media_id.length.clamp(0, 12)), f.attempts, f.reason]));
    final retry = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('models.failures.title')),
        content: SingleChildScrollView(child: SelectableText(contextMenuBuilder: appTextMenu, [...shown, if (_failures.length > 30) L('models.failures.more', [_failures.length - 30])].join('\n') + L('models.failures.footer'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L('common.close'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(L('models.retry'))),
        ],
      ),
    );
    if (retry != true) return;
    await coreRunAsync(Core.aiFailuresClear);
    await _load();
    await widget.tagger.startIfEnabled(asked: true);
  }

  @override
  Widget build(BuildContext context) => _failures.isEmpty
      ? const SizedBox.shrink()
      : ListTile(
          key: const ValueKey('ai-failures'),
          leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          title: Text(L('models.failures')),
          trailing: Text('${_failures.length}'),
          onTap: _show,
        );
}
