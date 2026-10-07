// LauncherInferenceService 契约测试（GhostModelDeck #18）。
//
// 测试纪律：真实 maclauncher_sdk 客户端 + 真实 loopback/Unix socket；
// 启动器侧协议对等体按 launcher_core server.dart 固定源码语义实现
// （这是本票允许的替身边界）；业务模块（模型库/引擎目录/网关/MCP/配置）
// 全部真实；并发、取消、重连全部用确定性信号等待，不用 sleep 计时。
// 不做真实 .app 拉起，不做原生窗口激活验证（#19 范围）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/council_mcp.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_runtime.dart';
import 'package:ghost_model_deck/app_theme.dart';
import 'package:ghost_model_deck/library_page.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';
import 'package:ghost_model_deck/public_gateway.dart';
import 'package:ghost_model_deck/sdk_service.dart';
import 'package:ghost_model_deck/update_checker.dart';
import 'package:ghost_model_deck/version_status_bridge.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart' as sdk;

import 'fixtures/decision_gguf.dart';
import 'fixtures/engine_archive.dart';

void main() {
  group('LauncherInferenceService 协议握手与状态', () {
    _realNet('hello 载荷与 app 能力声明符合固定契约', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      fixture.service.connect();
      final hello = await fixture.peer.helloAt(0);

      expect(hello['type'], 'hello');
      expect(hello['protocolVersion'], 1);
      expect(hello['projectId'], 'com.ghost233.ghostmodeldeck');
      expect(hello['appSessionId'], isA<String>());
      expect((hello['appSessionId'] as String), isNotEmpty);
      final capabilities = (hello['capabilities'] as Map)
          .cast<String, Object?>();
      final services = (capabilities['services'] as List)
          .map((entry) => (entry as Map).cast<String, Object?>())
          .toList();
      expect(services, hasLength(1));
      expect(services.single['id'], 'inference');
      expect(services.single['name'], '推理服务');
      expect(Set<String>.from(services.single['methods'] as List), {
        'start',
        'recycle',
        'status',
        'logs',
      });
      expect(Set<String>.from(capabilities['app'] as List), {
        'openWindow',
      }, reason: '按契约不声明 onSetEntryManaged');
    });

    _realNet('hello 自报 projectName 与 entry（运行时发现 #30）', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      fixture.service.connect();
      final hello = await fixture.peer.helloAt(0);

      expect(hello['projectName'], 'GhostModelDeck');
      final entry = (hello['entry'] as Map).cast<String, Object?>();
      expect(
        entry['kind'],
        isIn(['app', 'executable']),
        reason: '开发期非 bundle 运行退回 executable，打包运行为 app',
      );
      expect(entry['path'], isA<String>());
      expect((entry['path'] as String), isNotEmpty);
    });

    _realNet('注册 onVersionStatus 后声明能力并按桥映射如实应答（#28）', () async {
      const sha =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final bridge = VersionStatusBridge(
        currentVersion: () => '0.1.0',
        checkForUpdates: (_) async => UpdateAvailable(
          version: '0.2.0',
          downloadUrl: Uri.parse(
            'https://github.com/Ghost233/GhostModelDeck/releases/download/v0.2.0/GhostModelDeck-0.2.0.dmg',
          ),
          sizeBytes: 41943040,
          sha256: sha,
        ),
      );
      final fixture = await _SdkFixture.create(onVersionStatus: bridge.query);
      addTearDown(fixture.close);
      fixture.service.connect();
      final hello = await fixture.peer.helloAt(0);
      final capabilities = (hello['capabilities'] as Map)
          .cast<String, Object?>();
      expect(Set<String>.from(capabilities['app'] as List), {
        'openWindow',
        'versionStatus',
      }, reason: '注册回调即声明版本状况能力');

      final answer = await fixture.peer.call('versionStatus', serviceId: null);
      final result = (answer['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'success');
      expect(result['currentVersion'], '0.1.0');
      expect(result['hasUpdate'], isTrue);
      expect(result['latestVersion'], '0.2.0');
      expect(
        result['downloadUrl'],
        'https://github.com/Ghost233/GhostModelDeck/releases/download/v0.2.0/GhostModelDeck-0.2.0.dmg',
      );
      expect(result['sha256'], sha, reason: 'sha256 非空原样透传');
      expect(result['failureReason'], isNull);
    });

    _realNet('未注册 onVersionStatus 时 SDK 自动应答 unsupported 而非错误（#28）', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();
      final answer = await fixture.peer.call('versionStatus', serviceId: null);
      final result = (answer['result'] as Map).cast<String, Object?>();
      expect(answer['error'], isNull, reason: '未注册回调不是协议错误');
      expect(result['state'], 'unsupported');
    });

    _realNet('onVersionStatus 回调抛异常由 SDK 兜底为 failure 应答（#28）', () async {
      Future<sdk.VersionStatus> throwing() async =>
          throw StateError('query exploded');
      final fixture = await _SdkFixture.create(onVersionStatus: throwing);
      addTearDown(fixture.close);
      await fixture.connect();
      final answer = await fixture.peer.call('versionStatus', serviceId: null);
      final result = (answer['result'] as Map).cast<String, Object?>();
      expect(answer['error'], isNull, reason: '回调异常不是协议错误');
      expect(result['state'], 'failure');
      expect(result['failureReason'] as String, contains('query exploded'));
    });

    _realNet('onOpenWindow 缺 seam 时真实失败不虚报成功', () async {
      final fixture = await _SdkFixture.create(openWindowSeam: false);
      addTearDown(fixture.close);
      await fixture.connect();
      final error = await fixture.peer.callError('openWindow', serviceId: null);
      expect(error['code'], 'failed');
      expect(error['message'] as String, contains('窗口激活 seam 未配置'));
    });

    _realNet('openWindow 成功时触发注入的窗口 seam 并留日志', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();
      final result = await fixture.peer.call('openWindow', serviceId: null);
      expect(result['result'], isA<Map>());
      expect(fixture.openWindowCalls, 1);

      final logs = await fixture.peer.call('logs', params: {'limit': 500});
      final entries = _logEntries(logs);
      expect(
        entries.any(
          (entry) => (entry['text'] as String).contains('启动器请求激活主窗口'),
        ),
        isTrue,
      );
    });

    _realNet('stopped 状态下 status 为真实快照（状态机映射与 UTC observedAt）', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();
      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'stopped');
      expect(result['instanceId'], isNull);
      expect(result['ready'], isNull);
      expect(result['message'], isNull);
      expect(result['observedAt'], isA<String>());
      final observedAt = DateTime.parse(result['observedAt'] as String);
      expect(observedAt.isUtc, isTrue);
      expect(
        DateTime.now().toUtc().difference(observedAt).abs().inSeconds,
        lessThan(10),
      );
    });
  });

  group('LauncherInferenceService 启动受理', () {
    _realNet('空启动集合：受理=开网关+MCP，ready 为真实 false', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();

      final start = await fixture.peer.call('start');
      expect(start['result'], isA<Map>());
      expect(fixture.service.state, LauncherServiceState.running);
      expect(fixture.gateway.state, PublicGatewayState.running);
      expect(fixture.mcp.state.status, CouncilMcpStatus.running);
      expect(fixture.engine.runtimeInstances, isEmpty, reason: '受理不偷载模型');

      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['instanceId'], isA<String>());
      expect((result['instanceId'] as String), startsWith('run-'));
      expect(result['ready'], isFalse);
      expect(result['message'] as String, contains('启动模型集合为空'));

      // 网关真实可用：直接请求公开 API。
      final baseUrl = fixture.gateway.baseUrl;
      expect(baseUrl, isNotNull);
      final response = await _get('$baseUrl/v1/models');
      expect(response.status, 200);
      expect(response.body, contains('"data"'));
    });

    _realNet('真实加载启动集合模型：真进程拉起、ready 为真、重复 start 幂等', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      await fixture.peer.call('start');
      expect(fixture.io.startCount, 1);
      final live = fixture.liveInstances;
      expect(live, hasLength(1));
      expect(live.single.artifactId, fixture.asset.id);
      expect(live.single.status, RuntimeInstanceStatus.ready);

      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['ready'], isTrue);
      expect(result['message'], isNull);
      final firstInstanceId = result['instanceId'] as String;

      // 重复 start（新 id）：保留 instanceId，复用已运行实例，不再拉进程。
      await fixture.peer.call('start');
      expect(fixture.io.startCount, 1);
      expect(fixture.liveInstances, hasLength(1));
      final second = await fixture.peer.call('status');
      expect(
        ((second['result'] as Map).cast<String, Object?>())['instanceId'],
        firstInstanceId,
      );
    });

    _realNet('启动集合缺失条目只记日志，其余条目照常受理', () async {
      final fixture = await _SdkFixture.create(
        useAssetEntry: true,
        extraMissingEntry: true,
      );
      addTearDown(fixture.close);
      await fixture.connect();

      await fixture.peer.call('start');
      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['ready'], isFalse);
      expect(result['message'] as String, contains('模型未运行：missing-artifact'));
      expect(fixture.liveInstances, hasLength(1), reason: '真实条目照常加载');

      final logs = await fixture.peer.call('logs', params: {'limit': 500});
      final entries = _logEntries(logs);
      expect(
        entries.any(
          (entry) =>
              (entry['text'] as String).contains('启动集合模型缺失') &&
              (entry['text'] as String).contains('missing-artifact'),
        ),
        isTrue,
      );
    });

    _realNet('启动集合配置损坏时 start 真实失败，不静默跳过', () async {
      final fixture = await _SdkFixture.create(corruptStartupSet: true);
      addTearDown(fixture.close);
      await fixture.connect();

      final error = await fixture.peer.callError('start');
      expect(error['code'], 'failed');
      expect(error['message'] as String, contains('启动模型集合配置版本不受支持'));
      expect(fixture.service.state, LauncherServiceState.failed);
      expect(fixture.gateway.state, PublicGatewayState.stopped);

      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'failed');
      expect(result['message'] as String, contains('启动模型集合配置版本不受支持'));
    });

    _realNet('反复 start/recycle 幂等且无泄漏', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      await fixture.peer.call('start');
      await fixture.peer.call('start');
      await fixture.peer.call('recycle');
      await fixture.peer.call('recycle');
      expect(fixture.service.state, LauncherServiceState.stopped);
      await fixture.peer.call('start');
      expect(fixture.service.state, LauncherServiceState.running);
      expect(fixture.liveInstances, hasLength(1));
      expect(fixture.io.startCount, 2);
      final status = await fixture.peer.call('status');
      expect(
        ((status['result'] as Map).cast<String, Object?>())['ready'],
        isTrue,
      );
    });
  });

  group('LauncherInferenceService 回收', () {
    _realNet('按序完整回收：引擎真停、MCP 真停、网关封停，状态真实回落', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      await fixture.peer.call('start');
      expect(fixture.liveInstances, hasLength(1));
      final liveModelsUrl = '${fixture.gateway.baseUrl}/v1/models';

      final recycle = await fixture.peer.call('recycle');
      expect(recycle['result'], isA<Map>());
      expect(
        fixture.events.where((event) => event == 'engine-killed'),
        hasLength(1),
      );
      expect(fixture.liveInstances, isEmpty);
      expect(fixture.mcp.state.status, CouncilMcpStatus.stopped);
      expect(fixture.gateway.state, PublicGatewayState.stopped);
      expect(fixture.events, contains('gateway-stopped'));
      expect(fixture.service.state, LauncherServiceState.stopped);

      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'stopped');
      expect(result['instanceId'], isNull);

      // 回收后公开 API 真实拒绝连接（旧端口监听已关闭）。
      expect(fixture.gateway.baseUrl, isNull);
      await expectLater(_get(liveModelsUrl), throwsA(isA<SocketException>()));
    });

    _realNet('回收后配置与连接保留，可再次完整启动', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      await fixture.peer.call('start');
      final firstInstanceId =
          ((await fixture.peer.call('status'))['result'] as Map)['instanceId'];
      await fixture.peer.call('recycle');
      expect(fixture.startupSet.entries, hasLength(1), reason: '配置保留');

      await fixture.peer.call('start');
      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['ready'], isTrue);
      expect(result['instanceId'], isA<String>());
      expect(
        result['instanceId'],
        isNot(firstInstanceId),
        reason: '新一轮换 instanceId',
      );
      expect(fixture.gateway.state, PublicGatewayState.running);
      expect(fixture.mcp.state.status, CouncilMcpStatus.running);
      expect(fixture.liveInstances, hasLength(1));
      expect(fixture.io.startCount, 2);
    });
  });

  group('LauncherInferenceService 请求互斥与按 id 去重', () {
    _realNet('start 在途时 recycle 收到 busy，不抢占', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      final gate = Completer<void>();
      fixture.io.startGate = gate.future;
      final startFuture = fixture.peer.call('start');
      await fixture.io.waitForStartEntered();

      final busy = await fixture.peer.callError('recycle');
      expect(busy['code'], 'busy');
      expect(busy['message'] as String, contains('service busy: inference'));

      gate.complete();
      await startFuture;
      expect(fixture.liveInstances, hasLength(1));
    });

    _realNet('completed 响应按 id 重放：回调绝不执行两次', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();

      // 空集合下的 start 已 completed；把模型加入集合后以同 id 重放：
      // 不得再次执行回调（否则会把模型拉起来）。
      final first = await fixture.peer.call('start', id: 'D1');
      await fixture.startupSet.add(EngineCatalog.officialId, fixture.asset.id);
      final replay = await fixture.peer.call('start', id: 'D1');
      expect(replay['result'], equals(first['result']));
      expect(fixture.io.startCount, 0, reason: '重放不得重跑 start 回调');

      // status completed 重放：两次响应逐字节一致（observedAt 相同）。
      final statusA = await fixture.peer.call('status', id: 'S1');
      final statusB = await fixture.peer.call('status', id: 'S1');
      expect(jsonEncode(statusB), jsonEncode(statusA));

      // 新 id 才是真正的新请求：模型真实加载。
      await fixture.peer.call('start', id: 'D2');
      expect(fixture.liveInstances, hasLength(1));
    });

    _realNet('协议负路径：未知方法/缺 serviceId/未知服务/非法结构返回真实错误', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();

      var error = await fixture.peer.callError('bogus');
      expect(error['code'], 'unsupported');
      expect(error['message'], 'unknown method: bogus');

      error = await fixture.peer.callError('status', serviceId: null);
      expect(error['code'], 'invalid');
      expect(error['message'], 'missing serviceId');

      error = await fixture.peer.callError('status', serviceId: 'nope');
      expect(error['code'], 'unsupported');
      expect(error['message'], 'unknown service: nope');

      // 结构非法（无 id）：响应 id 为 null 且不进入去重。
      fixture.peer.sendRaw({
        'type': 'request',
        'serviceId': 'inference',
        'method': 'status',
      });
      final malformed = await fixture.peer.waitFor(() {
        for (final response in fixture.peer.responses) {
          if (response['id'] == null && response['error'] != null) {
            return response;
          }
        }
        return null;
      }, what: 'malformed request response');
      expect((malformed['error'] as Map)['code'], 'invalid');
      expect(
        (malformed['error'] as Map)['message'],
        'invalid request structure',
      );
    });

    _realNet('logs：真实批次旧→新、limit 语义与未知字段容忍', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();
      await fixture.peer.call('start');

      final full = await fixture.peer.call('logs', params: {'limit': 500});
      final result = (full['result'] as Map).cast<String, Object?>();
      expect(result['instanceId'], isA<String>());
      expect(result['truncated'], isFalse);
      expect(result['observedAt'], isA<String>());
      final entries = _logEntries(full);
      expect(entries.length, greaterThanOrEqualTo(3));
      for (final entry in entries) {
        expect(entry['stream'], 'app');
        expect(entry['timestamp'], isA<String>());
      }
      final texts = entries.map((entry) => entry['text'] as String).toList();
      final accepted = texts.indexWhere((text) => text.contains('推理服务启动受理'));
      final gatewayUp = texts.indexWhere(
        (text) => text.contains('公开 API：running'),
      );
      final mcpUp = texts.indexWhere(
        (text) => text.contains('JEV MCP：running'),
      );
      expect(accepted, greaterThanOrEqualTo(0));
      expect(gatewayUp, greaterThan(accepted));
      expect(mcpUp, greaterThan(gatewayUp), reason: '日志顺序必须旧→新');

      final limited = await fixture.peer.call('logs', params: {'limit': 2});
      final limitedResult = (limited['result'] as Map).cast<String, Object?>();
      final limitedEntries = _logEntries(limited);
      expect(limitedEntries, hasLength(2));
      expect(limitedResult['truncated'], isTrue);
      expect(
        limitedEntries.map((entry) => entry['text']).toList(),
        texts.sublist(texts.length - 2),
      );

      // 未知字段不伪造不报错；limit 非 int 落回默认 200。
      final tolerant = await fixture.peer.call(
        'logs',
        params: {'limit': 3, 'mystery': true},
      );
      expect(_logEntries(tolerant), hasLength(3));
      final defaulted = await fixture.peer.call(
        'logs',
        params: {'limit': 'abc'},
      );
      expect(_logEntries(defaulted).length, entries.length);
    });
  });

  group('LauncherInferenceService 断连与重连纪律', () {
    _realNet('拒绝连接后按正常节奏重试，不 hammer', () async {
      final fixture = await _SdkFixture.create(
        acceptHellos: false,
        rejectReason: 'conflict',
      );
      addTearDown(fixture.close);
      fixture.service.connect();
      await fixture.peer.helloAt(0);
      await fixture.peer.helloAt(1, timeout: const Duration(seconds: 15));
      final gap = fixture.peer.helloTimes[1].difference(
        fixture.peer.helloTimes[0],
      );
      expect(gap, greaterThanOrEqualTo(const Duration(seconds: 4)));

      fixture.peer.acceptHellos = true;
      await fixture.peer.helloAt(2, timeout: const Duration(seconds: 15));
      final status = await fixture.peer.call('status');
      expect(
        ((status['result'] as Map).cast<String, Object?>())['state'],
        'stopped',
      );
      expect(
        fixture.gateway.state,
        PublicGatewayState.stopped,
        reason: '重连不得触碰业务',
      );
    });

    _realNet('pending-approval 只公告一次、不刷错误日志，批准后正常连接（#30）', () async {
      final fixture = await _SdkFixture.create(
        acceptHellos: false,
        rejectReason: sdk.kRejectReasonPendingApproval,
      );
      addTearDown(fixture.close);
      fixture.service.connect();
      await fixture.peer.helloAt(0);
      await fixture.peer.helloAt(1, timeout: const Duration(seconds: 15));

      fixture.peer.acceptHellos = true;
      await fixture.peer.helloAt(2, timeout: const Duration(seconds: 15));
      // states 流为异步投递：logs 应答可能先于 connected 日志落库，按条件
      // 轮询到连接成功日志出现再断言（带截止时间，不赌固定延时）。
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      List<String> texts;
      for (;;) {
        final logs = await fixture.peer.call('logs', params: {'limit': 500});
        texts = _logEntries(logs)
            .map((entry) => entry['text'] as String)
            .toList();
        if (texts.any((text) => text.contains('启动器连接：connected'))) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for 启动器连接：connected log entry');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(
        texts.where((text) => text.contains('待批准')),
        hasLength(1),
        reason: '待批准期间只公告一次，SDK 重试不重复刷日志',
      );
      expect(
        texts.where((text) => text.contains('pending-approval')),
        isEmpty,
        reason: 'pending-approval 不以拒绝原因原文作为错误呈现',
      );
      expect(
        texts.where((text) => text.contains('启动器连接：connected')),
        isNotEmpty,
        reason: '用户批准后正常记录连接成功',
      );
    });

    _realNet('断连不回收业务；重连后继续受理；第二连接被拒冲突且不抢占', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();
      await fixture.peer.call('start');
      expect(fixture.liveInstances, hasLength(1));

      fixture.peer.dropConnections();
      await fixture.peer.waitFor(
        () => fixture.peer.drops > 0 ? true : null,
        what: 'SDK 断连信号',
      );
      expect(
        fixture.events.where((event) => event == 'sdk-drop'),
        hasLength(1),
      );
      expect(fixture.liveInstances, hasLength(1), reason: '断连绝不回收业务');
      expect(fixture.gateway.state, PublicGatewayState.running);

      // 未经回收，业务原样恢复受理。
      await fixture.peer.helloAt(1, timeout: const Duration(seconds: 15));
      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['ready'], isTrue);
      expect(fixture.liveInstances, hasLength(1));
      expect(fixture.io.startCount, 1, reason: '重连不得重复拉起模型');

      // 第二连接冲突：incumbent 不被抢占。
      fixture.peer.acceptHellos = false;
      fixture.peer.rejectReason = 'conflict';
      final second = sdk.MacLauncherSdk.connect(
        projectId: 'com.ghost233.ghostmodeldeck',
        services: const {},
        socketPath: fixture.peer.path,
        retryInterval: const Duration(milliseconds: 500),
      );
      final states = <sdk.SdkConnectionStatus>[];
      final subscription = second.states.listen(states.add);
      try {
        await fixture.peer.helloAt(2, timeout: const Duration(seconds: 10));
        await _waitForCondition(
          () => states.any(
            (status) => status.state == sdk.SdkConnectionState.rejected,
          ),
          what: '第二连接 rejected 状态',
        );
        final rejected = states.firstWhere(
          (status) => status.state == sdk.SdkConnectionState.rejected,
        );
        expect(rejected.reason, 'conflict');
        final first = await fixture.peer.call('status');
        expect(
          ((first['result'] as Map).cast<String, Object?>())['state'],
          'running',
          reason: 'incumbent 连接不被抢占',
        );
      } finally {
        await subscription.cancel();
        await second.dispose();
      }
    });

    _realNet('launcher 崩溃（socket 消失）按断连纪律处理，可再连新实例', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();
      await fixture.peer.call('start');
      expect(fixture.liveInstances, hasLength(1));

      // 对等体整体关闭（模拟启动器崩溃）：SDK 看到 EOF 后按重连纪律处理。
      await fixture.peer.close();
      expect(fixture.liveInstances, hasLength(1), reason: '启动器崩溃不回收业务');
      expect(fixture.gateway.state, PublicGatewayState.running);

      final peer2 = await _LauncherPeer.bind(fixture.peer.path);
      fixture.replacePeer(peer2);
      await peer2.helloAt(0, timeout: const Duration(seconds: 20));
      final status = await peer2.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['ready'], isTrue);
      expect(fixture.liveInstances, hasLength(1));
    });

    _realNet('SDK 真实 ping/pong 保活由对等体应答', () async {
      final fixture = await _SdkFixture.create();
      addTearDown(fixture.close);
      await fixture.connect();
      await fixture.peer.waitFor(
        () => fixture.peer.pings > 0 ? true : null,
        what: 'SDK ping',
        timeout: const Duration(seconds: 15),
      );
      expect(fixture.peer.lastPing, isNotNull);
      expect(fixture.peer.lastPing!['type'], 'ping');
      expect(fixture.peer.lastPing!['sentAt'], isA<String>());
      expect(
        () => DateTime.parse(fixture.peer.lastPing!['sentAt'] as String),
        returnsNormally,
      );
      expect(fixture.peer.pongs, fixture.peer.pings);
      final status = await fixture.peer.call('status');
      expect(
        ((status['result'] as Map).cast<String, Object?>())['state'],
        'stopped',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    _realNet('pong 超时（启动器无响应）后 SDK 真实断连并自动重连', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      fixture.peer.answerPings = false;
      await fixture.connect();
      await fixture.peer.call('start');
      expect(fixture.liveInstances, hasLength(1));

      // SDK 在 15s 无 pong 后 destroy socket（确定性：等断连信号，不计时）。
      await fixture.peer.waitFor(
        () => fixture.peer.drops > 0 ? true : null,
        what: 'pong 超时断连',
        timeout: const Duration(seconds: 40),
      );
      expect(fixture.liveInstances, hasLength(1), reason: '断连不回收业务');

      fixture.peer.answerPings = true;
      await fixture.peer.helloAt(1, timeout: const Duration(seconds: 30));
      final status = await fixture.peer.call('status');
      final result = (status['result'] as Map).cast<String, Object?>();
      expect(result['state'], 'running');
      expect(result['ready'], isTrue);
      expect(fixture.liveInstances, hasLength(1));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('LauncherInferenceService dispose 纪律', () {
    _realNet('dispose 断开 SDK 但绝不触碰业务；幂等；之后 connect 抛错', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      var fixtureTornDown = false;
      addTearDown(() async {
        if (!fixtureTornDown) {
          fixtureTornDown = true;
          await fixture.close();
        }
      });
      await fixture.connect();
      await fixture.peer.call('start');
      expect(fixture.liveInstances, hasLength(1));

      await fixture.service.dispose();
      await fixture.service.dispose();
      await fixture.peer.waitFor(
        () => fixture.peer.drops > 0 ? true : null,
        what: 'dispose 后 SDK 断连',
      );
      expect(fixture.liveInstances, hasLength(1), reason: 'dispose 不回收业务');
      expect(fixture.gateway.state, PublicGatewayState.running);
      expect(fixture.mcp.state.status, CouncilMcpStatus.running);
      expect(() => fixture.service.connect(), throwsStateError);

      // 业务仍可被应用自身收尾（退出路径的确定性演示）。
      await fixture.catalog.stopManaged();
      await fixture.mcp.stop();
      await fixture.gateway.stop();
      expect(fixture.liveInstances, isEmpty);
      expect(fixture.gateway.state, PublicGatewayState.stopped);
    });

    _realNet('dispose 与在途 start 竞态：回调绝不执行两次，服务不复活', () async {
      final fixture = await _SdkFixture.create(useAssetEntry: true);
      addTearDown(fixture.close);
      await fixture.connect();

      final gate = Completer<void>();
      fixture.io.startGate = gate.future;
      final first = fixture.peer.call(
        'start',
        id: 'race',
        timeout: const Duration(seconds: 10),
      );
      await fixture.io.waitForStartEntered();
      // in-flight dedup：同 id 复用同一在途回调，绝不重入执行。
      final duplicate = fixture.peer.call(
        'start',
        id: 'race',
        timeout: const Duration(seconds: 10),
      );
      await fixture.service.dispose();
      gate.complete();
      // 回调完成后连接已销毁，响应按固定语义不写出：两侧超时属预期。
      await expectLater(first, throwsA(isA<TimeoutException>()));
      await expectLater(duplicate, throwsA(isA<TimeoutException>()));
      expect(fixture.io.startCount, 1, reason: 'start 回调只执行一次');
      expect(fixture.liveInstances, hasLength(1), reason: 'dispose 不打断在途业务');
      expect(() => fixture.service.connect(), throwsStateError);
    });
  });

  group('StartupModelSet 持久化', () {
    _realNet('schema/增删/坏结构真实报错，不静默吞掉', () async {
      final root = await Directory.systemTemp.createTemp('gmd-startup-set-');
      addTearDown(() => root.delete(recursive: true));
      final set = StartupModelSet(
        file: File('${root.path}/startup-models.json'),
      );
      await set.load();
      expect(set.entries, isEmpty);

      await set.add('engine-a', 'artifact-a');
      await set.add('engine-a', 'artifact-a');
      expect(set.entries, hasLength(1), reason: '去重');
      expect(set.contains('engine-a', 'artifact-a'), isTrue);
      final saved = (jsonDecode(await set.file.readAsString()) as Map)
          .cast<String, Object?>();
      expect(saved['schema'], 1);
      expect((saved['entries'] as List).single, {
        'engine': 'engine-a',
        'artifact': 'artifact-a',
      });

      await set.remove('engine-a', 'artifact-a');
      expect(set.entries, isEmpty);

      await set.file.writeAsString(jsonEncode({'schema': 2, 'entries': []}));
      final bad = StartupModelSet(file: set.file);
      expect(() => bad.load(), throwsFormatException);

      await set.file.writeAsString(
        jsonEncode({'schema': 1, 'entries': 'nope'}),
      );
      final bad2 = StartupModelSet(file: set.file);
      expect(() => bad2.load(), throwsFormatException);

      await set.file.writeAsString(
        jsonEncode({
          'schema': 1,
          'entries': [
            {'engine': 'engine-a'},
          ],
        }),
      );
      final bad3 = StartupModelSet(file: set.file);
      expect(() => bad3.load(), throwsFormatException);
    });
  });

  group('模型库页启动模型集合开关', () {
    testWidgets(
      '运行行上显式切换启动模型集合并持久化',
      (tester) => HttpOverrides.runWithHttpOverrides(() async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final created = await tester.runAsync(() => _SdkFixture.create());
        expect(created, isNotNull);
        final fixture = created!;
        addTearDown(() async {
          await tester.runAsync(() => fixture.close());
        });
        await tester.runAsync(() => fixture.engine.start(fixture.asset.id));

        Future<void> pumpPage({required bool withSet}) => tester.pumpWidget(
          MaterialApp(
            theme: buildJevTheme(Brightness.light),
            home: Scaffold(
              body: LibraryPage(
                library: fixture.library,
                libraryPath: fixture.models.path,
                engines: fixture.catalog,
                startupSet: withSet ? fixture.startupSet : null,
              ),
            ),
          ),
        );

        Future<void> pumpUntil(bool Function() ready) async {
          for (var n = 0; n < 100; n++) {
            await tester.pump();
            if (ready()) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }

        await tester.runAsync(() async {
          await pumpPage(withSet: true);
          await pumpUntil(
            () =>
                find.byIcon(Icons.rocket_launch_outlined).evaluate().isNotEmpty,
          );
        });
        expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);

        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.rocket_launch_outlined));
          await pumpUntil(
            () => find.byIcon(Icons.rocket_launch).evaluate().isNotEmpty,
          );
        });
        expect(
          fixture.startupSet.contains(
            EngineCatalog.officialId,
            fixture.asset.id,
          ),
          isTrue,
        );
        expect(find.byIcon(Icons.rocket_launch), findsOneWidget);
        final saved = await tester.runAsync(() async {
          return (jsonDecode(
            await fixture.startupSet.file.readAsString(),
          ) as Map).cast<String, Object?>();
        });
        expect(saved, isNotNull);
        expect(saved!['schema'], 1);
        expect((saved['entries'] as List).single, {
          'engine': EngineCatalog.officialId,
          'artifact': fixture.asset.id,
        });

        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.rocket_launch));
          await pumpUntil(
            () =>
                find.byIcon(Icons.rocket_launch_outlined).evaluate().isNotEmpty,
          );
        });
        expect(
          fixture.startupSet.contains(
            EngineCatalog.officialId,
            fixture.asset.id,
          ),
          isFalse,
        );
        expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);

        await tester.runAsync(() async {
          await pumpPage(withSet: false);
          await pumpUntil(() => find.text('运行中').evaluate().isNotEmpty);
        });
        expect(find.byIcon(Icons.rocket_launch), findsNothing);
        expect(find.byIcon(Icons.rocket_launch_outlined), findsNothing);
      }, _NetworkBoundary()),
    );
  });
}

