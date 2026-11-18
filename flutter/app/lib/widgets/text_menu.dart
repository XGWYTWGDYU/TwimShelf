import 'package:flutter/material.dart';

/// The menu of selected text, for every `SelectableText` and `TextField`: the platform's own.
Widget appTextMenu(BuildContext context, EditableTextState state) =>
    AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
