import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/council_page.dart';
import 'package:ghost_model_deck/jev_models.dart';
import 'package:ghost_model_deck/download_panel.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/download_tasks_page.dart';
import 'package:ghost_model_deck/engine_page.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/local_model_package.dart';
import 'package:ghost_model_deck/main.dart' as app;
import 'package:ghost_model_deck/mcp_page.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_package.dart';
import 'package:ghost_model_deck/model_run_dialog.dart';
import 'package:ghost_model_deck/model_search_page.dart';
import 'package:ghost_model_deck/settings_page.dart';

import 'fixtures/actual_app_environment.dart';
import 'fixtures/council_runtime.dart';
import 'fixtures/test_environment.dart';

const _captureDirectory = String.fromEnvironment('JEV_LAYOUT_SCREENSHOTS');
const _window = Size(900, 560);
const _captureKey = Key('production-layout-capture');
const _repositoryId =
    'research/Long-decision-model-name-for-desktop-layout-GGUF';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var fontLoaded = false;
  setUpAll(() async {
    // Screenshots need readable CJK glyphs instead of flutter_test's Ahem.
    final font = layoutFontFile;
    expect(await font.exists(), isTrue, reason: 'Noto CJK font is required');
    final bytes = ByteData.sublistView(await font.readAsBytes());
    final cjkLoader = FontLoader('Layout Noto CJK')
      ..addFont(Future.value(bytes));
    await cjkLoader.load();
    fontLoaded = true;
    final materialIcons = materialIconsFontFile;
    expect(
      await materialIcons.exists(),
      isTrue,
      reason: 'SDK MaterialIcons font is required',
    );
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(ByteData.sublistView(await materialIcons.readAsBytes())),
      );
    await iconsLoader.load();
    if (_captureDirectory.isNotEmpty) {
      expect(
        fontLoaded,
        isTrue,
        reason: 'Readable screenshot font is required',
      );
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'production shell preserves minimum desktop layout (${brightness.name}-1.5x)',
      (tester) async {
        final environment = await tester.runAsync(ActualAppEnvironment.create);
        addTearDown(environment!.close);
        tester.view.physicalSize = _window;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: _captureKey,
              child: Builder(
                builder: (context) {
                  // Keep the actual public app's home; adapt only test-font families.
                  final production = const app.GhostModelDeckApp().build(
                    context,
                  ) as MaterialApp;
                  return MaterialApp(
                    title: production.title,
                    debugShowCheckedModeBanner: false,
                    theme: _readableTheme(production.theme!),
                    darkTheme: _readableTheme(production.darkTheme!),
                    home: production.home,
                  );
                },
              ),
            ),
          );
          await _settleIo(tester);
        });
        Object? primaryError;
        StackTrace? primaryStack;
        final cleanupErrors = <(Object, StackTrace)>[];
        try {
          _expectVisible(tester, find.text('Ghost Model Deck'));
          _expectVisible(tester, find.text('设置'));
          await tester.scrollUntilVisible(
            find.text('MCP'),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          _expectVisible(tester, find.text('MCP'));
          expect(
            find.ancestor(
              of: find.text('委员会配置'),
              matching: find.byType(Scrollable),
            ),
            findsOneWidget,
          );
          await _capture(
            tester,
            'shell-${brightness.name}-1.5x',
            footer:
                'Production shell | empty container settings | 900 x 560 | ${brightness.name} 1.5x | Noto CJK | Widget fixture, not Mac',
          );
          for (var step = 0; step < 20 && !_focusedNavigation('MCP'); step++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
          }
          expect(
            _focusedNavigation('MCP'),
            isTrue,
            reason: 'Tab must reach the real MCP navigation',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.byType(McpPage), findsOneWidget);
        } catch (error, stack) {
          primaryError = error;
          primaryStack = stack;
        } finally {
          try {
            if (find.byType(McpPage).evaluate().isEmpty) {
              await tester.scrollUntilVisible(
                find.text('MCP'),
                120,
                scrollable: find.byType(Scrollable).first,
              );
              await tester.pumpAndSettle();
              await tester.tap(find.text('MCP').first);
              await tester.pump();
            }
            final server = tester.widget<McpPage>(find.byType(McpPage)).server;
            await tester.runAsync(server.stop);
          } catch (error, stack) {
            cleanupErrors.add((error, stack));
          }
          try {
            await tester.pumpWidget(const SizedBox.shrink());
          } catch (error, stack) {
            cleanupErrors.add((error, stack));
          }
        }
        if (primaryError != null) {
          for (final cleanup in cleanupErrors) {
            stderr.writeln('Layout cleanup also failed: ${cleanup.$1}');
          }
          Error.throwWithStackTrace(primaryError, primaryStack!);
        }
        if (cleanupErrors.isNotEmpty) {
          for (final cleanup in cleanupErrors.skip(1)) {
            stderr.writeln('Additional layout cleanup failure: ${cleanup.$1}');
          }
          Error.throwWithStackTrace(
            cleanupErrors.first.$1,
            cleanupErrors.first.$2,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
    for (final scale in [1.0, 1.5]) {
      final mode = '${brightness.name}-${scale.toStringAsFixed(1)}x';
      for (final page in [
        'search',
        'library',
        'downloads',
        'engines',
        'settings',
        'council',
        'mcp',
        'run-dialog',
      ]) {
        testWidgets('$page preserves minimum desktop layout ($mode)', (
          tester,
        ) async {
          final fixture = (await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(
              _LayoutFixture.create,
              _NetworkBoundary(),
            ),
          ))!;
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(fixture.close);
          });
          tester.view.physicalSize = _window;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final theme = buildJevTheme(brightness);
          final widget = fixture.page(page);
          await tester.runAsync(() async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: _captureKey,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: fontLoaded ? _readableTheme(theme) : theme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Row(
                      children: [
                        // Reserve the production shell's space, not a second UI.
                        SizedBox(
                          width: 188,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'Widget fixture\nContainer renderer\n900 × 560\n'
                              'Content 647 × 502\n$mode\n\n'
                              'Sidebar allocation only\n'
                              'HF / engine I/O fixtures\nNot a Mac screenshot',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(32, 30, 32, 28),
                            child: widget,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await _settleIo(tester);
          });

          if (page == 'run-dialog') {
            final packages = (await tester.runAsync(
              () => LocalModelPackages.discover(
                Directory(fixture.modelPath),
                fixture.runtime.library.state.artifacts,
              ),
            ))!;
            await _openRunDialog(tester, fixture, packages);
            final field = find.byType(DropdownButton<String>);
            expect(
              tester.widget<DropdownButton<String>>(field).items,
              hasLength(2),
            );
            _expectVisible(tester, find.widgetWithText(FilledButton, '运行'));
            _expectVisible(tester, find.widgetWithText(TextButton, '取消'));
            await _capture(tester, '$page-$mode');
            await tester.tap(field);
            await tester.pumpAndSettle();
            // Both real catalog registrations must remain readable in the menu.
            expect(
              find.textContaining('Ghost Model Deck').hitTestable(),
              findsOneWidget,
            );
            expect(find.textContaining('本地关联').hitTestable(), findsOneWidget);
            await _capture(tester, '$page-menu-$mode');
            await tester.tap(find.textContaining('本地关联').last);
            await tester.pumpAndSettle();
            expect(
              tester.widget<DropdownButton<String>>(field).value,
              fixture.runtime.catalog.state.entries.last.id,
            );
            await tester.tap(field);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.textContaining('本地关联').hitTestable(), findsNothing);
            expect(find.text('运行模型'), findsOneWidget);
            await tester.tap(find.widgetWithText(TextButton, '取消'));
            await tester.pumpAndSettle();
            expect(find.text('运行模型'), findsNothing);
            await _openRunDialog(tester, fixture, packages);
            await tester.tap(field);
            await tester.pumpAndSettle();
            await tester.tap(find.textContaining('本地关联').last);
            await tester.pumpAndSettle();
            final processIO = fixture.runtime.io as _LayoutProcessIO;
            processIO.startRequested = Completer<void>();
            processIO.resumeStart = Completer<void>();
            await tester.runAsync(
              () => HttpOverrides.runWithHttpOverrides(() async {
                await tester.tap(find.widgetWithText(FilledButton, '运行'));
                for (
                  var frame = 0;
                  frame < 100 && !processIO.startRequested!.isCompleted;
                  frame++
                ) {
                  await tester.pump();
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                expect(
                  processIO.startRequested!.isCompleted,
                  isTrue,
                  reason: 'The public run action must reach the external process boundary',
                );
              }, _NetworkBoundary()),
            );
            await tester.pump();
            try {
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pump(const Duration(milliseconds: 300));
              expect(find.text('运行模型'), findsOneWidget);
              expect(
                tester
                    .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
                    .onPressed,
                isNull,
              );
              _expectVisible(tester, find.widgetWithText(FilledButton, '启动中'));
              await _capture(tester, '$page-starting-$mode');
            } finally {
              await tester.runAsync(
                () => HttpOverrides.runWithHttpOverrides(() async {
                  final provider = fixture.runtime.catalog.providerFor(
                    fixture.runtime.catalog.state.entries.last.id,
                  );
                  final ready = fixture.runtime.catalog.changes.firstWhere(
                    (_) => provider.state.instances.any(
                      (instance) =>
                          instance.status == LlamaInstanceStatus.ready,
                    ),
                  );
                  processIO.resumeStart!.complete();
                  await _settleIo(tester);
                  await ready.timeout(const Duration(seconds: 5));
                }, _NetworkBoundary()),
              );
            }
            expect(find.text('运行模型'), findsNothing);
            await _openRunDialog(tester, fixture, packages);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.text('运行模型'), findsNothing);
          } else {
            await _capture(tester, '$page-$mode');
            for (final operation in fixture.operations(page)) {
              await tester.ensureVisible(operation);
              await tester.pumpAndSettle();
              _expectVisible(tester, operation);
            }
            if (page == 'settings') {
              await tester.tap(find.byType(DropdownButton<DownloadSource>));
              await tester.pumpAndSettle();
              expect(find.text('HF 直连').last.hitTestable(), findsOneWidget);
              expect(find.text('LM Studio 代理').hitTestable(), findsOneWidget);
              await _capture(tester, '$page-menu-$mode');
              await tester.runAsync(() async {
                await tester.tap(find.text('LM Studio 代理').last);
                await _settleIo(tester);
              });
              expect(
                fixture.downloads.preferences.source,
                DownloadSource.lmStudio,
              );
              await tester.tap(find.byType(DropdownButton<DownloadSource>));
              await tester.pumpAndSettle();
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pumpAndSettle();
              expect(find.text('HF 直连').hitTestable(), findsNothing);
            }
            if (page == 'council') {
              await _capture(tester, '$page-actions-$mode');
              expect(find.text('咨询'), findsNothing);
              expect(find.byKey(const Key('council-context')), findsNothing);
              await tester.ensureVisible(
                find.byKey(const Key('edit-model-layout-council')),
              );
              await tester.tap(
                find.byKey(const Key('edit-model-layout-council')),
              );
              await tester.pumpAndSettle();
              _expectVisible(tester, find.byKey(const Key('jev-model-name')));
              expect(
                tester
                    .widget<TextField>(find.byKey(const Key('jev-model-name')))
                    .controller!
                    .text,
                'layout-council',
              );
              await tester.enterText(
                find.byKey(const Key('jev-model-name')),
                'layout-edited-council',
              );
              await tester.runAsync(
                () => HttpOverrides.runWithHttpOverrides(() async {
                  await tester.tap(find.text('保存'));
                  await _settleIo(tester);
                }, _NetworkBoundary()),
              );
              await tester.pumpAndSettle();
              expect(
                find.byKey(const Key('edit-model-layout-edited-council')),
                findsOneWidget,
              );
              await tester.ensureVisible(find.text('委员会配置'));
              await tester.pumpAndSettle();
              _expectVisible(tester, find.text('委员会配置'));
              await _capture(tester, '$page-configuration-$mode');
            }
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}

void _expectVisible(WidgetTester tester, Finder finder) {
  expect(finder.hitTestable(), findsWidgets);
  final bounds = tester.getRect(finder.first);
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(_window.width));
  expect(bounds.top, greaterThanOrEqualTo(0));
  expect(bounds.bottom, lessThanOrEqualTo(_window.height));
}

bool _focusedNavigation(String label) {
  var focused = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is ListTile &&
        widget.title is Text &&
        (widget.title as Text).data == label) {
      focused = true;
      return false;
    }
    return true;
  });
  return focused;
}

Finder _action(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    )
    .first;

TextStyle? _readableText(TextStyle? style) =>
    style?.copyWith(fontFamily: 'Layout Noto CJK');

ButtonStyle? _readableButton(ButtonStyle? style) => style?.copyWith(
  textStyle: WidgetStatePropertyAll(
    _readableText(style.textStyle?.resolve({})),
  ),
);

ThemeData _readableTheme(ThemeData theme) => theme.copyWith(
  textTheme: theme.textTheme.apply(fontFamily: 'Layout Noto CJK'),
  primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Layout Noto CJK'),
  inputDecorationTheme: theme.inputDecorationTheme.copyWith(
    hintStyle: _readableText(theme.inputDecorationTheme.hintStyle),
    labelStyle: _readableText(theme.inputDecorationTheme.labelStyle),
  ),
  dialogTheme: theme.dialogTheme.copyWith(
    titleTextStyle: _readableText(theme.dialogTheme.titleTextStyle),
    contentTextStyle: _readableText(theme.dialogTheme.contentTextStyle),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: _readableButton(theme.filledButtonTheme.style),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: _readableButton(theme.outlinedButtonTheme.style),
  ),
  textButtonTheme: TextButtonThemeData(
    style: _readableButton(theme.textButtonTheme.style),
  ),
);

Future<void> _openRunDialog(
  WidgetTester tester,
  _LayoutFixture fixture,
  LocalModelPackages packages,
) async {
  await tester.runAsync(() async {
    unawaited(
      showModelRunDialog(
        tester.element(find.byType(LibraryPage)),
        catalog: fixture.runtime.catalog,
        library: fixture.runtime.library,
        modelPackage: packages.packages.first,
        variant: packages.packages.first.variants.first,
      ),
    );
    await _settleIo(tester);
  });
}

Future<void> _settleIo(WidgetTester tester) async {
  // Library/package discovery and catalog refresh use real filesystem Futures.
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await tester.pumpAndSettle();
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  String? footer,
}) async {
  if (_captureDirectory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    var pixels = await boundary.toImage(pixelRatio: 1);
    try {
      if (footer != null) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawImage(pixels, Offset.zero, Paint());
        canvas.drawRect(
          Rect.fromLTWH(
            0,
            pixels.height.toDouble(),
            pixels.width.toDouble(),
            32,
          ),
          Paint()..color = Colors.white,
        );
        final caption = TextPainter(
          text: TextSpan(
            text: footer,
            style: const TextStyle(
              fontFamily: 'Layout Noto CJK',
              fontSize: 12,
              color: Colors.black,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: pixels.width - 16);
        caption.paint(canvas, Offset(8, pixels.height + 6));
        final picture = recorder.endRecording();
        final annotated = await picture.toImage(
          pixels.width,
          pixels.height + 32,
        );
        picture.dispose();
        caption.dispose();
        pixels.dispose();
        pixels = annotated;
      }
      final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_captureDirectory/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      pixels.dispose();
    }
  });
}