List<Map<String, Object?>> _logEntries(Map<String, Object?> response) {
  final result = (response['result'] as Map).cast<String, Object?>();
  return (result['entries'] as List)
      .map((entry) => (entry as Map).cast<String, Object?>())
      .toList();
}

Future<({int status, String body})> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close();
  }
}

Future<void> _waitForCondition(
  bool Function() probe, {
  required String what,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!probe()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 按 launcher_core server.dart 固定源码语义实现的启动器协议对等体：
/// 行分隔 UTF-8 JSON 帧、hello 校验与 welcome、ping→pong、
/// request/response 按 id 配对。这是本票允许的替身边界。
class _LauncherPeer {
  _LauncherPeer._(this._server, this.path);

  final ServerSocket _server;
  final String path;
  final hellos = <Map<String, Object?>>[];
  final helloTimes = <DateTime>[];
  final responses = <Map<String, Object?>>[];
  final connections = <_PeerConnection>[];
  bool acceptHellos = true;
  String rejectReason = 'conflict';
  bool answerPings = true;
  int pings = 0;
  int pongs = 0;
  int drops = 0;
  Map<String, Object?>? lastPing;
  void Function()? onDrop;

  var _wake = Completer<void>();
  int _sessionCounter = 0;
  int _requestCounter = 0;
  final _pending = <String, Completer<Map<String, Object?>>>{};
  _PeerConnection? _active;

  static Future<_LauncherPeer> bind(String path) async {
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final peer = _LauncherPeer._(server, path);
    server.listen(peer._acceptConnection);
    return peer;
  }

  void _acceptConnection(Socket socket) {
    final connection = _PeerConnection(this, socket);
    connections.add(connection);
    _signal();
  }

  void _signal() {
    final wake = _wake;
    _wake = Completer<void>();
    if (!wake.isCompleted) {
      wake.complete();
    }
  }

  Future<T> waitFor<T>(
    T? Function() probe, {
    required String what,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      final value = probe();
      if (value != null) {
        return value;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        fail('timed out waiting for $what');
      }
      final wake = _wake.future;
      final again = probe();
      if (again != null) {
        return again;
      }
      await wake.timeout(
        remaining,
        onTimeout: () {
          fail('timed out waiting for $what');
        },
      );
    }
  }

  Future<Map<String, Object?>> helloAt(
    int index, {
    Duration timeout = const Duration(seconds: 15),
  }) => waitFor(
    () => hellos.length > index ? hellos[index] : null,
    what: 'hello #$index',
    timeout: timeout,
  );

  Future<Map<String, Object?>> call(
    String method, {
    String? serviceId = 'inference',
    Map<String, Object?>? params,
    String? id,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final connection = _active;
    if (connection == null) {
      throw StateError('no accepted SDK connection');
    }
    final requestId = id ?? 'test-r${++_requestCounter}';
    final completer = Completer<Map<String, Object?>>();
    _pending[requestId] = completer;
    connection.send({
      'type': 'request',
      'id': requestId,
      'serviceId': ?serviceId,
      'method': method,
      'params': ?params,
    });
    await connection.socket.flush();
    return completer.future.timeout(timeout);
  }

  Future<Map<String, Object?>> callError(
    String method, {
    String? serviceId = 'inference',
    Map<String, Object?>? params,
  }) async {
    final response = await call(method, serviceId: serviceId, params: params);
    final error = response['error'];
    expect(error, isA<Map>(), reason: 'expected error response for $method');
    return (error as Map).cast<String, Object?>();
  }

  void sendRaw(Map<String, Object?> message) {
    _active?.send(message);
  }

  void dropConnections() {
    for (final connection in List.of(connections)) {
      connection.socket.destroy();
    }
  }

  Future<void> close() async {
    dropConnections();
    for (final connection in connections) {
      await connection.subscription.cancel();
    }
    await _server.close();
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  void _onHello(_PeerConnection connection, Map<String, Object?> hello) {
    hellos.add(hello);
    helloTimes.add(DateTime.now());
    if (acceptHellos) {
      _active = connection;
      connection.send({
        'type': 'welcome',
        'accepted': true,
        'launcherSessionId': 'test-launcher-${++_sessionCounter}',
      });
    } else {
      connection.send({
        'type': 'welcome',
        'accepted': false,
        'reason': rejectReason,
      });
      // 真实启动器拒绝后立即关闭会话；SDK 在 done 后才按 retryInterval 重连。
      connection.socket.flush().then((_) => connection.socket.close()).ignore();
    }
    _signal();
  }

  void _onPing(_PeerConnection connection, Map<String, Object?> message) {
    pings++;
    lastPing = message;
    if (answerPings) {
      pongs++;
      connection.send({'type': 'pong', 'sentAt': message['sentAt']});
    }
    _signal();
  }

  void _onResponse(Map<String, Object?> message) {
    responses.add(message);
    final id = message['id'];
    if (id is String) {
      _pending.remove(id)?.complete(message);
    }
    _signal();
  }

  void _onDone(_PeerConnection connection) {
    if (identical(_active, connection)) {
      _active = null;
    }
    drops++;
    onDrop?.call();
    _signal();
  }
}

class _PeerConnection {
  _PeerConnection(this.peer, this.socket) {
    subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () => peer._onDone(this), onError: (_) {});
  }

  final _LauncherPeer peer;
  final Socket socket;
  late final StreamSubscription<String> subscription;

  void send(Map<String, Object?> message) {
    socket.writeln(jsonEncode(message));
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      return;
    }
    final message = decoded.cast<String, Object?>();
    switch (message['type']) {
      case 'hello':
        peer._onHello(this, message);
      case 'ping':
        peer._onPing(this, message);
      case 'response':
        peer._onResponse(message);
    }
  }
}

/// 面向 chat 资产的假引擎进程 IO（真实 loopback HTTP 服务），
/// 结构对齐 test/public_gateway_test.dart 的 _GatewayIO/_GatewayChild。
class _SdkIO implements EngineProcessIO {
  _SdkIO(this.events);

  final List<String> events;
  final children = <_SdkChild>[];
  int startCount = 0;
  Future<void>? startGate;

  var _enteredWake = Completer<void>();

  Future<void> waitForStartEntered({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final target = startCount;
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      if (startCount > target) {
        return;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) {
        fail('timed out waiting for engine start entry');
      }
      final wake = _enteredWake.future;
      if (startCount > target) {
        return;
      }
      await wake.timeout(
        remaining,
        onTimeout: () {
          fail('timed out waiting for engine start entry');
        },
      );
    }
  }

  @override
  Future<EngineChild> start(String executable, List<String> arguments) async {
    startCount++;
    final wake = _enteredWake;
    _enteredWake = Completer<void>();
    if (!wake.isCompleted) {
      wake.complete();
    }
    await startGate;
    String arg(String name) => arguments[arguments.indexOf(name) + 1];
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.parse(arg('--port')),
    );
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/health':
          response.write('{"status":"ok"}');
        case '/props':
          response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'model_alias': arg('--alias'),
                'model_path': arg('--model'),
              }),
            );
        case '/v1/chat/completions':
          response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'model': arg('--alias'),
                'choices': [
                  {
                    'index': 0,
                    'message': {
                      'role': 'assistant',
                      'content': 'hello from fake engine',
                    },
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {
                  'prompt_tokens': 1,
                  'completion_tokens': 1,
                  'total_tokens': 2,
                },
              }),
            );
        default:
          response.statusCode = HttpStatus.notFound;
      }
      unawaited(response.close());
    });
    final child = _SdkChild(server, events);
    children.add(child);
    return child;
  }

  @override
  Future<EngineCommandResult> run(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.singleOrNull == '--version') {
      return const EngineCommandResult(
        0,
        'version: 0.5.0-dev (build 11381, commit 836d57176)\nbuilt for Darwin arm64',
        '',
      );
    }
    final result = await Process.run(executable, arguments);
    return EngineCommandResult(
      result.exitCode,
      '${result.stdout}',
      '${result.stderr}',
    );
  }
}

