import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The menu of selected text, for every `SelectableText` and `TextField`. On Windows and Linux,
/// Flutter draws its own plain strip instead of a system menu, so it is replaced by the app's
/// menu look. Elsewhere the platform's own stays.
Widget appTextMenu(BuildContext context, EditableTextState state) {
  if (defaultTargetPlatform != TargetPlatform.windows && defaultTargetPlatform != TargetPlatform.linux) {
    return AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
  }
  return TextMenu(anchor: state.contextMenuAnchors.primaryAnchor, items: state.contextMenuButtonItems);
}

const _screenPadding = 8.0;

/// At [anchor] (kept on screen), as the app's other menus: same corners, colours, row size.
class TextMenu extends StatelessWidget {
  const TextMenu({super.key, required this.anchor, required this.items});
  final Offset anchor;
  final List<ContextMenuButtonItem> items;

  static IconData? _icon(ContextMenuButtonType type) => switch (type) {
        ContextMenuButtonType.cut => Icons.content_cut,
        ContextMenuButtonType.copy => Icons.content_copy,
        ContextMenuButtonType.paste => Icons.content_paste,
        ContextMenuButtonType.selectAll => Icons.select_all,
        ContextMenuButtonType.delete => Icons.delete_outline,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final menu = Theme.of(context).popupMenuTheme;
    final top = MediaQuery.paddingOf(context).top + _screenPadding;
    return Padding(
      padding: EdgeInsets.fromLTRB(_screenPadding, top, _screenPadding, _screenPadding),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(anchor: anchor - Offset(_screenPadding, top)),
        child: Material(
          color: menu.color,
          elevation: menu.elevation ?? 3,
          shape: menu.shape,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: menu.menuPadding ?? const EdgeInsets.all(6),
            child: IntrinsicWidth(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 132),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in items)
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: item.onPressed,
                        child: SizedBox(
                          height: 40,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(children: [
                              SizedBox(width: 20, child: Icon(_icon(item.type), size: 20)),
                              const SizedBox(width: 12),
                              Flexible(child: Text(AdaptiveTextSelectionToolbar.getButtonLabel(context, item), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            ]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
