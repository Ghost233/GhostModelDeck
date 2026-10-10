import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

void main() {
  test('original history client coverage must match its recorded outcomes', () async {
    final original = await _storageInput('run-original-outcome');
    expect(original.summary['valid'], 0);
    expect(original.summary['failures'], 1);
    expect(original.items.single['status'], 'cancelled');
    final contradictory = <String, Object?>{
      ...original.toJson(),
      'summary': {...original.summary, 'valid': 1, 'failures': 0},
    };
    // Balanced totals are insufficient: the actual retained status is failure.
    expect(() => BenchmarkRun.fromJson(contradictory), throwsFormatException);
    expect(
      original.toJson()['source_summary'],
      containsPair('complete', false),
    );
    expect(original.summary['valid'], 0);
  });
  test(
    'original history cannot relabel a partial published suite as complete',
    () async {
      final original = await _storageInput('run-original-scale');
      expect(original.suite['questionCount'], 11257);
      expect(original.summary['expected'], 11257);
      final falseFull = <String, Object?>{
        ...original.toJson(),
        'status': 'completed',
        'summary': {
          ...original.summary,
          'expected': 1,
          'missing': 0,
          'complete': true,
        },
        'source_summary': {
          ...Map<String, Object?>.from(
            original.toJson()['source_summary'] as Map,
          ),
          'complete': true,
        },
      };
      // No quick-run scale may replace the original published full denominator.
      expect(() => BenchmarkRun.fromJson(falseFull), throwsFormatException);
    },
  );
  test('question journals reject foreign leaf ownership before writing and preserve other history', () async {
    final root = await Directory.systemTemp.createTemp('gmd-question-owner-');
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(
      directory: Directory('${root.path}/records'),
    );
    final protected = await _storageInput('run-protected-history');
    await store.save(protected);
    final protectedHeader = File(
      '${store.directory.path}/${protected.id}.json',
    );
    final protectedJournal = File(
      '${store.directory.path}/${protected.id}-0.items.jsonl',
    );
    final headerBytes = await protectedHeader.readAsBytes();
    final journalBytes = await protectedJournal.readAsBytes();
    final source = await File('${root.path}/original-data.parquet')
        .writeAsString('protected source marker');
    final model = await File('${root.path}/shared-model.gguf')
        .writeAsString('protected model marker');
    await expectLater(() async {
      final forged = BenchmarkRun.batch(
        id: 'run-foreign-owner',
        createdAt: protected.createdAt,
        status: BenchmarkRunStatus.interrupted,
        evaluations: [protected],
      );
      await store.save(forged);
    }(), throwsFormatException);
    expect(await protectedHeader.readAsBytes(), headerBytes);
    expect(await protectedJournal.readAsBytes(), journalBytes);
    expect(await source.readAsString(), 'protected source marker');
    expect(await model.readAsString(), 'protected model marker');
    expect(
      await File('${store.directory.path}/run-foreign-owner.json').exists(),
      isFalse,
    );
    expect(
      await File('${store.directory.path}/run-foreign-owner-0.items.jsonl')
          .exists(),
      isFalse,
    );
    expect(
      jsonDecode(await protectedHeader.readAsString())['id'],
      protected.id,
    );
  });
  test('same-length question journal corruption is rejected by read export and deletion', () async {
    final root = await Directory.systemTemp.createTemp(
      'gmd-question-corruption-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(
      directory: Directory('${root.path}/records'),
    );
    final run = await _storageInput('run-journal-corruption');
    await store.save(run);
    final header = File('${store.directory.path}/${run.id}.json');
    final journal = File('${store.directory.path}/${run.id}-0.items.jsonl');
    final original = await journal.readAsString();
    final corrupted = original.replaceFirst('native-kev', 'native-foo');
    expect(corrupted, isNot(original));
    expect(utf8.encode(corrupted).length, utf8.encode(original).length);
    await journal.writeAsString(corrupted, flush: true);
    final headerBytes = await header.readAsBytes();
    await expectLater(store.load(run.id), throwsFormatException);
    final export = File('${root.path}/refused-export.json');
    await expectLater(store.exportTo(run.id, export), throwsFormatException);
    expect(await export.exists(), isFalse);
    await expectLater(store.delete(run.id), throwsFormatException);
    expect(await header.readAsBytes(), headerBytes);
    expect(await journal.readAsString(), corrupted);
  });

  test('question journals reject symlinks and foreign owner descriptors without touching shared files', () async {
    for (final symbolic in [true, false]) {
      final root = await Directory.systemTemp.createTemp('gmd-question-links-');
      addTearDown(() => root.delete(recursive: true));
      final store = BenchmarkRunStore(
        directory: Directory('${root.path}/records'),
      );
      final run = await _storageInput('run-unsafe-descriptor');
      final other = await _storageInput('run-protected-other');
      await store.save(run);
      await store.save(other);
      final header = File('${store.directory.path}/${run.id}.json');
      final journal = File('${store.directory.path}/${run.id}-0.items.jsonl');
      final otherHeader = File('${store.directory.path}/${other.id}.json');
      final otherJournal = File(
        '${store.directory.path}/${other.id}-0.items.jsonl',
      );
      final otherHeaderBytes = await otherHeader.readAsBytes();
      final otherJournalBytes = await otherJournal.readAsBytes();
      final source = await File('${root.path}/original-data.parquet')
          .writeAsString('protected source marker');
      final model = await File('${root.path}/shared-model.gguf')
          .writeAsString('protected model marker');
      if (symbolic) {
        await journal.delete();
        await Link(journal.path).create(model.path);
      } else {
        final descriptor = jsonDecode(await header.readAsString()) as Map;
        (descriptor['journal'] as Map)['file'] =
            otherJournal.uri.pathSegments.last;
        await header.writeAsString(jsonEncode(descriptor), flush: true);
      }
      final headerBytes = await header.readAsBytes();
      await expectLater(
        store.load(run.id),
        throwsA(isA<FileSystemException>()),
      );
      final export = File('${root.path}/refused-export.json');
      await expectLater(
        store.exportTo(run.id, export),
        throwsA(isA<FileSystemException>()),
      );
      expect(await export.exists(), isFalse);
      await expectLater(
        store.delete(run.id),
        throwsA(isA<FileSystemException>()),
      );
      expect(await header.readAsBytes(), headerBytes);
      expect(await otherHeader.readAsBytes(), otherHeaderBytes);
      expect(await otherJournal.readAsBytes(), otherJournalBytes);
      expect(await source.readAsString(), 'protected source marker');
      expect(await model.readAsString(), 'protected model marker');
      if (symbolic) {
        expect(await Link(journal.path).target(), model.path);
      } else {
        expect(await journal.exists(), isTrue);
      }
    }
  });

  test('question history export and selected deletion preserve source models and other records', () async {
    final root = await Directory.systemTemp.createTemp('gmd-question-delete-');
    addTearDown(() => root.delete(recursive: true));
    final store = BenchmarkRunStore(
      directory: Directory('${root.path}/records'),
    );
    final selected = await _storageInput('run-delete-selected');
    final other = await _storageInput('run-preserve-other');
    await store.save(selected);
    await store.save(other);
    final otherHeader = File('${store.directory.path}/${other.id}.json');
    final otherJournal = File(
      '${store.directory.path}/${other.id}-0.items.jsonl',
    );
    final otherHeaderBytes = await otherHeader.readAsBytes();
    final otherJournalBytes = await otherJournal.readAsBytes();
    final source = await File('${root.path}/original-data.parquet')
        .writeAsString('protected source marker');
    final model = await File('${root.path}/shared-model.gguf')
        .writeAsString('protected model marker');
    final export = File('${root.path}/complete-record.json');
    await store.exportTo(selected.id, export);
    final exported = BenchmarkRun.fromJson(
      Map<String, Object?>.from(jsonDecode(await export.readAsString()) as Map),
    );
    expect(exported.toJson(), selected.toJson());
    expect(exported.hasItemDetails, isTrue);
    expect(exported.toJson().containsKey('journal'), isFalse);
    await expectLater(
      store.exportTo(selected.id, source),
      throwsA(isA<FileSystemException>()),
    );
    expect(await source.readAsString(), 'protected source marker');
    await store.delete(selected.id);
    expect(
      await File('${store.directory.path}/${selected.id}.json').exists(),
      isFalse,
    );
    expect(
      await File('${store.directory.path}/${selected.id}-0.items.jsonl')
          .exists(),
      isFalse,
    );
    expect((await store.list()).map((run) => run.id), [other.id]);
    expect(await otherHeader.readAsBytes(), otherHeaderBytes);
    expect(await otherJournal.readAsBytes(), otherJournalBytes);
    expect(await source.readAsString(), 'protected source marker');
    expect(await model.readAsString(), 'protected model marker');
    expect(await export.exists(), isTrue);
  });
}