class _SdkChild implements EngineChild {
  _SdkChild(this.server, this.events) : pid = server.port;

  final HttpServer server;
  final List<String> events;
  final exited = Completer<int>();

  @override
  final int pid;

  @override
  Future<int> get exitCode => exited.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill(ProcessSignal signal) {
    events.add('engine-killed');
    server.close(force: true).then((_) {
      if (!exited.isCompleted) {
        exited.complete(0);
      }
    });
    return true;
  }
}

class _OpenWindowCounter {
  int calls = 0;

  Future<void> increment() async {
    calls++;
  }
}

class _SdkFixture {
  _SdkFixture._({
    required this.root,
    required this.models,
    required this.library,
    required this.asset,
    required this.io,
    required this.engine,
    required this.catalog,
    required this.routes,
    required this.gateway,
    required this.council,
    required this.mcp,
    required this.startupSet,
    required this.peer,
    required this.service,
    required this.events,
    required this.openWindowCounter,
  });

  final Directory root;
  final Directory models;
  final ModelLibrary library;
  final LibraryArtifact asset;
  final _SdkIO io;
  final LlamaEngine engine;
  final EngineCatalog catalog;
  final PublicModelRoutes routes;
  final PublicGatewayServer gateway;
  final CouncilController council;
  final CouncilMcpServer mcp;
  final StartupModelSet startupSet;
  _LauncherPeer peer;
  final LauncherInferenceService service;
  final List<String> events;
  final _OpenWindowCounter openWindowCounter;

