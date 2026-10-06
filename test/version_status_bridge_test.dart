// VersionStatusBridge 映射测试（GhostModelDeck #28）。
//
// 测试纪律：纯 Dart 映射验证，更新检查 seam 注入固定 UpdateCheckResult；
// 不做真实网络访问，不加载模型，不触碰 macOS 原生 API。
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/update_checker.dart';
import 'package:ghost_model_deck/version_status_bridge.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

void main() {
  const current = '0.1.0';
  const sha =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  final dmgUrl = Uri.parse(
    'https://github.com/Ghost233/GhostModelDeck/releases/download/v0.2.0/GhostModelDeck-0.2.0.dmg',
  );

  VersionStatusBridge bridgeWith(
    UpdateCheckResult result, {
    String? Function()? currentVersion,
  }) => VersionStatusBridge(
    currentVersion: currentVersion ?? () => current,
    checkForUpdates: (version) async => result,
  );

  group('VersionStatusBridge 结果映射', () {
    test('UpdateAvailable → success + hasUpdate，sha256 非空原样透传', () async {
      final bridge = bridgeWith(
        UpdateAvailable(
          version: '0.2.0',
          downloadUrl: dmgUrl,
          sizeBytes: 41943040,
          sha256: sha,
        ),
      );
      final status = await bridge.query();
      expect(status.state, VersionQueryState.success);
      expect(status.currentVersion, current);
      expect(status.hasUpdate, isTrue);
      expect(status.latestVersion, '0.2.0');
      expect(status.downloadUrl, dmgUrl.toString());
      expect(status.sha256, sha);
      expect(status.failureReason, isNull);
    });

    test('UpdateAvailable 无 sha256 时该字段保持缺失', () async {
      final bridge = bridgeWith(
        UpdateAvailable(
          version: '0.2.0',
          downloadUrl: dmgUrl,
          sizeBytes: null,
          sha256: null,
        ),
      );
      final status = await bridge.query();
      expect(status.state, VersionQueryState.success);
      expect(status.hasUpdate, isTrue);
      expect(status.sha256, isNull);
    });

    test(
      'UpdateUpToDate → success + hasUpdate: false，latestVersion 取当前版本',
      () async {
        final bridge = bridgeWith(
          const UpdateUpToDate(currentVersion: current, latestVersion: current),
        );
        final status = await bridge.query();
        expect(status.state, VersionQueryState.success);
        expect(status.currentVersion, current);
        expect(status.hasUpdate, isFalse);
        expect(status.latestVersion, current);
        expect(status.downloadUrl, isNull);
        expect(status.sha256, isNull);
      },
    );

    test('UpdateNoReleaseYet → unsupported，如实说明暂无更新渠道', () async {
      final bridge = bridgeWith(const UpdateNoReleaseYet());
      final status = await bridge.query();
      expect(status.state, VersionQueryState.unsupported);
      expect(status.currentVersion, current);
      expect(status.hasUpdate, isNull);
      expect(status.failureReason, contains('尚未发布'));
    });

    test('UpdateCheckFailure → failure 并如实携带原因', () async {
      final bridge = bridgeWith(const UpdateCheckFailure('网络连接失败'));
      final status = await bridge.query();
      expect(status.state, VersionQueryState.failure);
      expect(status.currentVersion, current);
      expect(status.failureReason, '网络连接失败');
      expect(status.hasUpdate, isNull);
    });
  });

  group('VersionStatusBridge 不抛异常兜底', () {
    test('检查 seam 抛异常 → failure，不上抛', () async {
      final bridge = VersionStatusBridge(
        currentVersion: () => current,
        checkForUpdates: (_) async => throw StateError('boom'),
      );
      final status = await bridge.query();
      expect(status.state, VersionQueryState.failure);
      expect(status.failureReason, contains('boom'));
    });

    test('当前版本不可用 → failure，不调用检查 seam', () async {
      var called = false;
      final bridge = VersionStatusBridge(
        currentVersion: () => null,
        checkForUpdates: (_) async {
          called = true;
          return const UpdateNoReleaseYet();
        },
      );
      final status = await bridge.query();
      expect(called, isFalse);
      expect(status.state, VersionQueryState.failure);
      expect(status.failureReason, contains('当前版本不可用'));
    });

    test('当前版本读取本身抛异常 → failure，不上抛', () async {
      final bridge = VersionStatusBridge(
        currentVersion: () => throw StateError('no version'),
        checkForUpdates: (_) async => const UpdateNoReleaseYet(),
      );
      final status = await bridge.query();
      expect(status.state, VersionQueryState.failure);
      expect(status.failureReason, contains('no version'));
    });
  });
}
