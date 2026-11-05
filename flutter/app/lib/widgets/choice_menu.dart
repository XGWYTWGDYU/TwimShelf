import 'package:flutter/material.dart';

import '../actions/media_actions.dart' show menuAnimation;

/// A choice among a few, in place of Flutter's dropdown (its panel grows empty and its items fade
/// in one by one, with a scrollbar always showing): a pill with the current value, and the same
/// menu as everywhere else, opening whole. With [label] it is a field of a form.
class ChoiceMenu<T> extends StatelessWidget {
  const ChoiceMenu({super.key, required this.value, required this.items, required this.onChanged, this.hint, this.label});
  final T? value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final String? hint;
  final String? label;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final from = box.localToGlobal(Offset.zero, ancestor: overlay);
    final scheme = Theme.of(context).colorScheme;
    final chosen = await showMenu<(T,)>(
      context: context,
      popUpAnimationStyle: menuAnimation,
      constraints: label == null ? null : BoxConstraints(minWidth: box.size.width, maxWidth: box.size.width),
      position: RelativeRect.fromRect(Rect.fromLTWH(from.dx, from.dy + box.size.height + 4, box.size.width, 0), Offset.zero & overlay.size),
      items: [
        for (final (v, title) in items)
          PopupMenuItem(
            value: (v,),
            child: Row(children: [
              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
              SizedBox(width: 28, child: v == value ? Icon(Icons.check, size: 18, color: scheme.primary) : null),
            ]),
          ),
      ],
    );
    if (chosen != null && chosen.$1 != value) onChanged(chosen.$1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String? shown;
    for (final (v, title) in items) {
      if (v == value) shown = title;
    }
    final text = Text(shown ?? hint ?? '', maxLines: 1, overflow: TextOverflow.ellipsis);
    if (label != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _open(context),
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.arrow_drop_down)),
          child: text,
        ),
      );
    }
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: items.isEmpty ? null : () => _open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: DefaultTextStyle.merge(style: theme.textTheme.labelLarge, child: text)),
              const SizedBox(width: 2),
              Icon(Icons.unfold_more, size: 18, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }
}
