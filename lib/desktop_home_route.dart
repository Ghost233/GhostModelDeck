import 'package:flutter/material.dart';

/// Desktop navigation changes panels; only native quit may release the shell.
/// Repeated popup activation must not pop the application underneath the menu.
class DesktopHomeRoute extends MaterialPageRoute<Object?> {
  DesktopHomeRoute({required super.builder, super.settings});

  @override
  // Completing the root route would release its owner on a later popup event.
  // The desktop root intentionally never completes through Navigator.pop.
  // ignore: must_call_super
  bool didPop(Object? result) => false;
}
