import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/decision_protocol.dart';
import 'package:ghost_model_deck/lmstudio_provider.dart';
import 'package:ghost_model_deck/model_library.dart';

void main() {
  test('discovery shows observed CLI and default runtimes without claiming instance readiness', () async {
    final library = ModelLibrary();
    final cli = _Cli();
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);

    await provider.refresh();

    expect(provider.state.connection, ProviderConnection.connected);
    expect(provider.state.cliVersion, 'CLI commit: 69d945a');
    expect(provider.state.appVersion, isNull);
    expect(provider.state.endpoint, Uri.parse('http://127.0.0.1:1234'));
    expect(
      provider.state.runtimes
          .singleWhere((runtime) => runtime.selected)
          .identifier,
      'llama.cpp-mac-arm64-apple-metal-advsimd@2.50.0',
    );
    expect(provider.state.models.single.indexedPath, 'author/Kev/Kev-Q8.gguf');
    expect(provider.state.instances, isEmpty);
    expect(provider.state.error, isNull);
  });

  test('typed probing distinguishes authentication from unsupported and admits a bound real distribution', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var responseCode = 401;
    var responseBody = '{"error":"invalid_api_key"}';
    final seen = <Map<String, dynamic>>[];
    server.listen((request) async {
      expect(request.uri.path, '/v1/systemone');
      seen.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      if (responseCode == 200) {
        expect(
          request.headers.value('authorization'),
          'Bearer user-only-token',
        );
      }
      request.response.statusCode = responseCode;
      request.response.write(responseBody);
      await request.response.close();
    });
    final library = ModelLibrary();
    final cli = _Cli()
      ..instances = [
        {
          'identifier': 'existing-user-model',
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
        },
      ];
    final provider = LmStudioProvider(
      library: library,
      cli: cli,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.refresh();

    await provider.probe('existing-user-model');
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.authenticationRequired,
    );
    expect(
      provider.state.connection,
      ProviderConnection.authenticationRequired,
    );
    responseCode = 404;
    responseBody = '{"error":"route not found"}';
    provider.setToken('user-only-token');
    await provider.probe('existing-user-model');
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.unsupported,
    );
    responseCode = 200;
    responseBody = jsonEncode(
      _answer('existing-user-model', {'keep': 0.25, 'change': 0.75}, 'change'),
    );
    await provider.probe('existing-user-model');
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.ready,
    );
    expect(
      provider.state.instances.single.ownership,
      InstanceOwnership.attached,
    );
    final result = await provider.decide(
      'existing-user-model',
      DecisionRequest(
        state: '中文状态',
        instructions: '选择候选项',
        options: {'keep': '保持', 'change': '调整'},
      ),
    );
    expect(result.probabilities, {'keep': 0.25, 'change': 0.75});
    expect(result.choice, 'change');
    expect(result.rawResponse, responseBody);
    expect(seen.last['model'], 'existing-user-model');
    expect((seen.last['questions'] as Map)['council_choice']['criteria'], {
      'keep': '保持',
      'change': '调整',
    });
  });

  test('exact local load owns only its new instance and protects the verified installation', () async {
    final root = await Directory.systemTemp.createTemp('jev-engine-');
    addTearDown(() => root.delete(recursive: true));
    final file = await _writeKev(root);
    final library = ModelLibrary();
    final asset = (await library.scan(root, verifyFiles: true)).single;
    expect(asset.integrity, AssetIntegrity.complete);
    final cli = _Cli();
    cli.models.single['sizeBytes'] = await file.length();
    cli.models.single['deviceIdentifier'] = null;
    cli.instances = [
      {
        'identifier': 'user-keep',
        'modelKey': 'user-model',
        'path': 'other/User.gguf',
        'deviceIdentifier': null,
      },
    ];
    cli.onMutation = (arguments) async {
      if (arguments.first == 'load') {
        if (!arguments.contains('--exact') ||
            !arguments.contains('--local') ||
            !arguments.contains('author/Kev/Kev-Q8.gguf')) {
          return const CliResult(1, '', 'wrong model');
        }
        final id = arguments[arguments.indexOf('--identifier') + 1];
        cli.instances.add({
          'identifier': id,
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
          'deviceIdentifier': null,
          'format': 'gguf',
          'sizeBytes': await file.length(),
        });
        return const CliResult(0, 'Loaded', '');
      }
      if (arguments.first == 'unload' &&
          arguments.length == 2 &&
          arguments.last != 'user-keep') {
        cli.instances.removeWhere(
          (value) => value['identifier'] == arguments.last,
        );
        return const CliResult(0, 'Unloaded', '');
      }
      throw StateError('Unsafe mutation: $arguments');
    };
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.refresh();
    await expectLater(
      provider.load(asset.id),
      throwsA(isA<LmStudioException>()),
    );
    await provider.confirmModelLibrary(root.path);

    final created = await provider.load(asset.id);
    expect(created.ownership, InstanceOwnership.managed);
    expect(created.capability, InstanceCapability.pending);
    expect(created.runtimeVersion, isNull);
    expect(
      provider.state.instances
          .singleWhere((value) => value.id == 'user-keep')
          .ownership,
      InstanceOwnership.attached,
    );
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    await expectLater(
      provider.stop('user-keep'),
      throwsA(isA<LmStudioException>()),
    );
    await provider.stop(created.id);
    expect(provider.state.instances.map((value) => value.id), ['user-keep']);
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      file.path,
    );
    expect(await file.exists(), isTrue);
  });

  test('an in-flight decision cannot mark a replaced instance ready', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      entered.complete();
      await release.future;
      request.response.write(
        jsonEncode(
          _answer('same-id', {'keep': 0.25, 'change': 0.75}, 'change'),
        ),
      );
      await request.response.close();
    });
    final library = ModelLibrary();
    final cli = _Cli()
      ..instances = [
        {
          'identifier': 'same-id',
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
        },
      ];
    final provider = LmStudioProvider(
      library: library,
      cli: cli,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.refresh();
    final decision = provider.decide(
      'same-id',
      DecisionRequest(
        state: 'state',
        instructions: 'Choose',
        options: {'keep': 'Keep', 'change': 'Change'},
      ),
    );
    final rejected = expectLater(decision, throwsA(isA<LmStudioException>()));
    await entered.future;
    cli.instances.single['path'] = 'other/Replaced.gguf';
    cli.instances.single['modelKey'] = 'other';
    await provider.refresh();
    release.complete();
    await rejected;
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.pending,
    );
    expect(provider.state.instances.single.lastResult, isNull);
  });

  test('an attached instance with an older CLI schema still protects its possible local files', () async {
    final root = await Directory.systemTemp.createTemp('jev-attached-');
    addTearDown(() => root.delete(recursive: true));
    await _writeKev(root);
    final library = ModelLibrary();
    final asset = (await library.scan(root, verifyFiles: true)).single;
    final cli = _Cli()
      ..instances = [
        {
          'identifier': 'user-existing',
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
        },
      ];
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.confirmModelLibrary(root.path);
    await provider.refresh();

    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    expect(
      provider.state.instances.single.ownership,
      InstanceOwnership.attached,
    );
    cli.instances.clear();
    await provider.refresh();
    expect((await library.prepareDeletion([asset.id])).files, isNotEmpty);
  });

  test('duplicate instance identifiers appearing during a decision invalidate its binding', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final entered = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      entered.complete();
      await release.future;
      request.response.write(
        jsonEncode(
          _answer('same-id', {'keep': 0.25, 'change': 0.75}, 'change'),
        ),
      );
      await request.response.close();
    });
    final library = ModelLibrary();
    final cli = _Cli()
      ..instances = [
        {
          'identifier': 'same-id',
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
        },
      ];
    final provider = LmStudioProvider(
      library: library,
      cli: cli,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.refresh();
    final decision = provider.decide(
      'same-id',
      DecisionRequest(
        state: 'state',
        instructions: 'Choose',
        options: {'keep': 'Keep', 'change': 'Change'},
      ),
    );
    final rejected = expectLater(decision, throwsA(isA<LmStudioException>()));
    await entered.future;
    cli.instances.add({
      ...cli.instances.single,
      'path': 'remote/Other.gguf',
      'deviceIdentifier': 'remote-device',
    });
    await provider.refresh();
    release.complete();
    await rejected;
    expect(
      provider.state.instances.every(
        (value) => value.capability == InstanceCapability.pending,
      ),
      isTrue,
    );
  });

  test('chat, scores, wrong identities and invalid probabilities never become ready decisions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = 200;
    var body = '';
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    final library = ModelLibrary();
    final cli = _Cli()
      ..instances = [
        {
          'identifier': 'actual-id',
          'modelKey': 'kev',
          'path': 'author/Kev/Kev-Q8.gguf',
        },
      ];
    final provider = LmStudioProvider(
      library: library,
      cli: cli,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.refresh();
    final request = DecisionRequest(
      state: 'state',
      instructions: 'Choose',
      options: {'keep': 'Keep', 'change': 'Change'},
    );
    final invalid = [
      {
        'choices': [
          {
            'message': {'content': 'Keep'},
          },
        ],
      },
      {
        'model': 'actual-id',
        'answers': {
          'council_choice': {'type': 'score', 'score': 0.7},
        },
        'usage': {'output_tokens': 0},
      },
      _answer('other-id', {'keep': 0.25, 'change': 0.75}, 'change'),
      _answer('actual-id', {'keep': 0.25, 'foreign': 0.75}, 'keep'),
      _answer('actual-id', {'keep': -0.25, 'change': 1.25}, 'change'),
      _answer('actual-id', {'keep': 0.2, 'change': 0.2}, 'keep'),
      _answer('actual-id', {'keep': 'NaN', 'change': 0.75}, 'change'),
      _answer('actual-id', {'keep': 0.25, 'change': 0.75}, 'absent'),
      {
        ..._answer('actual-id', {'keep': 0.25, 'change': 0.75}, 'change'),
        'usage': {'output_tokens': 1},
      },
    ];
    for (final value in invalid) {
      body = jsonEncode(value);
      await expectLater(
        provider.decide('actual-id', request),
        throwsA(isA<LmStudioException>()),
      );
      expect(
        provider.state.instances.single.capability,
        InstanceCapability.invalidResponse,
      );
      expect(provider.state.instances.single.lastResult, isNull);
    }
    status = 501;
    body = '{"error":"not a decision model"}';
    await provider.probe('actual-id');
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.unsupported,
    );
    await server.close(force: true);
    await provider.probe('actual-id');
    expect(
      provider.state.instances.single.capability,
      InstanceCapability.connectionFailed,
    );
  });

  test('a confirmed failed load reports the actual sanitized runtime reason', () async {
    final root = await Directory.systemTemp.createTemp('jev-load-reason-');
    addTearDown(() => root.delete(recursive: true));
    final file = await _writeKev(root);
    final library = ModelLibrary();
    final asset = (await library.scan(root, verifyFiles: true)).single;
    final cli = _Cli();
    cli.models.single['sizeBytes'] = await file.length();
    cli.models.single['deviceIdentifier'] = null;
    const nativeReason =
        'error loading model: done_getting_tensors: wrong number of tensors; expected 322, got 320';
    cli.onMutation = (arguments) async => CliResult(
      1,
      'Loading 12%',
      '\u001b[31mError: Failed to load model.\u001b[0m\n$nativeReason\n'
          'Authorization: Bearer fake-auth-secret\napi_key=fake-api-secret\n'
          'in-memory-user-token\u0007\n${List.filled(4096, 'x').join()}',
    );
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);
    provider.setToken('in-memory-user-token');
    await provider.confirmModelLibrary(root.path);

    await expectLater(
      provider.load(asset.id),
      throwsA(
        isA<LmStudioException>().having(
          (error) => error.message,
          'specific reason',
          allOf([
            contains('加载失败'),
            contains(nativeReason),
            isNot(contains('未能确认')),
            isNot(contains('\u001b')),
            isNot(contains('\u0007')),
            isNot(contains('fake-auth-secret')),
            isNot(contains('fake-api-secret')),
            isNot(contains('in-memory-user-token')),
            predicate<String>((value) => value.length <= 1100),
          ]),
        ),
      ),
    );
    expect(provider.state.instances, isEmpty);
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      file.path,
    );
    expect(await file.exists(), isTrue);
  });

  test('a model changing before load retains its explicit local validation failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'jev-local-load-failure-',
    );
    addTearDown(() => root.delete(recursive: true));
    final file = await _writeKev(root);
    final library = ModelLibrary();
    final asset = (await library.scan(root, verifyFiles: true)).single;
    final cli = _Cli();
    cli.models.single['sizeBytes'] = await file.length();
    cli.models.single['deviceIdentifier'] = null;
    cli.onMutation = (_) async =>
        throw StateError('Changed model must not reach the external loader');
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.confirmModelLibrary(root.path);
    final bytes = await file.readAsBytes();
    bytes[bytes.length - 1] = 1;
    await file.writeAsBytes(bytes);

    await expectLater(
      provider.load(asset.id),
      throwsA(
        isA<LmStudioException>().having(
          (error) => error.message,
          'local cause',
          contains('模型在加载前变化'),
        ),
      ),
    );
    expect(provider.state.instances, isEmpty);
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      file.path,
    );
  });

  test('a timed-out load remains attached and protected until successful absence reconciliation', () async {
    final root = await Directory.systemTemp.createTemp('jev-uncertain-load-');
    addTearDown(() => root.delete(recursive: true));
    final file = await _writeKev(root);
    final library = ModelLibrary();
    final asset = (await library.scan(root, verifyFiles: true)).single;
    final cli = _Cli();
    cli.models.single['sizeBytes'] = await file.length();
    cli.models.single['deviceIdentifier'] = null;
    cli.onMutation = (arguments) async {
      if (arguments.first != 'load') {
        throw StateError('Uncertain instance must not be unloaded');
      }
      final id = arguments[arguments.indexOf('--identifier') + 1];
      cli.instances.add({
        'identifier': id,
        'modelKey': 'kev',
        'path': 'author/Kev/Kev-Q8.gguf',
        'deviceIdentifier': null,
        'format': 'gguf',
        'sizeBytes': await file.length(),
      });
      throw TimeoutException('External CLI interrupted');
    };
    final provider = LmStudioProvider(library: library, cli: cli);
    addTearDown(provider.close);
    addTearDown(library.close);
    await provider.confirmModelLibrary(root.path);
    await expectLater(
      provider.load(asset.id),
      throwsA(isA<LmStudioException>()),
    );
    final uncertain = provider.state.instances.single;
    expect(uncertain.ownership, InstanceOwnership.attached);
    final otherRoot = await Directory('${root.path}/another-library').create();
    await expectLater(
      provider.confirmModelLibrary(otherRoot.path),
      throwsA(isA<LmStudioException>()),
    );
    expect(provider.confirmedModelLibraryPath, root.path);
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    await expectLater(
      provider.stop(uncertain.id),
      throwsA(isA<LmStudioException>()),
    );
    await provider.stopManaged();
    cli.failListing = true;
    await provider.refresh();
    expect(provider.state.connection, ProviderConnection.connectionFailed);
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    cli.failListing = false;
    cli.instances.clear();
    await provider.refresh();
    expect(
      (await library.prepareDeletion([asset.id])).files.single.path,
      file.path,
    );
  });
}

