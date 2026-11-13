import 'package:flutter/material.dart';

/// Visibility is temporary: leaving the field or the app masks it again.
class PrivateTextField extends StatefulWidget {
  const PrivateTextField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    this.readOnly = false,
    this.onChanged,
    this.onCopy,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final bool readOnly;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onCopy;

  @override
  State<PrivateTextField> createState() => _PrivateTextFieldState();
}

class _PrivateTextFieldState extends State<PrivateTextField>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _hide() {
    if (_visible) setState(() => _visible = false);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _hide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _hide();
  }

  @override
  void didUpdateWidget(covariant PrivateTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.controller != widget.controller) {
      _visible = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.fieldKey,
    controller: widget.controller,
    focusNode: _focus,
    enabled: widget.enabled,
    readOnly: widget.readOnly,
    obscureText: !_visible,
    obscuringCharacter: '●',
    autocorrect: false,
    enableSuggestions: false,
    onChanged: widget.onChanged,
    onTapOutside: (_) => _focus.unfocus(),
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: ExcludeFocus(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '${_visible ? '隐藏' : '显示'}${widget.label}',
              icon: Icon(
                _visible ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: widget.enabled
                  ? () {
                      _focus.requestFocus();
                      setState(() => _visible = !_visible);
                    }
                  : null,
            ),
            if (widget.onCopy != null)
              IconButton(
                tooltip: '复制${widget.label}',
                icon: const Icon(Icons.copy, size: 17),
                onPressed: widget.enabled ? widget.onCopy : null,
              ),
          ],
        ),
      ),
    ),
  );
}
