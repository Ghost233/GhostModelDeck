import 'dart:io';

/// The host entry validates the fixed tools once. Tests consume its explicit
/// paths and fail clearly on missing inputs instead of dropping layout checks.
File _requiredFile(String name) {
  final path = Platform.environment[name];
  if (path == null || path.isEmpty || !File(path).isAbsolute) {
    throw StateError('Set $name through scripts/test-host.sh prepare');
  }
  final file = File(path);
  if (!file.existsSync()) throw StateError('$name file is missing: $path');
  return file;
}

File get layoutFontFile => _requiredFile('JEV_LAYOUT_FONT');

File get materialIconsFontFile {
  final sdk = Platform.environment['GMD_FLUTTER_SDK'];
  if (sdk == null || sdk.isEmpty || !Directory(sdk).isAbsolute) {
    throw StateError(
      'Set GMD_FLUTTER_SDK through scripts/test-host.sh prepare',
    );
  }
  final file = File(
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!file.existsSync()) {
    throw StateError(
      'The configured SDK MaterialIcons font is missing: ${file.path}',
    );
  }
  return file;
}

String get testPythonExecutable => _requiredFile('GMD_TEST_PYTHON').path;
