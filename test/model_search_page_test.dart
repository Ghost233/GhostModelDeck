import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/hf_model_browser.dart';
import 'package:ghost_model_deck/download_preferences.dart';
import 'package:ghost_model_deck/download_panel.dart';
import 'package:ghost_model_deck/download_tasks_page.dart';
import 'package:ghost_model_deck/settings_page.dart';
import 'package:ghost_model_deck/model_downloader.dart';
import 'package:ghost_model_deck/model_package.dart';
import 'package:ghost_model_deck/model_search_page.dart';

void main() {
  testWidgets('selects a model variant and keeps files in read-only details', (
    tester,
  ) async {
    final fixture = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'research/package',
            'sha': '1234567890abcdef1234567890abcdef12345678',
            'cardData': {'license': 'apache-2.0'},
            'siblings': [
              {'rfilename': 'Model-Q4_K_M.gguf', 'size': 1024},
              {'rfilename': 'Model-Q8_0.gguf', 'size': 2048},
              {'rfilename': 'README.md', 'size': 5},
            ],
          }),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      final browser = HttpOverrides.runWithHttpOverrides(
        () => HfModelBrowser(endpoint: endpoint),
        _NetworkBoundary(),
      );
      final directory = await Directory.systemTemp.createTemp('model-search-');
      return (
        server: server,
        browser: browser,
        downloader: ModelDownloader(hfEndpoint: endpoint),
        directory: directory,
      );
    }))!;
    final browser = fixture.browser;
    final downloader = fixture.downloader;
    addTearDown(() async {
      await tester.runAsync(() async {
        browser.close();
        downloader.close();
        await fixture.server.close(force: true);
        await fixture.directory.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSearchPage(
            browser: browser,
            downloads: DownloadTaskController(
              downloader: downloader,
              preferences: DownloadPreferences(
                file: File('${fixture.directory.path}/preferences.json'),
              ),
            ),
            libraryPath: fixture.directory.path,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('model-search-input')),
      'research/package',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('搜索'));
      if (browser.state.repositoryStatus != RequestStatus.ready) {
        await browser.changes
            .firstWhere(
              (state) => state.repositoryStatus == RequestStatus.ready,
            )
            .timeout(const Duration(seconds: 5));
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('Model-Q4_K_M.gguf'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-variant')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Q8_0').last);
    await tester.pumpAndSettle();

    expect(find.text('2.0 KiB'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('Model-Q8_0.gguf'), findsOneWidget);
    expect(find.text('Model-Q4_K_M.gguf'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets(
    'settings source applies to the selected package and task receipt',
    (tester) async {
      const commit = 'abcdef1234567890abcdef1234567890abcdef12';
      final payloads = {
        'Model-Q4_K_M-00001-of-00002.gguf': List<int>.filled(128, 4),
        'Model-Q4_K_M-00002-of-00002.gguf': List<int>.filled(256, 5),
        'Model-Q8_0-00001-of-00002.gguf': List<int>.filled(512, 8),
        'Model-Q8_0-00002-of-00002.gguf': List<int>.filled(1024, 9),
      };
      final requests = <String>[];
      final fixture = (await tester.runAsync(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path.startsWith('/api/models/')) {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'id': 'research/complete-package',
                'sha': commit,
                'siblings': [
                  for (final file in payloads.entries)
                    {'rfilename': file.key, 'size': file.value.length},
                  {'rfilename': 'README.md', 'size': 5},
                ],
              }),
            );
          } else {
            requests.add(request.uri.path);
            final path = request.uri.pathSegments.last;
            final body = payloads[path];
            if (body == null || !request.uri.pathSegments.contains(commit)) {
              request.response.statusCode = HttpStatus.notFound;
            } else {
              request.response.headers.set(
                HttpHeaders.etagHeader,
                '"fixture-$path"',
              );
              request.response.contentLength = body.length;
              request.response.add(body);
            }
          }
          await request.response.close();
        });
        final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
        final directory = await Directory.systemTemp.createTemp(
          'model-package-ui-',
        );
        final preferences = DownloadPreferences(
          file: File('${directory.path}/preferences.json'),
        );
        final downloader = ModelDownloader(
          hfEndpoint: endpoint,
          lmStudioEndpoint: Uri.parse('${endpoint.toString()}/proxy'),
        );
        return (
          server: server,
          browser: HttpOverrides.runWithHttpOverrides(
            () => HfModelBrowser(endpoint: endpoint),
            _NetworkBoundary(),
          ),
          downloader: downloader,
          directory: directory,
          preferences: preferences,
          downloads: DownloadTaskController(
            downloader: downloader,
            preferences: preferences,
          ),
        );
      }))!;
      addTearDown(() async {
        await tester.runAsync(() async {
          fixture.browser.close();
          fixture.downloader.close();
          fixture.preferences.dispose();
          await fixture.server.close(force: true);
          await fixture.directory.delete(recursive: true);
        });
      });
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              preferences: fixture.preferences,
              libraryPath: fixture.directory.path,
              onLibraryPathChanged: (path) async => path,
              pickLibraryDirectory: () async => null,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<DownloadSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('LM Studio 代理').last);
      await tester.pumpAndSettle();
      // Menu completion runs in the widget clock; filesystem continuations need
      // real I/O turns followed by widget microtask pumps.
      final saveWait = Stopwatch()..start();
      while (fixture.preferences.source != DownloadSource.lmStudio &&
          saveWait.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(fixture.preferences.source, DownloadSource.lmStudio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSearchPage(
              browser: fixture.browser,
              downloads: fixture.downloads,
              libraryPath: fixture.directory.path,
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('model-search-input')),
        'research/complete-package',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('搜索'));
        if (fixture.browser.state.repositoryStatus != RequestStatus.ready) {
          await fixture.browser.changes
              .firstWhere(
                (state) => state.repositoryStatus == RequestStatus.ready,
              )
              .timeout(const Duration(seconds: 5));
        }
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-variant')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Q8_0').last);
      await tester.pumpAndSettle();

      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('下载'));
          if (fixture.downloader.state.isActive) {
            await fixture.downloader.changes
                .firstWhere((state) => !state.isActive)
                .timeout(const Duration(seconds: 10));
          }
        }, _NetworkBoundary()),
      );
      await tester.pumpAndSettle();
      expect(
        fixture.downloader.state.status,
        DownloadStatus.installed,
        reason: fixture.downloader.state.error,
      );
      expect(fixture.downloader.state.revision, commit);
      expect(fixture.downloader.state.downloadedBytes, 1536);
      expect(fixture.downloader.state.source, DownloadSource.lmStudio);
      expect(requests.every((path) => path.startsWith('/proxy/')), isTrue);
      await tester.runAsync(() async {
        final installed = Directory(
          '${fixture.directory.path}/research/complete-package',
        );
        expect(
          (await installed.list().toList()).map(
            (file) => file.path.split('/').last,
          ),
          unorderedEquals([
            'Model-Q8_0-00001-of-00002.gguf',
            'Model-Q8_0-00002-of-00002.gguf',
          ]),
        );
        expect(
          await File('${installed.path}/Model-Q8_0-00001-of-00002.gguf')
              .readAsBytes(),
          List<int>.filled(512, 8),
        );
        expect(
          await File('${installed.path}/Model-Q8_0-00002-of-00002.gguf')
              .readAsBytes(),
          List<int>.filled(1024, 9),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadTasksPage(downloads: fixture.downloads)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('LM Studio 代理'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(
        find.byType(DropdownButtonFormField<DownloadSource>),
        findsNothing,
      );
      expect(find.text('选择目录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clears the old variant while a new revision is pending', (
    tester,
  ) async {
    const originalCommit = '1111111111111111111111111111111111111111';
    const nextCommit = '2222222222222222222222222222222222222222';
    final selections = <ModelPackageSelection?>[];
    final fixture = (await tester.runAsync(() async {
      // Gate completion must use the real I/O zone, not the widget fake clock.
      final receivedRevision = Completer<void>();
      final releaseRevision = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final next = request.uri.pathSegments.last == 'next';
        if (next) {
          receivedRevision.complete();
          await releaseRevision.future;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'research/revision-package',
            'sha': next ? nextCommit : originalCommit,
            'siblings': [
              {'rfilename': 'Model-Q4_K_M.gguf', 'size': 1024},
              if (!next) {'rfilename': 'Model-Q8_0.gguf', 'size': 2048},
            ],
          }),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      return (
        server: server,
        browser: HttpOverrides.runWithHttpOverrides(
          () => HfModelBrowser(endpoint: endpoint),
          _NetworkBoundary(),
        ),
        downloader: ModelDownloader(hfEndpoint: endpoint),
        directory: await Directory.systemTemp.createTemp('model-revision-ui-'),
        receivedRevision: receivedRevision,
        releaseRevision: releaseRevision,
      );
    }))!;
    final receivedRevision = fixture.receivedRevision;
    final releaseRevision = fixture.releaseRevision;
    addTearDown(() async {
      await tester.runAsync(() async {
        if (!releaseRevision.isCompleted) releaseRevision.complete();
        fixture.browser.close();
        fixture.downloader.close();
        await fixture.server.close(force: true);
        await fixture.directory.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(728, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSearchPage(
            browser: fixture.browser,
            downloads: DownloadTaskController(
              downloader: fixture.downloader,
              preferences: DownloadPreferences(
                file: File('${fixture.directory.path}/preferences.json'),
              ),
            ),
            libraryPath: fixture.directory.path,
            onPackageSelected: selections.add,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('model-search-input')),
      'research/revision-package',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('搜索'));
      if (fixture.browser.state.repositoryStatus != RequestStatus.ready) {
        await fixture.browser.changes
            .firstWhere(
              (state) => state.repositoryStatus == RequestStatus.ready,
            )
            .timeout(const Duration(seconds: 5));
      }
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-variant')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Q8_0').last);
    await tester.pumpAndSettle();
    expect(selections.last!.variant.quantization, 'Q8_0');
    expect(selections.last!.modelPackage.repository.revision, originalCommit);
    await tester.tap(find.byTooltip('版本'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('model-revision-input')),
      'next',
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('读取'));
      await receivedRevision.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'HF revision request not observed',
          const Duration(seconds: 5),
        ),
      );
    });
    await tester.pump();
    expect(selections.last, isNull);
    expect(find.textContaining('Q8_0'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '下载'))
          .onPressed,
      isNull,
    );

    await tester.runAsync(() async {
      releaseRevision.complete();
      await fixture.browser.changes
          .firstWhere((state) => state.repositoryStatus == RequestStatus.ready)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw TimeoutException(
              'HF revision response not applied',
              const Duration(seconds: 5),
            ),
          );
    });
    await tester.pumpAndSettle();
    expect(selections.last!.modelPackage.repository.revision, nextCommit);
    expect(selections.last!.variant.quantization, 'Q4_K_M');
    expect(find.textContaining('Q8_0'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '下载'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a model revision when the default branch has no weights', (
    tester,
  ) async {
    const taggedCommit = '3333333333333333333333333333333333333333';
    final selections = <ModelPackageSelection?>[];
    final fixture = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final tagged = request.uri.pathSegments.last == 'release-1';
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'id': 'research/tagged-package',
            'sha': tagged
                ? taggedCommit
                : '1111111111111111111111111111111111111111',
            'siblings': [
              if (tagged) {'rfilename': 'Model-Q8_0.gguf', 'size': 2048},
              {'rfilename': 'README.md', 'size': 5},
            ],
          }),
        );
        await request.response.close();
      });
      final endpoint = Uri.parse('http://127.0.0.1:${server.port}');
      return (
        server: server,
        browser: HttpOverrides.runWithHttpOverrides(
          () => HfModelBrowser(endpoint: endpoint),
          _NetworkBoundary(),
        ),
        downloader: ModelDownloader(hfEndpoint: endpoint),
        directory: await Directory.systemTemp.createTemp('tagged-model-ui-'),
      );
    }))!;
    addTearDown(() async {
      await tester.runAsync(() async {
        fixture.browser.close();
        fixture.downloader.close();
        await fixture.server.close(force: true);
        await fixture.directory.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(728, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSearchPage(
            browser: fixture.browser,
            downloads: DownloadTaskController(
              downloader: fixture.downloader,
              preferences: DownloadPreferences(
                file: File('${fixture.directory.path}/preferences.json'),
              ),
            ),
            libraryPath: fixture.directory.path,
            onPackageSelected: selections.add,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('model-search-input')),
      'research/tagged-package',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('搜索'));
      if (fixture.browser.state.repositoryStatus != RequestStatus.ready) {
        await fixture.browser.changes
            .firstWhere(
              (state) => state.repositoryStatus == RequestStatus.ready,
            )
            .timeout(const Duration(seconds: 5));
      }
    });
    await tester.pumpAndSettle();
    expect(selections.last, isNull);
    await tester.tap(find.byTooltip('版本'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('model-revision-input')),
      'release-1',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('读取'));
      if (fixture.browser.state.repositoryStatus != RequestStatus.ready) {
        await fixture.browser.changes
            .firstWhere(
              (state) => state.repositoryStatus == RequestStatus.ready,
            )
            .timeout(const Duration(seconds: 5));
      }
    });
    await tester.pumpAndSettle();
    expect(selections.last!.modelPackage.repository.revision, taggedCommit);
    expect(
      selections.last!.modelPackage.repository.requestedRevision,
      'release-1',
    );
    expect(selections.last!.variant.quantization, 'Q8_0');
    expect(find.text('GGUF · Q8_0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Only HF network I/O is replaced; the widget and browser are production code.
class _NetworkBoundary extends HttpOverrides {}