  int get openWindowCalls => openWindowCounter.calls;

  List<RuntimeInstance> get liveInstances => engine.runtimeInstances
      .where((instance) => instance.hasLiveProcess)
      .toList();

  static Future<_SdkFixture> create({
    bool openWindowSeam = true,
    bool acceptHellos = true,
    String rejectReason = 'conflict',
    bool useAssetEntry = false,
    bool extraMissingEntry = false,
    bool corruptStartupSet = false,
    Future<sdk.VersionStatus> Function()? onVersionStatus,
  }) async {
    final root = await Directory.systemTemp.createTemp('gmd-sdk-');
    final models = Directory('${root.path}/models');
    await writeDecisionKev(models, ordinaryChat: true);
    final library = ModelLibrary();
    final asset = (await library.scan(models, verifyFiles: true)).single;
    final bytes = engineArchive();
    final archive = await File('${root.path}/release.tar.gz')
        .writeAsBytes(bytes);
    final events = <String>[];
    final io = _SdkIO(events);
    final useRegistry = ModelUseRegistry(library);
    final engine = LlamaEngine(
      library: library,
      installationDirectory: Directory('${root.path}/engines'),
      io: io,
      useRegistry: useRegistry,
      release: LlamaRelease(
        tag: 'b11381',
        commit: '836d57176',
        url: Uri.parse('https://github.com/fixture'),
        sha256: sha256.convert(bytes).toString(),
        sizeBytes: bytes.length,
      ),
      loadTimeout: const Duration(seconds: 3),
    );
    final catalog = EngineCatalog(
      library: library,
      officialEngine: engine,
      useRegistry: useRegistry,
      registryFile: File('${root.path}/private/engines.json'),
      io: io,
    );
    await catalog.installOfficial(verifiedArchive: archive);
    final routes = PublicModelRoutes(library: library, runtimes: [engine]);
    await routes.load();
    final gateway = PublicGatewayServer(routes: routes, port: 0);
    gateway.changes.listen((state) {
      if (state == PublicGatewayState.stopped) {
        events.add('gateway-stopped');
      }
    });
    final council = CouncilController(catalog: catalog);
    final mcp = CouncilMcpServer(controller: council, port: 0);
    final startupSet = StartupModelSet(
      file: File('${root.path}/private/startup-models.json'),
    );
    if (corruptStartupSet) {
      await Directory('${root.path}/private').create(recursive: true);
      await startupSet.file.writeAsString(jsonEncode({'schema': 99}));
    } else {
      await startupSet.load();
      if (useAssetEntry) {
        await startupSet.add(EngineCatalog.officialId, asset.id);
      }
      if (extraMissingEntry) {
        await startupSet.add(EngineCatalog.officialId, 'missing-artifact');
      }
    }
    final socketPath = '${root.path}/launcher.sock';
    final peer = await _LauncherPeer.bind(socketPath);
    peer
      ..acceptHellos = acceptHellos
      ..rejectReason = rejectReason;
    final openWindowCounter = _OpenWindowCounter();
    final fixture = _SdkFixture._(
      root: root,
      models: models,
      library: library,
      asset: asset,
      io: io,
      engine: engine,
      catalog: catalog,
      routes: routes,
      gateway: gateway,
      council: council,
      mcp: mcp,
      startupSet: startupSet,
      peer: peer,
      service: LauncherInferenceService(
        library: library,
        engines: catalog,
        gateway: gateway,
        mcp: mcp,
        startupSet: startupSet,
        onOpenWindow: openWindowSeam ? openWindowCounter.increment : null,
        onVersionStatus: onVersionStatus,
        socketPath: socketPath,
      ),
      events: events,
      openWindowCounter: openWindowCounter,
    );
    peer.onDrop = () => events.add('sdk-drop');
    return fixture;
  }

  void replacePeer(_LauncherPeer next) {
    peer = next;
    peer.onDrop = () => events.add('sdk-drop');
  }

  Future<void> connect() async {
    service.connect();
    await peer.helloAt(0);
  }

  Future<void> close() async {
    await service.dispose();
    await peer.close();
    gateway.close();
    routes.close();
    mcp.close();
    await council.close();
    await catalog.stopManaged();
    catalog.close();
    engine.close();
    library.close();
    for (final child in io.children) {
      await child.server.close(force: true);
    }
    await root.delete(recursive: true);
  }
}

/// 本套件全部走真实 loopback/Unix socket；TestWidgetsFlutterBinding 会把
/// HttpClient 全局替换为 400 假实现（HttpOverrides.global 赋值无效），按
/// desktop_layout_test/council_page_test 惯例逐测试恢复真实网络。
void _realNet(
  String description,
  Future<void> Function() body, {
  Timeout? timeout,
}) {
  test(
    description,
    () => HttpOverrides.runWithHttpOverrides(body, _NetworkBoundary()),
    timeout: timeout,
  );
}

/// 恢复真实 loopback 网络的空 HttpOverrides。
class _NetworkBoundary extends HttpOverrides {}
