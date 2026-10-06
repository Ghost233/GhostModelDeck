import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/software_update_pane.dart';
import 'package:ghost_model_deck/update_checker.dart';
import 'package:ghost_model_deck/update_download_service.dart';

const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final update = UpdateAvailable(
  version: '0.2.0',
  downloadUrl: Uri(
    scheme: 'https',
    host: 'example.invalid',
    path: '/GhostModelDeck-0.2.0.dmg',
  ),
  sizeBytes: 41943040,
  sha256: sha,
);

void main() {
  Future<void> pumpPane(
    WidgetTester tester, {
    SoftwareUpdateConfig? config,
    bool nullConfig = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildJevTheme(Brightness.light),
        home: Scaffold(
          body: SoftwareUpdatePane(config: nullConfig ? null : config),
        ),
      ),
    );
  }

  SoftwareUpdateConfig configWith({
    required Future<UpdateCheckResult> Function() check,
    Future<UpdateDownloadOutcome> Function(
      UpdateAvailable, {
      UpdateProgressCallback? onProgress,
      UpdateInstallConfirmer? confirmBeforeInstall,
    })?
    download,
    void Function()? onCheck,
  }) => SoftwareUpdateConfig(
    currentVersion: '0.1.0',
    checkForUpdates: () {
      onCheck?.call();
      return check();
    },
    downloadUpdate:
        download ??
        (update, {onProgress, confirmBeforeInstall}) async =>
            const UpdateDownloadFailed('不应被调用'),
  );

  testWidgets('shows current version and auto-checks exactly once on open', (
    tester,
  ) async {
    var checks = 0;
    await pumpPane(
      tester,
      config: configWith(
        onCheck: () => checks++,
        check: () async => const UpdateUpToDate(
          currentVersion: '0.1.0',
          latestVersion: '0.1.0',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0.1.0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-state-up-to-date')),
      findsOneWidget,
    );
    expect(find.text('已是最新'), findsOneWidget);
    expect(checks, 1);
  });

  testWidgets('renders 尚未发布正式版 when no release exists', (tester) async {
    await pumpPane(
      tester,
      config: configWith(check: () async => const UpdateNoReleaseYet()),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-state-no-release')),
      findsOneWidget,
    );
    expect(find.text('尚未发布正式版'), findsOneWidget);
  });

  testWidgets('manual 立即检查 re-runs the check', (tester) async {
    var checks = 0;
    await pumpPane(
      tester,
      config: configWith(
        onCheck: () => checks++,
        check: () async => const UpdateNoReleaseYet(),
      ),
    );
    await tester.pumpAndSettle();
    expect(checks, 1);

    await tester.tap(find.byKey(const ValueKey('update-check-now')));
    await tester.pumpAndSettle();
    expect(checks, 2);
    expect(find.text('尚未发布正式版'), findsOneWidget);
  });

  testWidgets('check failure renders the reason', (tester) async {
    await pumpPane(
      tester,
      config: configWith(check: () async => const UpdateCheckFailure('网络不可用')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-state-failed')), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
  });

  testWidgets('available update shows new version, size and download button', (
    tester,
  ) async {
    await pumpPane(tester, config: configWith(check: () async => update));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-state-available')),
      findsOneWidget,
    );
    expect(find.text('有更新'), findsOneWidget);
    expect(find.text('新版本 v0.2.0（40.0 MB）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-download-button')),
      findsOneWidget,
    );
  });

  testWidgets('release without sha256 forbids download', (tester) async {
    await pumpPane(
      tester,
      config: configWith(
        check: () async => UpdateAvailable(
          version: '0.2.0',
          downloadUrl: Uri(scheme: 'https', host: 'example.invalid'),
          sizeBytes: null,
          sha256: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新版本 v0.2.0（大小未知）'), findsOneWidget);
    expect(find.text('该发布缺少校验摘要，无法安全下载。'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-download-button')), findsNothing);
  });

  testWidgets('download shows progress, confirms, then reports saved path', (
    tester,
  ) async {
    UpdateAvailable? received;
    await pumpPane(
      tester,
      config: configWith(
        check: () async => update,
        download: (u, {onProgress, confirmBeforeInstall}) async {
          received = u;
          onProgress?.call(
            const UpdateDownloadProgress(
              receivedBytes: 50,
              totalBytes: 100,
              bytesPerSecond: 25,
            ),
          );
          final ok = await confirmBeforeInstall!(
            const UpdateDownloadReady(
              stagedPath: '/tmp/GhostModelDeck-0.2.0.dmg.part',
              totalBytes: 100,
              sha256Hex: sha,
            ),
          );
          if (!ok) return const UpdateDownloadDeclined();
          return const UpdateDownloadCompleted(
            path: '/Users/x/Downloads/GhostModelDeck-0.2.0.dmg',
            totalBytes: 100,
            sha256Hex: sha,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('update-download-button')));
    await tester.pumpAndSettle();

    // 下载中状态：进度条与百分比/速度文本。
    expect(received?.version, '0.2.0');
    expect(
      find.byKey(const ValueKey('update-download-progress')),
      findsOneWidget,
    );
    expect(find.text('50% · 50 B / 100 B · 25 B/s'), findsOneWidget);

    // 校验通过后的确认对话框。
    expect(find.text('下载完成'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-confirm-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-state-completed')),
      findsOneWidget,
    );
    expect(
      find.text('已保存到 /Users/x/Downloads/GhostModelDeck-0.2.0.dmg 并已打开。'),
      findsOneWidget,
    );
  });

  testWidgets('cancelling the confirmation leaves nothing saved', (
    tester,
  ) async {
    await pumpPane(
      tester,
      config: configWith(
        check: () async => update,
        download: (u, {onProgress, confirmBeforeInstall}) async {
          // 发出一次确定性进度，避免 LinearProgressIndicator 不确定动画
          // 导致 pumpAndSettle 超时。
          onProgress?.call(
            const UpdateDownloadProgress(
              receivedBytes: 100,
              totalBytes: 100,
              bytesPerSecond: 50,
            ),
          );
          final ok = await confirmBeforeInstall!(
            const UpdateDownloadReady(
              stagedPath: '/tmp/x.part',
              totalBytes: 100,
              sha256Hex: sha,
            ),
          );
          return ok
              ? const UpdateDownloadCompleted(
                  path: '/x.dmg',
                  totalBytes: 100,
                  sha256Hex: sha,
                )
              : const UpdateDownloadDeclined();
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-download-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-state-declined')), findsOneWidget);
    expect(find.text('已取消，安装包未保存。'), findsOneWidget);
  });

  testWidgets('integrity failure renders blocked message and never opens', (
    tester,
  ) async {
    await pumpPane(
      tester,
      config: configWith(
        check: () async => update,
        download: (u, {onProgress, confirmBeforeInstall}) async =>
            UpdateDownloadIntegrityFailure(
              expectedSha256: sha,
              actualSha256: 'b' * 64,
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update-download-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-state-integrity-failed')),
      findsOneWidget,
    );
    expect(find.text('更新包校验失败：sha256 不匹配，已阻止打开。'), findsOneWidget);
    expect(find.text('下载完成'), findsNothing); // 未走到确认/打开
  });

  testWidgets('missing config degrades to read-only unavailable state', (
    tester,
  ) async {
    await pumpPane(tester, nullConfig: true);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('update-state-unavailable')),
      findsOneWidget,
    );
    expect(find.text('未知'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('update-check-now')),
    );
    expect(button.onPressed, isNull);
  });
}