Map<String, dynamic> _answer(
  String model,
  Map<String, Object> probabilities,
  String choice,
) => {
  'model': model,
  'answers': {
    'council_choice': {
      'type': 'choice',
      'choice': choice,
      'probabilities': probabilities,
      'confidence': 0.5,
    },
  },
  'usage': {'input_tokens': 25, 'output_tokens': 0},
};

class _Cli implements LmStudioCli {
  List<Map<String, dynamic>> models = [
    {
      'type': 'llm',
      'modelKey': 'kev',
      'displayName': 'Kev',
      'format': 'gguf',
      'path': 'author/Kev/Kev-Q8.gguf',
      'indexedModelIdentifier': 'author/Kev/Kev-Q8.gguf',
      'sizeBytes': 64,
    },
  ];
  List<Map<String, dynamic>> instances = [];
  Future<CliResult> Function(List<String>)? onMutation;
  bool failListing = false;

  @override
  Future<CliResult> run(
    List<String> arguments, {
    required Duration timeout,
  }) async {
    if (arguments.join(' ') == '--version') {
      return const CliResult(0, 'CLI commit: 69d945a\n', '');
    }
    if (arguments.join(' ') == 'server status --json') {
      return const CliResult(0, '{"running":true,"port":1234}', '');
    }
    if (arguments.join(' ') == 'runtime ls') {
      return const CliResult(
        0,
        'LLM ENGINE SELECTED MODEL FORMAT\nllama.cpp-mac-arm64-apple-metal-advsimd@2.50.0 ✓ GGUF\n'
            'llama.cpp-mac-arm64-apple-metal-advsimd@2.49.0 GGUF\n',
        '',
      );
    }
    if (arguments.join(' ') == 'ls --json') {
      return CliResult(0, jsonEncode(models), '');
    }
    if (arguments.join(' ') == 'ps --json') {
      return failListing
          ? const CliResult(1, '', 'unavailable')
          : CliResult(0, jsonEncode(instances), '');
    }
    if (onMutation != null) return onMutation!(arguments);
    throw StateError('Unexpected CLI command: $arguments');
  }
}

