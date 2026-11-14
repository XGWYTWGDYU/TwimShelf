import 'package:flutter/material.dart';

import '../app/activity.dart';
import '../app/prefs.dart';
import '../mascot/mascot.dart';
import 'media_image.dart';

/// What runs in the background (downloads, imports, AI tagging, sync…), as cards floating over
/// every page: at the bottom right of a wide window, above the floating bar on a phone (as the
/// native apps show it). Out of the way while the media viewer is open.
class ActivityPanel extends StatelessWidget {
  const ActivityPanel({super.key, required this.center, required this.bottomInset, required this.compact});
  final ActivityCenter center;
  /// Room kept free at the bottom (the floating bar).
  final double bottomInset;
  /// A phone's width: the panel spans the width instead of sitting in the corner.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([center, immersivePages]),
      builder: (context, _) {
        final list = immersivePages.value > 0 ? const <Activity>[] : center.activities;
        final mq = MediaQuery.of(context);
        final panel = AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a), child: child),
          ),
          child: list.isEmpty ? const SizedBox.shrink(key: ValueKey('activity-none')) : _Panel(key: const ValueKey('activity-panel'), list: list),
        );
        return Positioned(
          right: compact ? 12 + mq.padding.right : 18 + mq.padding.right,
          left: compact ? 12 + mq.padding.left : null,
          bottom: bottomInset + (compact ? 8 : 18) + mq.padding.bottom,
          // the panel takes no taps: what is under it stays usable around the cards
          child: IgnorePointer(child: compact ? panel : SizedBox(width: 340, child: panel)),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.list});
  final List<Activity> list;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('activityPanel'),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _Card(key: ValueKey('activity-${list[i].kind.name}'), activity: list[i]),
          ],
        ]),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.activity});
  final Activity activity;

  static IconData _icon(ActivityKind k) => switch (k) {
        ActivityKind.download => Icons.download_for_offline,
        ActivityKind.model => Icons.inventory_2,
        ActivityKind.tagging => Icons.auto_awesome,
        ActivityKind.sync => Icons.sync,
        ActivityKind.verify => Icons.verified_user,
        ActivityKind.importing => Icons.archive,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final a = activity;
    // the mascot mode: shopping for a download, the camera for AI tagging
    final mascot = !Prefs.instance.mascot ? null : a.kind == ActivityKind.download ? 'bag' : a.kind == ActivityKind.tagging ? 'camera' : null;
    final Widget symbol = a.kind == ActivityKind.sync
        ? const _Spinning(child: Icon(Icons.sync))
        : MascotIcon(mascot, size: 34, fallback: Icon(_icon(a.kind)));
    final preview = a.previewPath != null && !a.previewIsVideo ? a.previewPath : null;
    return Row(children: [
      Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: mascot != null ? null : scheme.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(9)),
        clipBehavior: Clip.antiAlias,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: preview == null
              ? IconTheme(key: const ValueKey('symbol'), data: IconThemeData(color: scheme.primary, size: 22), child: Center(child: symbol))
              : Image(
                  key: ValueKey(preview),
                  image: mediaImage(preview, cacheWidth: 140, maxSide: 160),
                  fit: BoxFit.cover,
                  width: 46,
                  height: 46,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => IconTheme(data: IconThemeData(color: scheme.primary, size: 22), child: Center(child: symbol)),
                ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(a.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: a.progress ?? 0),
              duration: const Duration(milliseconds: 300),
              builder: (_, v, _) => LinearProgressIndicator(value: a.progress == null ? null : v, minHeight: 4),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _Spinning extends StatefulWidget {
  const _Spinning({required this.child});
  final Widget child;

  @override
  State<_Spinning> createState() => _SpinningState();
}

class _SpinningState extends State<_Spinning> with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _turns, child: widget.child);
}