final _originalSuite = JevalSuite.load(Directory('benchmarks/sources/jeval'));

Future<BenchmarkRun> _storageInput(String id) async {
  final suite = await _originalSuite;
  final task = suite.tasks.first;
  // This is an external persisted-record fixture, not a model benchmark run.
  // Its request and metadata are the actual original published first task.
  final reply = JevPlaygroundResult(
    JevPlaygroundStatus.cancelled,
    'persistence fixture cancelled',
    mode: JevPlaygroundMode.http,
    timeout: const Duration(seconds: 30),
    elapsed: const Duration(microseconds: 1),
    request: task.request('native-kev'),
    requestBody: task.requestDocument('native-kev'),
  );
  final accumulator = suite.createAccumulator();
  final sourceResult = accumulator.record(task, reply);
  final score = accumulator.snapshot(complete: false);
  return BenchmarkRun.fromJson({
    'schema_version': 3,
    'id': id,
    'created_at': '2026-10-10T00:00:00.000Z',
    'finished_at': '2026-10-10T00:00:01.000Z',
    'status': 'interrupted',
    'model': 'native-kev',
    'source': 'native',
    'channel': 'http',
    'timeout_us': 30000000,
    'suite': suite.identity,
    'identity': {'fixture': 'persisted schema input; no inference'},
    'source_summary': score.summary,
    'groups': score.groups,
    'summary': {
      'expected': 11257,
      'attempted': 1,
      'missing': 11256,
      'complete': false,
      'valid': 0,
      'failures': 1,
      'client_timeouts': 0,
      'server_timeouts': 0,
      'timeouts': 0,
      'latency_success_p50_ms': null,
      'latency_success_p95_ms': null,
      'error': null,
    },
    'items': [
      {
        'id': task.id,
        'metadata': task.metadata,
        'source_result': sourceResult,
        'status': 'cancelled',
        'elapsed_us': 1,
        'request': task.request('native-kev'),
        'request_json': task.requestDocument('native-kev'),
        'original_request_json': task.requestDocument('native-kev'),
        'request_representation': 'original-json',
        'dispatched': null,
        'result': reply.toJson(),
        'error': reply.message,
      },
    ],
  });
}