Future<File> _writeKev(Directory root) async {
  final fields = <String, Object>{
    'general.architecture': 'qwen35',
    'qwen35.block_count': 1,
    'qwen35.embedding_length': 1,
    'qwen35.embedding_length_out': 2,
    'qwen35.attention.head_count': 1,
    'qwen35.attention.head_count_kv': 1,
    'qwen35.attention.key_length': 1,
    'qwen35.attention.value_length': 1,
    'qwen35.full_attention_interval': 1,
    'qwen35.feed_forward_length': 1,
    'qwen35.context_length': 16,
    'qwen35.attention.layer_norm_rms_epsilon': 0.000001,
    'qwen35.rope.dimension_sections': [1, 0, 0, 0],
    'qwen35.ssm.conv_kernel': 1,
    'qwen35.ssm.inner_size': 1,
    'qwen35.ssm.state_size': 1,
    'qwen35.ssm.time_step_rank': 1,
    'qwen35.ssm.group_count': 1,
    'qwen35.decision.type': 'kev',
    'qwen35.decision.temperature.choice': 1.0,
    'qwen35.decision.temperature.score': 1.0,
    'qwen35.decision.temperature.noul': 1.0,
    'tokenizer.ggml.model': 'gpt2',
    'tokenizer.ggml.tokens': ['token'],
    'tokenizer.chat_template.systemone': '{{ state }}{{ instructions }}{% for o in options %}{{ o.key }}{% endfor %}',
  };
  final tensors = <String, List<int>>{
    'token_embd.weight': [1, 1],
    'output_norm.weight': [1],
    'blk.0.attn_norm.weight': [1],
    'blk.0.post_attention_norm.weight': [1],
    'blk.0.attn_q.weight': [1, 2],
    'blk.0.attn_k.weight': [1, 1],
    'blk.0.attn_v.weight': [1, 1],
    'blk.0.attn_output.weight': [1, 1],
    'blk.0.attn_q_norm.weight': [1],
    'blk.0.attn_k_norm.weight': [1],
    'blk.0.ffn_gate.weight': [1, 1],
    'blk.0.ffn_up.weight': [1, 1],
    'blk.0.ffn_down.weight': [1, 1],
    'cls.output.weight': [1, 2],
    'cls.output.bias': [2],
  };
  final bytes = BytesBuilder()..add([71, 71, 85, 70]);
  void u32(int value) => bytes.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => bytes.add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void string(String value) {
    final encoded = utf8.encode(value);
    u64(encoded.length);
    bytes.add(encoded);
  }

  u32(3);
  u64(tensors.length);
  u64(fields.length);
  for (final entry in fields.entries) {
    string(entry.key);
    switch (entry.value) {
      case String value:
        u32(8);
        string(value);
      case int value:
        u32(4);
        u32(value);
      case double value:
        u32(6);
        bytes.add(
          (ByteData(
            4,
          )..setFloat32(0, value, Endian.little)).buffer.asUint8List(),
        );
      case List<String> value:
        u32(9);
        u32(8);
        u64(value.length);
        for (final item in value) {
          string(item);
        }
      case List<int> value:
        u32(9);
        u32(4);
        u64(value.length);
        for (final item in value) {
          u32(item);
        }
    }
  }
  var offset = 0;
  for (final tensor in tensors.entries) {
    string(tensor.key);
    u32(tensor.value.length);
    for (final dimension in tensor.value) {
      u64(dimension);
    }
    u32(0);
    u64(offset);
    final size = tensor.value.fold(4, (a, b) => a * b);
    offset += ((size + 31) ~/ 32) * 32;
  }
  bytes.add(Uint8List((32 - bytes.length % 32) % 32 + offset));
  final file = File('${root.path}/author/Kev/Kev-Q8.gguf');
  await file.parent.create(recursive: true);
  return file.writeAsBytes(bytes.toBytes());
}
