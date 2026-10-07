import 'dart:convert';
import 'dart:io';

import 'package:ghost_model_deck/council.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/library_directory_settings.dart';
import 'package:ghost_model_deck/llama_engine.dart';
import 'package:ghost_model_deck/model_library.dart';
import 'package:ghost_model_deck/model_use_registry.dart';

void emit(String phase, Map<String, Object?> fields) => stdout.writeln(
  jsonEncode({
    'phase': phase,
    'time': DateTime.now().toUtc().toIso8601String(),
    ...fields,
  }),
);

Future<List<Map<String, Object?>>> memory(List<LlamaInstance> instances) async {
  final pids = instances
      .map((instance) => instance.pid)
      .whereType<int>()
      .toList();
  final output = await Process.run('/bin/ps', [
    '-p',
    pids.join(','),
    '-o',
    'pid=,rss=,pcpu=',
  ]);
  if (output.exitCode != 0) {
    return [
      {'unavailable': true},
    ];
  }
  return [
    for (final line in (output.stdout as String).trim().split('\n'))
      if (line.trim().isNotEmpty)
        (() {
          final parts = line.trim().split(RegExp(r'\s+'));
          return <String, Object?>{
            'pid': int.tryParse(parts[0]),
            'rssKiB': int.tryParse(parts[1]),
            'pcpu': double.tryParse(parts[2]),
            'at': DateTime.now().toUtc().toIso8601String(),
          };
        })(),
  ];
}

Future<void> main() async {
  final settings = LibraryDirectorySettings.user();
  final library = ModelLibrary();
  final use = ModelUseRegistry(library);
  final engine = LlamaEngine(
    library: library,
    useRegistry: use,
    installationDirectory: Directory(
      '${settings.file.parent.path}/engines/llama.cpp',
    ),
  );
  final catalog = EngineCatalog(
    library: library,
    officialEngine: engine,
    useRegistry: use,
    registryFile: File('${settings.file.parent.path}/engines.json'),
  );
  final council = CouncilController(catalog: catalog);
  final before = <String, FileStat>{};
  var passed = false;
  try {
    final root = await settings.load();
    final inventory = await library.scan(Directory(root));
    final selected = <LibraryArtifact>[];
    for (final relative in [
      'ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf',
      'ggml-org/Laya-GGUF/Laya-Q8_0.gguf',
    ]) {
      final path = '$root/$relative';
      before[path] = await File(path).stat();
      final matches = inventory
          .where((asset) => asset.files.any((file) => file.path == path))
          .toList();
      if (matches.length != 1) {
        throw StateError('Selected installation is ambiguous');
      }
      selected.add(matches.single);
    }
    final verified = await library.verify(selected.map((asset) => asset.id));
    if (verified.length != 2 ||
        verified.any(
          (asset) =>
              !asset.fingerprintsVerified ||
              !asset.sourceVerified ||
              asset.integrity != AssetIntegrity.complete,
        )) {
      throw StateError('Selected assets failed full/source verification');
    }
    await catalog.refresh();
    final started = <LlamaInstance>[];
    for (final asset in verified) {
      final cold = Stopwatch()..start();
      final instance = await engine.start(asset.id);
      started.add(instance);
      emit('coldStart', {
        'assetId': asset.id,
        'instanceId': instance.id,
        'elapsedUs': cold.elapsedMicroseconds,
        'pid': instance.pid,
      });
      emit('ready', {
        'instanceId': instance.id,
        'pid': instance.pid,
        'repo': asset.repoId,
        'revision': asset.revision,
      });
    }
    final ids = started.map((instance) => instance.id).toSet();
    final seats = council.availableSeats
        .where(
          (seat) =>
              seat.engine.id == EngineCatalog.officialId &&
              ids.contains(seat.instance.id),
        )
        .toList();
    if (seats.length != 2 ||
        seats.map((seat) => seat.instance.asset.id).toSet().length != 2) {
      throw StateError('Two distinct ready seats missing');
    }
    council.selectSeats(seats.map((seat) => seat.id));
    final fixture = jsonDecode(
      await File('benchmarks/fixtures/zh-decision-smoke.json').readAsString(),
    ) as Map;
    emit('benchmarkStart', {
      'synthetic': true,
      'caseCount': (fixture['cases'] as List).length,
      'memoryMetric': 'Darwin ps rss KiB and pcpu; sampled resident pages, not total GPU allocation',
      'atReadyMemory': await memory(started),
    });
    for (final value in fixture['cases'] as List) {
      final item = value as Map;
      final options = <String, String>{
        for (final option in item['options'] as List)
          (option as Map)['id'] as String: option['text'] as String,
      };
      final result = await council.consult(
        state: item['state'] as String,
        options: options,
      );
      emit('benchmarkCase', {
        'caseId': item['id'],
        'category': item['category'],
        'orderGroup': item['orderGroup'],
        'expectedChoice': item['expectedChoice'],
        'result': result.toJson(),
        'memory': await memory(started),
      });
    }
    passed = true;
  } catch (error) {
    emit('failure', {'reason': '$error'});
  } finally {
    try {
      await catalog.stopManaged();
    } catch (error) {
      passed = false;
      emit('cleanupFailure', {'reason': '$error'});
    }
    var preserved = true;
    for (final entry in before.entries) {
      final after = await File(entry.key).stat();
      if (after.size != entry.value.size ||
          after.modified != entry.value.modified) {
        preserved = false;
      }
    }
    if (!preserved) passed = false;
    emit('cleanup', {
      'modelSizesAndModificationTimesPreserved': preserved,
      'instances': [
        for (final instance in engine.state.instances)
          {
            'id': instance.id,
            'pid': instance.pid,
            'status': instance.status.name,
          },
      ],
    });
    await council.close();
    catalog.close();
    engine.close();
    library.close();
    emit('finished', {'passed': passed});
    exitCode = passed ? 0 : 1;
  }
}
