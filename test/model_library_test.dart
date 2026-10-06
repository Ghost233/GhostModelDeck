import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/model_library.dart';

import 'fixtures/qwen2_mlx_layout.dart';

void main() {
  test('earlier unknown grouping or bounded companion wins over primary evidence failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-qwen2-primary-precedence-',
    );
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    for (final largeCompanion in [false, true]) {
      final directory = await Directory('${root.path}/$largeCompanion')
          .create();
      final bytes = Qwen2MlxFixture().bytes(
        indexed: largeCompanion,
        shards: largeCompanion ? 1 : 2,
      );
      bytes.remove('tokenizer.json');
      for (final file in bytes.entries) {
        await File('${directory.path}/${file.key}').writeAsBytes(file.value);
      }
      if (largeCompanion) {
        final file = await File('${directory.path}/tokenizer.json')
            .open(mode: FileMode.write);
        await file.truncate(33 * 1024 * 1024);
        await file.close();
      }
      final asset = (await library.scan(directory, verifyFiles: true)).single;
      expect(asset.integrity, AssetIntegrity.unknown);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
    }
  });
  for (final mutation in [
    'payload truncation',
    'overlap',
    'wrong byte width',
    'out of range',
    'duplicate shard',
  ]) {
    test('Qwen2 structural graph cannot repair low-level $mutation', () async {
      final root = await Directory.systemTemp.createTemp('gmd-qwen2-bytes-');
      addTearDown(() => root.delete(recursive: true));
      final bytes = Qwen2MlxFixture().bytes(
        shards: mutation == 'duplicate shard' ? 2 : 1,
      );
      if (mutation == 'duplicate shard') {
        bytes['model-1.safetensors'] = bytes['model-0.safetensors']!;
      } else {
        final weight = Uint8List.fromList(bytes['model.safetensors']!);
        final length = ByteData.sublistView(weight).getUint64(0, Endian.little);
        final header = jsonDecode(
          utf8.decode(weight.sublist(8, 8 + length)),
        ) as Map<String, dynamic>;
        final payload = weight.sublist(8 + length).toList();
        final norm = header['model.norm.weight'] as Map<String, dynamic>;
        switch (mutation) {
          case 'payload truncation':
            payload.removeLast();
          case 'overlap':
            norm['data_offsets'] = [
              (norm['data_offsets'][0] as int) - 2,
              (norm['data_offsets'][1] as int) - 2,
            ];
          case 'wrong byte width':
            norm['dtype'] = 'F32';
          case 'out of range':
            norm['data_offsets'] = [payload.length, payload.length + 128];
        }
        final encoded = utf8.encode(jsonEncode(header));
        bytes['model.safetensors'] = [
          ...(ByteData(
            8,
          )..setUint64(0, encoded.length, Endian.little)).buffer.asUint8List(),
          ...encoded,
          ...payload,
        ];
      }
      for (final file in bytes.entries) {
        await File('${root.path}/${file.key}').writeAsBytes(file.value);
      }
      final library = ModelLibrary();
      addTearDown(library.close);
      final asset = (await library.scan(root, verifyFiles: true)).single;
      expect(asset.integrity, AssetIntegrity.corrupt);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
    });
  }
  for (final missing in [false, true]) {
    test(
      'nine file Qwen2 receipt missing optional=$missing is authoritative but never Ready',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-qwen2-receipt-',
        );
        addTearDown(() => root.delete(recursive: true));
        final bytes = Qwen2MlxFixture().bytes();
        bytes.addAll({
          'merges.txt': utf8.encode('# text, not JSON'),
          'added_tokens.json': utf8.encode('{}'),
          'special_tokens_map.json': utf8.encode('{}'),
          'generation_config.json': utf8.encode('{}'),
        });
        expect(bytes.length, 9);
        for (final file in bytes.entries) {
          if (missing && file.key == 'merges.txt') continue;
          await File('${root.path}/${file.key}').writeAsBytes(file.value);
        }
        final receipts = await Directory(
          '${root.path}/.ghostmodeldeck/installations',
        ).create(recursive: true);
        await File('${receipts.path}/fixture.json').writeAsString(
          jsonEncode({
            'version': 1,
            'id': 'fixture',
            'repoId': 'synthetic/qwen2',
            'revision': List.filled(40, 'a').join(),
            'source': 'local',
            'reusedExisting': true,
            'sourceTransferPerformed': false,
            'files': [
              for (final file in bytes.entries)
                {
                  'path': file.key,
                  'sizeBytes': file.value.length,
                  'sha256': sha256.convert(file.value).toString(),
                  'upstreamSha256': sha256.convert(file.value).toString(),
                },
            ],
          }),
        );
        final library = ModelLibrary();
        addTearDown(library.close);
        final asset = (await library.scan(root, verifyFiles: true)).single;
        expect(
          asset.integrity,
          missing ? AssetIntegrity.incomplete : AssetIntegrity.complete,
        );
        // Synthetic receipt tests hash plumbing, not real upstream/model authenticity.
        expect(asset.sourceVerified, !missing);
        expect(asset.engineCapability, EngineCapability.awaitingVerification);
      },
    );
  }
  final packageCases = <String, AssetIntegrity>{
    'truncated weight': AssetIntegrity.corrupt,
    'malformed index': AssetIntegrity.corrupt,
    'missing shard': AssetIntegrity.incomplete,
    'bad routing': AssetIntegrity.incomplete,
    'malformed tokenizer': AssetIntegrity.corrupt,
    'malformed optional companion': AssetIntegrity.corrupt,
    'missing tokenizer': AssetIntegrity.incomplete,
    'missing tokenizer config': AssetIntegrity.incomplete,
    'missing config': AssetIntegrity.incomplete,
    'missing template': AssetIntegrity.incomplete,
    'unknown tokenizer': AssetIntegrity.unknown,
    'unexpected tensor': AssetIntegrity.unknown,
    'BF16 profile': AssetIntegrity.unknown,
    'F32 profile': AssetIntegrity.unknown,
    'receipt digest mismatch': AssetIntegrity.corrupt,
  };
  for (final entry in packageCases.entries) {
    test(
      'Qwen2 package ${entry.key} wins over structural eligibility',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gmd-qwen2-package-',
        );
        addTearDown(() => root.delete(recursive: true));
        final fixture = Qwen2MlxFixture();
        if (entry.key == 'unexpected tensor') {
          fixture.tensors['lm_head.weight'] = ('F16', [4, 64]);
        }
        if (entry.key.endsWith('profile')) {
          for (final name in fixture.tensors.keys.toList()) {
            final value = fixture.tensors[name]!;
            if (value.$1 == 'F16') {
              fixture.tensors[name] = (entry.key.split(' ').first, value.$2);
            }
          }
        }
        final bytes = fixture.bytes();
        switch (entry.key) {
          case 'truncated weight':
            bytes['model.safetensors'] = bytes['model.safetensors']!.sublist(
              0,
              17,
            );
          case 'malformed index':
            bytes['model.safetensors.index.json'] = utf8.encode('{');
          case 'missing shard':
            final index = jsonDecode(
              utf8.decode(bytes['model.safetensors.index.json']!),
            ) as Map<String, dynamic>;
            index['weight_map']['model.norm.weight'] = 'absent.safetensors';
            bytes['model.safetensors.index.json'] = utf8.encode(
              jsonEncode(index),
            );
          case 'bad routing':
            final index = jsonDecode(
              utf8.decode(bytes['model.safetensors.index.json']!),
            ) as Map<String, dynamic>;
            index['weight_map'].remove('model.norm.weight');
            bytes['model.safetensors.index.json'] = utf8.encode(
              jsonEncode(index),
            );
          case 'malformed tokenizer':
            bytes['tokenizer.json'] = utf8.encode('{');
          case 'malformed optional companion':
            bytes['generation_config.json'] = utf8.encode('{');
          case 'missing tokenizer':
            bytes.remove('tokenizer.json');
          case 'missing tokenizer config':
            bytes.remove('tokenizer_config.json');
          case 'missing config':
            bytes.remove('config.json');
          case 'missing template':
            bytes['tokenizer_config.json'] = utf8.encode('{}');
          case 'unknown tokenizer':
            bytes['tokenizer.json'] = utf8.encode(
              '{"model":{"type":"Other","vocab":{"hello":0}}}',
            );
        }
        for (final file in bytes.entries) {
          await File('${root.path}/${file.key}').writeAsBytes(file.value);
        }
        if (entry.key == 'receipt digest mismatch') {
          final receipts = await Directory(
            '${root.path}/.ghostmodeldeck/installations',
          ).create(recursive: true);
          await File('${receipts.path}/fixture.json').writeAsString(
            jsonEncode({
              'version': 1,
              'id': 'fixture',
              'repoId': 'synthetic/qwen2',
              'revision': List.filled(40, 'a').join(),
              'source': 'local',
              'reusedExisting': true,
              'sourceTransferPerformed': false,
              'files': [
                for (final file in bytes.entries)
                  {
                    'path': file.key,
                    'sizeBytes': file.value.length,
                    'sha256': file.key == 'model.safetensors'
                        ? List.filled(64, '0').join()
                        : sha256.convert(file.value).toString(),
                  },
              ],
            }),
          );
        }
        final library = ModelLibrary();
        addTearDown(library.close);
        final asset = (await library.scan(root, verifyFiles: true)).single;
        expect(asset.integrity, entry.value);
        expect(asset.sourceVerified, isFalse);
        expect(asset.engineCapability, EngineCapability.awaitingVerification);
      },
    );
  }
  test(
    'explicit affine mode with 628 tensors needs no universal nine companions',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-qwen2-628-');
      addTearDown(() => root.delete(recursive: true));
      final fixture = Qwen2MlxFixture(layers: 24);
      // Real graph count: embedding triplet + final norm + 24 * 26.
      expect(fixture.tensors.length, 628);
      expect(
        fixture.tensors.values.where((value) => value.$1 == 'U32').length,
        169,
      );
      expect(
        fixture.tensors.values.where((value) => value.$1 == 'F16').length,
        459,
      );
      fixture.config['quantization'] = {
        'bits': 4,
        'group_size': 64,
        'mode': 'affine',
      };
      for (final entry in fixture.bytes(indexed: false).entries) {
        await File('${root.path}/${entry.key}').writeAsBytes(entry.value);
      }
      final library = ModelLibrary();
      addTearDown(library.close);
      final asset = (await library.scan(root, verifyFiles: true)).single;
      expect(asset.files.length, 4);
      expect(asset.integrity, AssetIntegrity.complete);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
      expect(asset.sourceVerified, isFalse);
    },
  );
  test('earlier unknown header or unindexed grouping wins over Qwen2 layout failure', () async {
    final root = await Directory.systemTemp.createTemp('gmd-qwen2-precedence-');
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    for (final unknownHeader in [false, true]) {
      final fixture = Qwen2MlxFixture();
      fixture.tensors.remove('model.embed_tokens.scales');
      if (unknownHeader) {
        fixture.tensors['model.norm.weight'] = ('FUTURE16', [64]);
      }
      final directory = await Directory('${root.path}/$unknownHeader').create();
      for (final entry
          in fixture
              .bytes(indexed: false, shards: unknownHeader ? 1 : 2)
              .entries) {
        await File('${directory.path}/${entry.key}').writeAsBytes(entry.value);
      }
      final asset = (await library.scan(directory, verifyFiles: true)).single;
      expect(asset.integrity, AssetIntegrity.unknown);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
    }
  });
  test('Qwen2 requires every tensor including last layer with exact rank shape dtype', () async {
    final root = await Directory.systemTemp.createTemp('gmd-qwen2-required-');
    addTearDown(() => root.delete(recursive: true));
    final library = ModelLibrary();
    addTearDown(library.close);
    final names = Qwen2MlxFixture(layers: 2).tensors.keys.toList();
    for (final name in names) {
      for (final mutation in ['missing', 'shape', 'dtype']) {
        final fixture = Qwen2MlxFixture(layers: 2);
        final value = fixture.tensors[name]!;
        switch (mutation) {
          case 'missing':
            fixture.tensors.remove(name);
          case 'shape':
            fixture.tensors[name] = (value.$1, [...value.$2, 1]);
          case 'dtype':
            fixture.tensors[name] = (
              value.$1 == 'U32' ? 'I32' : 'U16',
              value.$2,
            );
        }
        final directory = await Directory(
          '${root.path}/${names.indexOf(name)}-$mutation',
        ).create();
        for (final entry in fixture.bytes().entries) {
          await File('${directory.path}/${entry.key}')
              .writeAsBytes(entry.value);
        }
        final asset = (await library.scan(directory, verifyFiles: true)).single;
        expect(
          asset.integrity,
          AssetIntegrity.incomplete,
          reason: '$mutation $name',
        );
        expect(
          asset.diagnostics.any((message) => message.contains(name)),
          isTrue,
          reason: name,
        );
        expect(asset.engineCapability, EngineCapability.awaitingVerification);
      }
    }
  });
  final configCases = <String, (String, Object?, AssetIntegrity)>{
    'missing hidden': ('hidden_size', null, AssetIntegrity.incomplete),
    'string hidden': ('hidden_size', '64', AssetIntegrity.incomplete),
    'bool layers': ('num_hidden_layers', false, AssetIntegrity.incomplete),
    'zero layers': ('num_hidden_layers', 0, AssetIntegrity.incomplete),
    'bounded layers': ('num_hidden_layers', 10001, AssetIntegrity.incomplete),
    'negative intermediate': (
      'intermediate_size',
      -64,
      AssetIntegrity.incomplete,
    ),
    'group dimension': ('intermediate_size', 65, AssetIntegrity.incomplete),
    'head dimension': ('num_attention_heads', 3, AssetIntegrity.incomplete),
    'KV division': ('num_key_value_heads', 3, AssetIntegrity.incomplete),
    'zero vocab': ('vocab_size', 0, AssetIntegrity.incomplete),
    'missing positions': (
      'max_position_embeddings',
      null,
      AssetIntegrity.incomplete,
    ),
    'zero epsilon': ('rms_norm_eps', 0, AssetIntegrity.incomplete),
    'invalid rope': ('rope_theta', '10000', AssetIntegrity.incomplete),
    'missing quantization': ('quantization', null, AssetIntegrity.incomplete),
    'bool bits': (
      'quantization',
      {'bits': false, 'group_size': 64},
      AssetIntegrity.incomplete,
    ),
    'zero group': (
      'quantization',
      {'bits': 4, 'group_size': 0},
      AssetIntegrity.incomplete,
    ),
    'missing tie': ('tie_word_embeddings', null, AssetIntegrity.incomplete),
    'untied': ('tie_word_embeddings', false, AssetIntegrity.unknown),
    'alternate architecture': ('model_type', 'unknown', AssetIntegrity.unknown),
    'alternate identity': (
      'architectures',
      ['OtherForCausalLM'],
      AssetIntegrity.unknown,
    ),
    'alternate bits': (
      'quantization',
      {'bits': 8, 'group_size': 64},
      AssetIntegrity.unknown,
    ),
    'alternate group': (
      'quantization',
      {'bits': 4, 'group_size': 128},
      AssetIntegrity.unknown,
    ),
    'alternate mode': (
      'quantization',
      {'bits': 4, 'group_size': 64, 'mode': 'mxfp4'},
      AssetIntegrity.unknown,
    ),
    'per module quantization': (
      'quantization',
      {'bits': 4, 'group_size': 64, 'model.layers.0': {}},
      AssetIntegrity.unknown,
    ),
    'conflicting quantization': (
      'quantization_config',
      {},
      AssetIntegrity.unknown,
    ),
    'custom file': ('model_file', 'custom', AssetIntegrity.unknown),
    'custom rope': ('rope_scaling', {}, AssetIntegrity.unknown),
    'alternate activation': ('hidden_act', 'relu', AssetIntegrity.unknown),
    'sliding window': ('use_sliding_window', true, AssetIntegrity.unknown),
    'quantized activation': (
      'quantize_activations',
      true,
      AssetIntegrity.unknown,
    ),
  };
  for (final entry in configCases.entries) {
    test(
      'Qwen2 rejects ${entry.key} without claiming complete or Ready',
      () async {
        final root = await Directory.systemTemp.createTemp('gmd-qwen2-config-');
        addTearDown(() => root.delete(recursive: true));
        final fixture = Qwen2MlxFixture();
        fixture.config[entry.value.$1] = entry.value.$2;
        for (final file in fixture.bytes().entries) {
          await File('${root.path}/${file.key}').writeAsBytes(file.value);
        }
        final library = ModelLibrary();
        addTearDown(library.close);
        final asset = (await library.scan(root, verifyFiles: true)).single;
        expect(asset.integrity, entry.value.$3);
        expect(asset.engineCapability, EngineCapability.awaitingVerification);
      },
    );
  }
  for (final indexed in [false, true]) {
    for (final shards in [1, 2]) {
      test(
        'Qwen2 two layers with $shards shards indexed=$indexed retains package ambiguity',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'gmd-qwen2-shards-',
          );
          addTearDown(() => root.delete(recursive: true));
          final fixture = Qwen2MlxFixture(layers: 2);
          for (final entry
              in fixture.bytes(indexed: indexed, shards: shards).entries) {
            await File('${root.path}/${entry.key}').writeAsBytes(entry.value);
          }
          final library = ModelLibrary();
          addTearDown(library.close);
          final asset = (await library.scan(root, verifyFiles: true)).single;
          expect(
            asset.integrity,
            !indexed && shards == 2
                ? AssetIntegrity.unknown
                : AssetIntegrity.complete,
          );
          expect(asset.engineCapability, EngineCapability.awaitingVerification);
        },
      );
    }
  }
  test(
    'mixed floating Qwen2 precision remains unknown rather than complete',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-qwen2-mixed-');
      addTearDown(() => root.delete(recursive: true));
      final fixture = Qwen2MlxFixture();
      fixture.tensors['model.norm.weight'] = ('BF16', [64]);
      for (final entry in fixture.bytes().entries) {
        await File('${root.path}/${entry.key}').writeAsBytes(entry.value);
      }
      final library = ModelLibrary();
      addTearDown(library.close);
      final asset = (await library.scan(root, verifyFiles: true)).single;
      expect(asset.integrity, AssetIntegrity.unknown);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
    },
  );
  test(
    'full mixed U32 F16 Qwen2 graph is structurally complete but never Ready',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-qwen2-layout-');
      addTearDown(() => root.delete(recursive: true));
      final fixture = Qwen2MlxFixture();
      expect(fixture.tensors.length, 30);
      expect(fixture.tensors.values.where((v) => v.$1 == 'U32').length, 8);
      final bytes = fixture.bytes();
      for (final entry in bytes.entries) {
        await File('${root.path}/${entry.key}').writeAsBytes(entry.value);
      }
      final library = ModelLibrary();
      addTearDown(library.close);
      final scanned = (await library.scan(root)).single;
      expect(scanned.integrity, AssetIntegrity.complete);
      expect(scanned.engineCapability, EngineCapability.awaitingVerification);
      expect(scanned.fingerprintsVerified, isFalse);
      final verified = (await library.verify([scanned.id])).single;
      expect(verified.integrity, AssetIntegrity.complete);
      expect(verified.kind, AssetKind.chat);
      expect(verified.architecture, 'qwen2');
      expect(verified.fingerprintsVerified, isTrue);
      expect(verified.sourceVerified, isFalse);
      expect(verified.engineCapability, EngineCapability.awaitingVerification);
      for (final entry in bytes.entries) {
        expect(
          await File('${root.path}/${entry.key}').readAsBytes(),
          entry.value,
        );
      }
    },
  );
  test(
    'shared companions never attach another indexed variant receipt',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gmd-receipt-isolation-',
      );
      addTearDown(() => root.delete(recursive: true));
      final library = ModelLibrary();
      addTearDown(library.close);
      await _writeJson(root, 'package/config.json', {'model_type': 'qwen2'});
      await _writeJson(root, 'package/tokenizer.json', {'model': {}});
      for (final variant in ['A', 'B']) {
        await _writeSafetensors(root, 'package/model-$variant.safetensors', {
          'layer.weight': [1],
        });
        await _writeJson(
          root,
          'package/model-$variant.safetensors.index.json',
          {
            'weight_map': {'layer.weight': 'model-$variant.safetensors'},
          },
        );
      }
      final initial = await library.scan(root);
      expect(initial, hasLength(2));
      final ids = {
        for (final variant in ['A', 'B'])
          variant: initial
              .singleWhere(
                (asset) => asset.files.any(
                  (file) => file.path.endsWith('/model-$variant.safetensors'),
                ),
              )
              .id,
      };
      for (final variant in ['A', 'B']) {
        final files = <Map<String, Object?>>[];
        for (final name in [
          'model-$variant.safetensors',
          'model-$variant.safetensors.index.json',
          'config.json',
          'tokenizer.json',
        ]) {
          final bytes = await File('${root.path}/package/$name').readAsBytes();
          final digest = sha256.convert(bytes).toString();
          files.add({
            'path': 'package/$name',
            'sizeBytes': bytes.length,
            'sha256': digest,
            'upstreamSha256': digest,
            'isLfs': true,
          });
        }
        await _writeJson(root, '.ghostmodeldeck/installations/$variant.json', {
          'version': 1,
          'id': variant,
          'repoId': 'publisher/package',
          'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'source': 'hf',
          'files': files,
        });
      }
      final scanned = await library.scan(root);
      expect(scanned, hasLength(2));
      for (final variant in ['A', 'B']) {
        final asset = scanned.singleWhere((asset) => asset.id == ids[variant]);
        expect(
          asset.files
              .where((file) => file.path.endsWith('.safetensors'))
              .map((file) => file.path.split('/').last),
          ['model-$variant.safetensors'],
        );
        final plan = await library.prepareDeletion([asset.id]);
        expect(
          plan.files
              .where((file) => file.path.endsWith('.safetensors'))
              .map((file) => file.path.split('/').last),
          ['model-$variant.safetensors'],
        );
        expect(
          await library.delete(plan, confirmed: false),
          DeletionResult.cancelled,
        );
      }
      expect(
        await File('${root.path}/package/model-A.safetensors').exists(),
        isTrue,
      );
      expect(
        await File('${root.path}/package/model-B.safetensors').exists(),
        isTrue,
      );
    },
  );
  test(
    'ordinary GGUF chat uses its own embedded template not SystemOne',
    () async {
      final root = await Directory.systemTemp.createTemp('gmd-chat-template-');
      addTearDown(() => root.delete(recursive: true));
      for (final name in ['present', 'absent', 'systemone-only']) {
        await _writeGguf(
          root,
          '$name.gguf',
          metadata: {
            'general.architecture': 'qwen2',
            'tokenizer.ggml.model': 'gpt2',
            'tokenizer.ggml.tokens': ['hello'],
            if (name == 'present') 'tokenizer.chat_template': '{{ messages }}',
            if (name == 'systemone-only')
              'tokenizer.chat_template.systemone': '{{ state }}',
          },
          tensors: {
            'token_embd.weight': [1, 1],
          },
        );
      }
      final library = ModelLibrary();
      addTearDown(library.close);
      final assets = await library.scan(root, verifyFiles: true);
      for (final asset in assets) {
        expect(asset.kind, AssetKind.chat);
        expect(asset.engineCapability, EngineCapability.awaitingVerification);
        if (asset.name == 'present.gguf') {
          expect(asset.integrity, AssetIntegrity.complete);
        } else {
          expect(asset.integrity, AssetIntegrity.incomplete);
          expect(asset.diagnostics, contains('缺少普通 chat 模板'));
        }
      }
    },
  );
  test('scan recognizes actual GGUF bytes without a GGUF filename and preserves them', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/existing.weights');
    final bytes = BytesBuilder()
      ..add([0x47, 0x47, 0x55, 0x46])
      ..add((ByteData(4)..setUint32(0, 3, Endian.little)).buffer.asUint8List())
      ..add(Uint8List(16));
    await file.writeAsBytes(bytes.toBytes());

    final artifacts = await ModelLibrary().scan(root, verifyFiles: true);

    expect(artifacts, hasLength(1));
    expect(artifacts.single.format, 'GGUF');
    expect(artifacts.single.integrity, AssetIntegrity.incomplete);
    expect(
      artifacts.single.engineCapability,
      EngineCapability.awaitingVerification,
    );
    expect(artifacts.single.files.single.path, file.path);
    expect(await file.readAsBytes(), bytes.toBytes());
    expect(await root.list().length, 1);
  });

  test('real decision metadata and tensors distinguish complete, split, missing, corrupt, chat and unknown assets', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    await _writeGguf(
      root,
      'complete/weights.bin',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    final weights = _kevTensors().entries.toList();
    for (var part = 0; part < 2; part++) {
      await _writeGguf(
        root,
        'split/fragment-0000${part + 1}-of-00002.gguf',
        metadata: {
          if (part == 0) ..._kevMetadata(),
          'split.no': part,
          'split.count': 2,
          'split.tensors.count': weights.length,
        },
        tensors: Map.fromEntries(part == 0 ? weights.take(7) : weights.skip(7)),
      );
    }
    await _writeGguf(
      root,
      'missing/fragment-00001-of-00002.gguf',
      metadata: {
        ..._kevMetadata(),
        'split.no': 0,
        'split.count': 2,
        'split.tensors.count': weights.length,
      },
      tensors: Map.fromEntries(weights.take(7)),
    );
    final corrupt = await _writeGguf(
      root,
      'corrupt/weights.data',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    final handle = await corrupt.open(mode: FileMode.append);
    await handle.truncate(await corrupt.length() - 40);
    await handle.close();
    final chatMeta = _kevMetadata()
      ..removeWhere((key, _) => key.contains('.decision.'));
    final chatTensors = _kevTensors()
      ..removeWhere((key, _) => key.startsWith('cls.'));
    await _writeGguf(
      root,
      'chat/not-a-brand.gguf',
      metadata: chatMeta,
      tensors: chatTensors,
    );
    await Directory('${root.path}/unknown').create();
    await File('${root.path}/unknown/Kev-ready.gguf')
        .writeAsBytes([255, 0, 1, 2, 3]);

    final artifacts = await ModelLibrary().scan(root, verifyFiles: true);

    LibraryArtifact asset(String directory) => artifacts.singleWhere(
      (asset) => asset.files.any((file) => file.path.contains('/$directory/')),
    );
    expect(artifacts, hasLength(6));
    expect(asset('complete').kind, AssetKind.decision);
    expect(asset('complete').integrity, AssetIntegrity.complete);
    expect(asset('complete').architecture, 'qwen35');
    expect(asset('complete').decisionType, 'kev');
    expect(asset('complete').sourceVerified, isFalse);
    expect(asset('split').files, hasLength(2));
    expect(asset('split').integrity, AssetIntegrity.complete);
    expect(asset('missing').integrity, AssetIntegrity.incomplete);
    expect(asset('corrupt').integrity, AssetIntegrity.corrupt);
    expect(asset('chat').kind, AssetKind.chat);
    expect(asset('unknown').kind, AssetKind.unknown);
    expect(asset('unknown').integrity, AssetIntegrity.unknown);
    expect(
      artifacts.every(
        (asset) =>
            asset.engineCapability == EngineCapability.awaitingVerification,
      ),
      isTrue,
    );
  });

  test('Laya accepts the scalar scorer layout stored in the real Q8 GGUF', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    final metadata = <String, Object>{
      'general.architecture': 'modern-bert',
      'modern-bert.block_count': 2,
      'modern-bert.embedding_length': 1,
      'modern-bert.context_length': 16,
      'modern-bert.feed_forward_length': [1, 4],
      'modern-bert.attention.head_count': 1,
      'modern-bert.attention.layer_norm_epsilon': 0.00001,
      'modern-bert.decision.type': 'laya',
      'modern-bert.decision.block_count': 1,
      'modern-bert.decision.max_head_tokens': 16,
      'modern-bert.decision.temperature.choice': 1.0,
      'modern-bert.decision.temperature.score': 1.0,
      'modern-bert.decision.temperature.noul': 1.0,
      'tokenizer.ggml.model': 'bert',
      'tokenizer.ggml.tokens': ['token'],
      'tokenizer.ggml.token_type_count': 3,
      'tokenizer.chat_template.systemone': '{{ type }}{{ state }}{{ instructions }}{% for o in options %}{{ o.key }}{% endfor %}',
    };
    final tensors = <String, List<int>>{
      'token_embd.weight': [1, 1], 'token_embd_norm.weight': [1],
      'output_norm.weight': [1], 'token_types.weight': [1, 3],
      'cls.weight': [1, 1], 'cls.bias': [1],
      'cls.norm.weight': [1], 'cls.norm.bias': [1],
      // The three token types are inputs; the scorer emits one value per type.
      // GGUF omits the scorer matrix's trailing singleton dimension.
      'cls.output.weight': [1], 'cls.output.bias': [1],
      for (var index = 0; index < 2; index++) ...{
        'blk.$index.attn_qkv.weight': [1, 3],
        'blk.$index.attn_output.weight': [1, 1],
        'blk.$index.ffn_up.weight': [1, index == 0 ? 2 : 4],
        'blk.$index.ffn_down.weight': [index == 0 ? 1 : 4, 1],
        'blk.$index.ffn_norm.weight': [1],
        if (index == 1) ...{
          'blk.$index.attn_norm.weight': [1],
          'blk.$index.attn_norm.bias': [1],
          'blk.$index.attn_qkv.bias': [3],
          'blk.$index.attn_output.bias': [1],
          'blk.$index.ffn_norm.bias': [1],
          'blk.$index.ffn_up.bias': [4],
          'blk.$index.ffn_down.bias': [1],
        },
      },
    };
    await _writeGguf(
      root,
      'scalar.weights',
      metadata: metadata,
      tensors: tensors,
    );
    await _writeGguf(
      root,
      'explicit-singleton.weights',
      metadata: metadata,
      tensors: {
        ...tensors,
        'cls.output.weight': [1, 1],
      },
    );
    await _writeGguf(
      root,
      'wrong-output-width.weights',
      metadata: metadata,
      tensors: {
        ...tensors,
        'cls.output.weight': [1, 3],
        'cls.output.bias': [3],
      },
    );

    final assets = await ModelLibrary().scan(root, verifyFiles: true);
    final valid = assets.where(
      (asset) => !asset.name.startsWith('wrong-output-width'),
    );

    expect(valid, hasLength(2));
    for (final asset in valid) {
      expect(asset.kind, AssetKind.decision);
      expect(asset.decisionType, 'laya');
      expect(asset.integrity, AssetIntegrity.complete);
      expect(asset.engineCapability, EngineCapability.awaitingVerification);
    }
    final invalid = assets.singleWhere(
      (asset) => asset.name.startsWith('wrong-output-width'),
    );
    expect(invalid.integrity, AssetIntegrity.incomplete);
    expect(invalid.diagnostics, contains('决策 head 或 scorer 尺寸不符'));
  });

  test('Safetensors content and actual config/index links distinguish complete, adapter, missing and damaged bundles', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    await _writeLayaCompanions(root, 'complete');
    await _writeSafetensors(
      root,
      'complete/weights.payload',
      _layaSafeTensors(),
    );
    await _writeLayaCompanions(root, 'missing');
    await _writeSafetensors(root, 'missing/encoder.part', {
      'encoder.embeddings.tok_embeddings.weight': [3, 1],
    });
    await _writeJson(root, 'missing/model.safetensors.index.json', {
      'weight_map': {
        for (final name in _layaSafeTensors().keys)
          name: name == 'encoder.embeddings.tok_embeddings.weight'
              ? 'encoder.part'
              : 'head.part',
      },
    });
    await _writeJson(root, 'adapter/adapter_config.json', {
      'peft_type': 'LORA',
      'base_model_name_or_path': 'author/base',
      'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });
    await _writeSafetensors(root, 'adapter/weights.payload', {
      'base_model.model.layers.0.self_attn.q_proj.lora_A.weight': [1, 1],
    });
    final damaged = await _writeSafetensors(root, 'damaged/model.safetensors', {
      'tensor': [1],
    });
    final handle = await damaged.open(mode: FileMode.append);
    await handle.truncate(await damaged.length() - 1);
    await handle.close();

    final artifacts = await ModelLibrary().scan(root, verifyFiles: true);

    LibraryArtifact asset(String directory) => artifacts.singleWhere(
      (asset) => asset.files.any((file) => file.path.contains('/$directory/')),
    );
    expect(artifacts, hasLength(4));
    expect(asset('complete').format, 'Safetensors');
    expect(asset('complete').kind, AssetKind.decision);
    expect(asset('complete').integrity, AssetIntegrity.complete);
    expect(asset('complete').files, hasLength(6));
    expect(asset('adapter').kind, AssetKind.adapter);
    expect(asset('adapter').integrity, AssetIntegrity.incomplete);
    expect(asset('adapter').files, hasLength(2));
    expect(asset('missing').integrity, AssetIntegrity.incomplete);
    expect(
      asset('missing').files
          .any((file) => file.path.endsWith('model.safetensors.index.json')),
      isTrue,
    );
    expect(
      asset('missing').files.any((file) => file.path.endsWith('head.part')),
      isFalse,
    );
    expect(asset('damaged').integrity, AssetIntegrity.corrupt);
    expect(
      artifacts.every(
        (asset) =>
            asset.engineCapability == EngineCapability.awaitingVerification,
      ),
      isTrue,
    );
  });

  test('known manifests verify actual fingerprints and require upstream evidence before claiming source verification', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    for (final directory in ['local', 'verified', 'corrupt', 'missing']) {
      final file = await _writeGguf(
        root,
        '$directory/weights.bin',
        metadata: _kevMetadata(),
        tensors: _kevTensors(),
      );
      final digest = sha256.convert(await file.readAsBytes()).toString();
      await _writeJson(root, '.ghostmodeldeck/installations/$directory.json', {
        'version': 1,
        'id': sha256.convert(utf8.encode(directory)).toString(),
        'repoId': 'author/neutral',
        'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'source': 'hf',
        'license': 'apache-2.0',
        'files': [
          {
            'path': '$directory/weights.bin',
            'sizeBytes': await file.length(),
            'sha256': directory == 'corrupt'
                ? List.filled(64, '0').join()
                : digest,
            'upstreamSha256': directory == 'verified' ? digest : null,
            'gitBlobId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'isLfs': true,
          },
          if (directory == 'missing')
            {
              'path': 'missing/required-head',
              'sizeBytes': 1,
              'sha256': List.filled(64, '0').join(),
            },
        ],
      });
    }

    final artifacts = await ModelLibrary().scan(root, verifyFiles: true);

    LibraryArtifact asset(String directory) => artifacts.singleWhere(
      (asset) => asset.files.any((file) => file.path.contains('/$directory/')),
    );
    expect(artifacts, hasLength(4));
    expect(asset('local').integrity, AssetIntegrity.complete);
    expect(asset('local').sourceVerified, isFalse);
    expect(asset('verified').sourceVerified, isTrue);
    expect(asset('verified').repoId, 'author/neutral');
    expect(
      asset('verified').revision,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(asset('verified').license, 'apache-2.0');
    expect(asset('corrupt').integrity, AssetIntegrity.corrupt);
    expect(asset('corrupt').sourceVerified, isFalse);
    expect(asset('missing').integrity, AssetIntegrity.incomplete);
    expect(asset('missing').sourceVerified, isFalse);
    expect(await File('${root.path}/verified/weights.bin').exists(), isTrue);
  });

  test('manual deletion requires confirmation, unchanged real files and stopped usage, while preserving the library and other paths', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    final outside = await Directory.systemTemp.createTemp('jev-outside-');
    addTearDown(() async {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    });
    final selected = await _writeGguf(
      root,
      'selected/weights.bin',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    final retained = await _writeGguf(
      root,
      'retained/weights.bin',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    final foreign = await _writeGguf(
      outside,
      'foreign.bin',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    await Link('${root.path}/file-alias.gguf').create(foreign.path);
    await Link('${root.path}/foreign-directory').create(outside.path);
    final original = await selected.readAsBytes();
    final library = ModelLibrary();
    final otherLibrary = ModelLibrary();
    addTearDown(library.close);
    addTearDown(otherLibrary.close);
    final assets = await library.scan(root, verifyFiles: true);
    expect(assets, hasLength(2));
    final asset = assets.singleWhere(
      (asset) => asset.files.single.path == selected.path,
    );

    final plan = await library.prepareDeletion([asset.id]);
    expect(plan.files.single.path, selected.path);
    expect(plan.sizeBytes, original.length);
    expect(
      await library.delete(plan, confirmed: false),
      DeletionResult.cancelled,
    );
    expect(await selected.readAsBytes(), original);
    await library.setFilesInUse([selected.path]);
    await expectLater(
      library.prepareDeletion([asset.id]),
      throwsA(isA<LibraryException>()),
    );
    await expectLater(
      library.delete(plan, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    expect(await selected.exists(), isTrue);
    await library.setFilesInUse([]);

    await selected.writeAsBytes([...original, 1]);
    await expectLater(
      library.delete(plan, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    expect(await selected.exists(), isTrue);
    await selected.delete();
    await Link(selected.path).create(foreign.path);
    await expectLater(
      library.delete(plan, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    expect(await foreign.exists(), isTrue);
    expect(await Link(selected.path).exists(), isTrue);
    await Link(selected.path).delete();
    await selected.writeAsBytes(original);

    final fresh = await library.prepareDeletion([asset.id]);
    await expectLater(
      otherLibrary.delete(fresh, confirmed: true),
      throwsA(isA<LibraryException>()),
    );
    expect(
      await library.delete(fresh, confirmed: true),
      DeletionResult.deleted,
    );
    expect(await selected.exists(), isFalse);
    expect(await root.exists(), isTrue);
    expect(await selected.parent.exists(), isTrue);
    expect(await retained.exists(), isTrue);
    expect(await foreign.readAsBytes(), original);
    expect(await Link('${root.path}/file-alias.gguf').exists(), isTrue);
    expect(library.state.artifacts, hasLength(1));
  });

  test('default inventory keeps full fingerprints unknown until the selected asset is explicitly verified', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    addTearDown(() => root.delete(recursive: true));
    for (final directory in ['selected', 'retained']) {
      final file = await _writeGguf(
        root,
        '$directory/weights.bin',
        metadata: _kevMetadata(),
        tensors: _kevTensors(),
      );
      final digest = sha256.convert(await file.readAsBytes()).toString();
      await _writeJson(root, '.ghostmodeldeck/installations/$directory.json', {
        'version': 1,
        'id': sha256.convert(utf8.encode(directory)).toString(),
        'repoId': 'author/$directory',
        'revision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'source': 'hf',
        'files': [
          {
            'path': '$directory/weights.bin',
            'sizeBytes': await file.length(),
            'sha256': digest,
            'upstreamSha256': digest,
            'isLfs': true,
          },
        ],
      });
    }
    final library = ModelLibrary();
    addTearDown(library.close);

    final inventory = await library.scan(root);
    final selected = inventory.singleWhere(
      (asset) => asset.files.single.path.contains('/selected/'),
    );
    expect(
      inventory.every(
        (asset) => !asset.fingerprintsVerified && !asset.sourceVerified,
      ),
      isTrue,
    );
    expect(selected.files.single.fingerprintKind, FingerprintKind.inventory);
    expect(selected.files.single.sha256, isNull);
    expect(selected.files.single.modifiedAtUtc, isNotNull);

    final checked = await library.verify([selected.id]);

    expect(checked, hasLength(1));
    expect(checked.single.fingerprintsVerified, isTrue);
    expect(checked.single.sourceVerified, isTrue);
    expect(
      checked.single.files.single.fingerprintKind,
      FingerprintKind.fullContent,
    );
    expect(checked.single.files.single.sha256, hasLength(64));
    final retained = library.state.artifacts.singleWhere(
      (asset) => asset.files.single.path.contains('/retained/'),
    );
    expect(retained.fingerprintsVerified, isFalse);
    expect(retained.sourceVerified, isFalse);
  });

  test('selective verification succeeds while an unrelated real file is being written', () async {
    final root = await Directory.systemTemp.createTemp('jev-library-');
    final selectedFile = await _writeGguf(
      root,
      'selected/weights.bin',
      metadata: _kevMetadata(),
      tensors: _kevTensors(),
    );
    final unrelated = File('${root.path}/downloading_unrelated.gguf.part');
    await unrelated.writeAsBytes(Uint8List(65536));
    final library = ModelLibrary();
    final inventory = await library.scan(root);
    final selected = inventory.singleWhere(
      (asset) => asset.files.single.path == selectedFile.path,
    );
    final phases = ReceivePort();
    final writer = await Isolate.spawn(_churnFile, [
      unrelated.path,
      phases.sendPort,
    ]);
    await phases.first;
    final before = await unrelated.stat();
    final clock = Stopwatch()..start();
    try {
      final verified = await library.verify([selected.id]);
      final after = await unrelated.stat();
      debugPrintSynchronously(
        'selective verification phase: elapsed=${clock.elapsedMilliseconds}ms, unrelated mtime ${before.modified.microsecondsSinceEpoch}->${after.modified.microsecondsSinceEpoch}',
      );
      expect(after.modified, isNot(before.modified));
      expect(verified, hasLength(1));
      expect(verified.single.fingerprintsVerified, isTrue);
      expect(verified.single.integrity, AssetIntegrity.complete);
      expect(verified.single.files.single.path, selectedFile.path);
      expect(library.state.error, isNull);
      final other = library.state.artifacts.singleWhere(
        (asset) => asset.files.single.path == unrelated.path,
      );
      expect(other.fingerprintsVerified, isFalse);
    } catch (error) {
      debugPrintSynchronously(
        'selective verification phase: elapsed=${clock.elapsedMilliseconds}ms, error=$error, stateError=${library.state.error}',
      );
      rethrow;
    } finally {
      writer.kill(priority: Isolate.immediate);
      phases.close();
      library.close();
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

void _churnFile(List<Object> args) {
  final file = File(args[0] as String).openSync(mode: FileMode.write);
  final bytes = Uint8List(65536);
  file.writeFromSync(bytes);
  (args[1] as SendPort).send('writer active');
  while (true) {
    file.setPositionSync(0);
    file.writeFromSync(bytes);
  }
}

Future<File> _writeGguf(
  Directory root,
  String path, {
  Map<String, Object>? metadata,
  Map<String, List<int>>? tensors,
}) async {
  final fields = metadata ?? {};
  final weights = tensors ?? {};
  final header = BytesBuilder()..add([0x47, 0x47, 0x55, 0x46]);
  void u32(int value) => header.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => header.add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void string(String value) {
    final bytes = utf8.encode(value);
    u64(bytes.length);
    header.add(bytes);
  }

  u32(3);
  u64(weights.length);
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
        header.add(
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
      default:
        throw ArgumentError('Unsupported fixture metadata');
    }
  }
  var offset = 0;
  for (final tensor in weights.entries) {
    string(tensor.key);
    u32(tensor.value.length);
    for (final dimension in tensor.value) {
      u64(dimension);
    }
    u32(0); // GGML F32.
    u64(offset);
    final size = tensor.value.fold(4, (total, dimension) => total * dimension);
    offset += ((size + 31) ~/ 32) * 32;
  }
  final padding = (32 - header.length % 32) % 32;
  header.add(Uint8List(padding + offset));
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  return file.writeAsBytes(header.toBytes());
}

Map<String, Object> _kevMetadata() => {
  'general.architecture': 'qwen35',
  'general.name': 'neutral fixture',
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

Map<String, List<int>> _kevTensors() => {
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

Future<File> _writeSafetensors(
  Directory root,
  String path,
  Map<String, List<int>> tensors,
) async {
  var offset = 0;
  final fields = <String, Object>{};
  for (final tensor in tensors.entries) {
    final size = tensor.value.fold(4, (total, dimension) => total * dimension);
    fields[tensor.key] = {
      'dtype': 'F32',
      'shape': tensor.value,
      'data_offsets': [offset, offset + size],
    };
    offset += size;
  }
  var json = jsonEncode(fields);
  while (utf8.encode(json).length % 8 != 0) {
    json += ' ';
  }
  final encoded = utf8.encode(json);
  final bytes = BytesBuilder()
    ..add(
      (ByteData(
        8,
      )..setUint64(0, encoded.length, Endian.little)).buffer.asUint8List(),
    )
    ..add(encoded)
    ..add(Uint8List(offset));
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  return file.writeAsBytes(bytes.toBytes());
}

Future<void> _writeJson(Directory root, String path, Object data) async {
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(data));
}

Future<void> _writeLayaCompanions(Directory root, String directory) async {
  await _writeJson(root, '$directory/config.json', {
    'model_type': 'laya',
    'architectures': ['LayaTypedDecisions'],
  });
  await _writeJson(root, '$directory/encoder/config.json', {
    'model_type': 'modernbert',
    'num_hidden_layers': 1,
    'hidden_size': 1,
    'vocab_size': 3,
    'intermediate_size': 1,
    'num_attention_heads': 1,
  });
  await _writeJson(root, '$directory/rl_agent_config.json', {
    'head_layers': 1,
    'head_max_len': 16,
    'temperature': [1.0, 1.0, 1.0],
  });
  await _writeJson(root, '$directory/tokenizer/tokenizer.json', {
    'version': '1.0',
    'model': {
      'type': 'WordPiece',
      'vocab': {'<bos>': 0, '<eos>': 1, '<mask>': 2},
    },
  });
  await _writeJson(root, '$directory/tokenizer/tokenizer_config.json', {
    'cls_token': '<bos>',
    'sep_token': '<eos>',
    'mask_token': '<mask>',
  });
}

Map<String, List<int>> _layaSafeTensors() => {
  'encoder.embeddings.tok_embeddings.weight': [3, 1],
  'encoder.embeddings.norm.weight': [1],
  'encoder.final_norm.weight': [1],
  'encoder.layers.0.attn.Wqkv.weight': [3, 1],
  'encoder.layers.0.attn.Wo.weight': [1, 1],
  'encoder.layers.0.mlp.Wi.weight': [2, 1],
  'encoder.layers.0.mlp.Wo.weight': [1, 1],
  'encoder.layers.0.mlp_norm.weight': [1],
  'head.layers.0.norm1.weight': [1],
  'head.layers.0.norm1.bias': [1],
  'head.layers.0.self_attn.in_proj_weight': [3, 1],
  'head.layers.0.self_attn.in_proj_bias': [3],
  'head.layers.0.self_attn.out_proj.weight': [1, 1],
  'head.layers.0.self_attn.out_proj.bias': [1],
  'head.layers.0.norm2.weight': [1],
  'head.layers.0.norm2.bias': [1],
  'head.layers.0.linear1.weight': [4, 1],
  'head.layers.0.linear1.bias': [4],
  'head.layers.0.linear2.weight': [1, 4],
  'head.layers.0.linear2.bias': [1],
  'type_emb.weight': [3, 1],
  'scorer.0.weight': [1],
  'scorer.0.bias': [1],
  'scorer.1.weight': [1, 1],
  'scorer.1.bias': [1],
  'scorer.3.weight': [1, 1],
  'scorer.3.bias': [1],
};