class _NetworkBoundary extends HttpOverrides {}

class _LayoutProcessIO extends CouncilRuntimeIO {
  Completer<void>? startRequested;
  Completer<void>? resumeStart;

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    startRequested?.complete();
    await resumeStart?.future;
    return super.start(executable, arguments);
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (executable == '/usr/bin/file') {
      return const EngineCommandResult(0, 'Mach-O 64-bit executable arm64', '');
    }
    if (arguments.singleOrNull == '--help') {
      return const EngineCommandResult(
        0,
        '--model --alias --host --port --ctx-size --batch-size --ubatch-size '
            '--parallel --n-gpu-layers --device',
        '',
      );
    }
    return super.run(executable, arguments, timeout: timeout);
  }
}

class _LayoutFixture {
  _LayoutFixture(
    this.runtime,
    this.server,
    this.browser,
    this.downloads,
    this.council,
    this.mcp,
  );
  final CouncilRuntime runtime;
  final HttpServer server;
  final HfModelBrowser browser;
  final DownloadTaskController downloads;
  final CouncilController council;
  final CouncilMcpServer mcp;
  String get modelPath => '${runtime.root.path}/models';

  static Future<_LayoutFixture> create() async {
    final runtime = await CouncilRuntime.create(processIO: _LayoutProcessIO());
    final linked = File(
      '${runtime.root.path}/linked-external-engine/llama-server',
    );
    await linked.parent.create();
    await File(runtime.engine.executablePath!).copy(linked.path);
    await runtime.catalog.link(linked.path);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.startsWith('/api/models/')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': _repositoryId,
            'sha': '1234567890abcdef1234567890abcdef12345678',
            'cardData': {'license': 'apache-2.0'},
            'siblings': [
              {
                'rfilename': 'Long-decision-model-name-Q4_K_M.gguf',
                'size': 1024,
              },
              {'rfilename': 'Long-decision-model-name-Q8_0.gguf', 'size': 2048},
            ],
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      }
      await request.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
    final browser = HfModelBrowser(endpoint: endpoint);
    await browser.search(_repositoryId);
    final preferences = DownloadPreferences(
      file: File('${runtime.root.path}/preferences.json'),
    );
    final downloads = DownloadTaskController(
      downloader: ModelDownloader(hfEndpoint: endpoint),
      preferences: preferences,
    );
    final repository = browser.state.repository!;
    final package = ModelPackage.discover(repository).single;
    await downloads.start(
      selection: package.selectVariant(package.variants.first.id),
      currentRepository: repository,
      libraryPath:
          '${runtime.root.path}/download-target-with-a-long-directory-name',
    );
    expect(downloads.downloader.state.status, DownloadStatus.failed);
    final council = CouncilController(catalog: runtime.catalog);
    await council.models.save(
      JevModelDefinition.council(
        name: 'layout-council',
        seats: council.models.availableBindings,
        timeout: const Duration(seconds: 3),
      ),
    );
    final mcp = CouncilMcpServer(controller: council, port: 0);
    await mcp.start();
    return _LayoutFixture(runtime, server, browser, downloads, council, mcp);
  }

  Widget page(String page) => switch (page) {
    'search' => ModelSearchPage(
      browser: browser,
      downloads: downloads,
      libraryPath: modelPath,
    ),
    'library' || 'run-dialog' => LibraryPage(
      library: runtime.library,
      libraryPath: modelPath,
      engines: runtime.catalog,
    ),
    'downloads' => DownloadTasksPage(downloads: downloads),
    'engines' => EnginePage(
      catalog: runtime.catalog,
      pickEngineDirectory: () async => null,
    ),
    'settings' => SettingsPage(
      preferences: downloads.preferences,
      libraryPath: '$modelPath/long-path-for-shared-model-library-location',
      onLibraryPathChanged: (path) async => path,
      pickLibraryDirectory: () async => null,
    ),
    'council' => CouncilPage(controller: council, onOpenLibrary: () {}),
    'mcp' => McpPage(server: mcp),
    _ => throw StateError('Unknown production page'),
  };

  List<Finder> operations(String page) => switch (page) {
    'search' => [_action('搜索'), _action('下载')],
    'library' => [_action('核验'), _action('删除模型'), _action('运行')],
    'downloads' => [_action('重试')],
    'engines' => [_action('关联引擎'), _action('解除关联')],
    'settings' => [
      find.byType(DropdownButton<DownloadSource>),
      _action('选择目录'),
    ],
    'council' => [_action('模型库'), _action('创建模型')],
    'mcp' => [_action('停止'), _action('复制 Codex 配置')],
    _ => [],
  };

  Future<void> close() async {
    await mcp.close();
    await council.close();
    browser.close();
    downloads.downloader.close();
    downloads.preferences.dispose();
    await server.close(force: true);
    await runtime.close();
  }
}
