import 'dart:js_interop';

@JS('document.fullscreenElement')
external JSObject? get _fullscreenElement;

// Read browser state rather than assuming Escape passed through Flutter.
bool get browserFullscreenActive => _fullscreenElement != null;
