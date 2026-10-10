import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/adversarial_benchmark.dart';
import 'package:ghost_model_deck/benchmark_run_store.dart';
import 'package:ghost_model_deck/coherence_benchmark.dart';
import 'package:ghost_model_deck/frozen_question_suite.dart';
import 'package:ghost_model_deck/jeval.dart';
import 'package:ghost_model_deck/jev_playground.dart';

// These are full original-source persisted-record fixtures. No model is called,
// and a stored cancelled input never establishes physical delivery or success.
const _model = '__fixed_public_call_name__';
const _timeout = Duration(seconds: 30);
const _identity = {'fixture': 'full original persistence input; no inference'};
final _created = DateTime.utc(2026, 10, 10);
final _finished = DateTime.utc(2026, 10, 10, 0, 0, 1);

void main() {
  for (final source in ['jeval', 'coherence', 'adversarial']) {
    test(
      'full original $source schema3 per-question append preserves every byte and visits rows linearly',
      () => _recordEvidence(source, () async {
        final suite = await _load(source);
        return _schema3(suite);
      }),
      // An operational watchdog, not a wall-time performance requirement.
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }
  test(
    'full original Adv schema4 HTTP and MCP journals retain independent complete inputs',
    () => _recordEvidence('adversarial-schema4', () async {
      final suite = await _load('adversarial');
      return _schema4(suite);
    }),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

Future<FrozenQuestionSuite> _load(String source) => switch (source) {
  'jeval' => JevalSuite.load(Directory('benchmarks/sources/jeval')),
  'coherence' => CoherenceSuite.load(Directory('benchmarks/sources/coherence')),
  'adversarial' => AdversarialSuite.load(
    Directory('benchmarks/sources/adversarial'),
  ),
  _ => throw ArgumentError.value(source),
};

Future<Map<String, Object?>> _schema3(FrozenQuestionSuite suite) async {
  final source = suite.identity['id'] as String;
  final expected = switch (source) {
    'jeval' => 11257,
    'coherence' => 10320,
    'adversarial' => 11368,
    _ => throw ArgumentError.value(source),
  };
  expect(suite.tasks, hasLength(expected));
  expect(suite.tasks.map((task) => task.id).toSet(), hasLength(expected));
  final root = await Directory.systemTemp.createTemp('gmd-question-scale-');
  addTearDown(() => root.delete(recursive: true));
  final store = BenchmarkRunStore(directory: Directory('${root.path}/records'));
  final id = 'run-scale-$source';
  final rows = _ObservedRows();
  final accumulator = suite.createAccumulator();
  final checkpoints = <Map<String, Object?>>[];
  final positions = {1, expected ~/ 4, expected ~/ 2, expected};
  final journal = File('${store.directory.path}/$id-0.items.jsonl');
  var previousBytes = 0;
  String? previousHash;
  BenchmarkRun? firstSnapshot;
  final stopwatch = Stopwatch()..start();
  for (final task in suite.tasks) {
    rows.append(_item(task, accumulator, JevPlaygroundMode.http));
    rows.observing = true;
    try {
      final snapshot = _snapshot(suite, id, rows, JevPlaygroundMode.http);
      firstSnapshot ??= snapshot;
      await store.save(snapshot);
    } finally {
      rows.observing = false;
    }
    if (positions.contains(rows.length)) {
      final checkpoint = await _journalCheckpoint(store, id, 0, rows.length);
      final bytes = checkpoint['bytes'] as int;
      expect(bytes, greaterThan(previousBytes));
      if (previousHash != null) {
        expect(await _fileHash(journal, end: previousBytes), previousHash);
      }
      checkpoints.add(checkpoint);
      previousBytes = bytes;
      previousHash = checkpoint['file_sha256'] as String;
    }
  }
  final score = accumulator.snapshot(complete: false);
  expect(score.summary['complete'], isFalse);
  final readsBeforeTerminal = rows.reads;
  late final BenchmarkRun terminal;
  rows.observing = true;
  try {
    terminal = _snapshot(suite, id, rows, JevPlaygroundMode.http, score: score);
    await store.save(terminal);
    await store.save(terminal);
  } finally {
    rows.observing = false;
  }
  stopwatch.stop();
  expect(rows.reads, readsBeforeTerminal);
  expect(rows.reads, inInclusiveRange(expected, 2 * expected + 2));
  expect(rows.maximumReadsPerRow, lessThanOrEqualTo(2));
  final first = firstSnapshot!;
  expect(first.items, hasLength(1));
  expect(first.items.single['id'], suite.tasks.first.id);
  expect(first.summary['attempted'], 1);
  expect(await journal.length(), previousBytes);
  expect(await _fileHash(journal), previousHash);
  expect(() => first.items[0] = rows.values.first, throwsUnsupportedError);
  final original = _inputEvidence(terminal, suite);
  final roundTrip = await _roundTrip(store, terminal, suite, root);
  return {
    'suite': suite.identity,
    'source_files': await _sourceFiles(suite),
    'schema_version': 3,
    'save_style': 'one original row appended per save; one terminal score',
    'input': original,
    'append_checkpoints': checkpoints,
    'total_snapshot_and_save_row_reads': rows.reads,
    'maximum_snapshot_and_save_reads_per_row': rows.maximumReadsPerRow,
    'row_read_upper_bound': 2 * expected + 2,
    'repeat_terminal_save_row_reads': rows.reads - readsBeforeTerminal,
    'journal_net_bytes': previousBytes,
    'journal_file_sha256': previousHash,
    'save_elapsed_us_reference_only': stopwatch.elapsedMicroseconds,
    'round_trip': roundTrip,
  };
}

Future<Map<String, Object?>> _schema4(FrozenQuestionSuite suite) async {
  expect(suite.tasks, hasLength(11368));
  final root = await Directory.systemTemp.createTemp(
    'gmd-question-scale-batch-',
  );
  addTearDown(() => root.delete(recursive: true));
  final store = BenchmarkRunStore(directory: Directory('${root.path}/records'));
  const owner = 'run-scale-adv-batch';
  final leaves = <BenchmarkRun>[];
  final observations = <_ObservedRows>[];
  for (final mode in [JevPlaygroundMode.http, JevPlaygroundMode.mcp]) {
    final rows = _ObservedRows();
    final accumulator = suite.createAccumulator();
    for (final task in suite.tasks) {
      rows.append(_item(task, accumulator, mode));
    }
    final score = accumulator.snapshot(complete: false);
    expect(score.summary['complete'], isFalse);
    leaves.add(
      _snapshot(suite, '$owner-${leaves.length}', rows, mode, score: score),
    );
    observations.add(rows);
  }
  final batch = BenchmarkRun.batch(
    id: owner,
    createdAt: _created,
    status: BenchmarkRunStatus.interrupted,
    evaluations: leaves,
  );
  expect(batch.toJson()['schema_version'], 4);
  expect(batch.summary['expected'], 22736);
  expect(batch.summary['attempted'], 22736);
  expect(batch.summary['missing'], 0);
  expect(batch.summary['complete'], isFalse);
  for (final rows in observations) {
    rows.observing = true;
  }
  try {
    await store.save(batch);
  } finally {
    for (final rows in observations) {
      rows.observing = false;
    }
  }
  final descriptors = <Map<String, Object?>>[];
  for (var index = 0; index < leaves.length; index++) {
    final rows = observations[index];
    expect(rows.reads, inInclusiveRange(11368, 2 * 11368 + 2));
    expect(rows.maximumReadsPerRow, lessThanOrEqualTo(2));
    descriptors.add(await _journalCheckpoint(store, owner, index, 11368));
  }
  final roundTrip = await _roundTrip(store, batch, suite, root);
  final header = File('${store.directory.path}/$owner.json');
  final originalHeader = await header.readAsString();
  final foreign = _object(jsonDecode(originalHeader));
  final foreignLeaf = (foreign['evaluations'] as List).first as Map;
  (foreignLeaf['journal'] as Map)['file'] = '$owner-1.items.jsonl';
  await header.writeAsString(jsonEncode(foreign), flush: true);
  final restarted = BenchmarkRunStore(directory: store.directory);
  await expectLater(restarted.load(owner), throwsA(isA<FileSystemException>()));
  final refused = File('${root.path}/foreign-owner-export.json');
  await expectLater(
    restarted.exportTo(owner, refused),
    throwsA(isA<FileSystemException>()),
  );
  expect(await refused.exists(), isFalse);
  for (var index = 0; index < descriptors.length; index++) {
    final file = File('${store.directory.path}/$owner-$index.items.jsonl');
    expect(await _fileHash(file), descriptors[index]['file_sha256']);
  }
  await header.writeAsString(originalHeader, flush: true);
  return {
    'suite': suite.identity,
    'source_files': await _sourceFiles(suite),
    'schema_version': 4,
    'save_style': 'two full original leaves; one save',
    'leaf_inputs': [for (final leaf in leaves) _inputEvidence(leaf, suite)],
    'journals': descriptors,
    'save_row_reads_by_leaf': [for (final rows in observations) rows.reads],
    'owner_mismatch_rejected_by_load_and_export': true,
    'owner_rejection_preserved_both_journal_hashes': true,
    'round_trip': roundTrip,
  };
}

Map<String, Object?> _item(
  FrozenQuestionTask task,
  FrozenQuestionAccumulator accumulator,
  JevPlaygroundMode mode,
) {
  final request = task.request(_model);
  final original = task.requestDocument(_model);
  final actual = mode == JevPlaygroundMode.http
      ? original
      : jsonEncode(request);
  final reply = JevPlaygroundResult(
    JevPlaygroundStatus.cancelled,
    'persistence fixture cancelled; no inference',
    mode: mode,
    timeout: _timeout,
    elapsed: const Duration(microseconds: 1),
    request: request,
    requestBody: actual,
  );
  final row = BenchmarkRun.questionItem(
    {
      'id': task.id,
      'metadata': task.metadata,
      'source_result': accumulator.record(task, reply),
      'status': reply.status.name,
      'elapsed_us': reply.elapsed.inMicroseconds,
      'request': request,
      'request_json': actual,
      'original_request_json': original,
      'request_representation': mode == JevPlaygroundMode.http
          ? 'original-json'
          : 'mcp-object',
      'dispatched': null,
      'result': reply.toJson(),
      'error': reply.message,
    },
    model: _model,
    channel: mode.name,
    identity: _identity,
  );
  expect(row['metadata'], task.metadata, reason: task.id);
  expect(row['request'], request, reason: task.id);
  expect(row['request_json'], actual, reason: task.id);
  expect(row['original_request_json'], original, reason: task.id);
  final result = row['result'] as Map;
  expect(result['request'], request, reason: task.id);
  expect(result['request_json'], actual, reason: task.id);
  expect(result['raw_response'], isNull);
  expect(result['output'], isNull);
  return row;
}

BenchmarkRun _snapshot(
  FrozenQuestionSuite suite,
  String id,
  List<Map<String, Object?>> rows,
  JevPlaygroundMode mode, {
  FrozenQuestionScore? score,
}) => BenchmarkRun.questionSnapshot(
  header: {
    'schema_version': 3,
    'id': id,
    'created_at': _created.toIso8601String(),
    'finished_at': score == null ? null : _finished.toIso8601String(),
    'status': score == null ? 'running' : 'interrupted',
    'model': _model,
    'source': 'native',
    'channel': mode.name,
    'timeout_us': _timeout.inMicroseconds,
    'suite': suite.identity,
    'identity': _identity,
    'source_summary': score?.summary ?? const {'complete': false},
    'groups': score?.groups ?? const <Map<String, Object?>>[],
    'summary': {
      'expected': suite.tasks.length,
      'attempted': rows.length,
      'missing': suite.tasks.length - rows.length,
      'complete': false,
      'valid': 0,
      'failures': rows.length,
      'client_timeouts': 0,
      'server_timeouts': 0,
      'timeouts': 0,
      'latency_success_p50_ms': null,
      'latency_success_p95_ms': null,
      'error': null,
    },
  },
  items: rows,
);

Future<Map<String, Object?>> _roundTrip(
  BenchmarkRunStore store,
  BenchmarkRun original,
  FrozenQuestionSuite suite,
  Directory root,
) async {
  final restarted = BenchmarkRunStore(directory: store.directory);
  final listed = (await restarted.list()).single;
  expect(listed.id, original.id);
  expect(listed.summary, original.summary);
  expect(listed.hasItemDetails, isFalse);
  expect(listed.evaluations, hasLength(original.evaluations.length));
  for (final leaf in listed.evaluations) {
    expect(leaf.items, isEmpty);
    expect(leaf.suite, suite.identity);
    expect(leaf.summary['expected'], suite.tasks.length);
  }
  final restored = await restarted.load(original.id);
  final loaded = _verifyRestored(restored, original, suite);
  final destination = File('${root.path}/independent-export.json');
  await restarted.exportTo(original.id, destination);
  final exported = BenchmarkRun.fromJson(
    _object(jsonDecode(await destination.readAsString())),
  );
  final exportInputs = _verifyRestored(exported, original, suite);
  expect(exportInputs, loaded);
  expect(exported.toJson().containsKey('journal'), isFalse);
  for (final leaf in exported.evaluations) {
    expect(leaf.toJson().containsKey('journal'), isFalse);
  }
  return {
    'list_hydrated_rows': 0,
    'selected_load_inputs': loaded,
    'export_inputs': exportInputs,
    'export_bytes': await destination.length(),
    'export_file_sha256': await _fileHash(destination),
    'export_is_independent_json': true,
  };
}

List<Map<String, Object?>> _verifyRestored(
  BenchmarkRun restored,
  BenchmarkRun original,
  FrozenQuestionSuite suite,
) {
  expect(restored.id, original.id);
  expect(restored.status, BenchmarkRunStatus.interrupted);
  expect(restored.summary, original.summary);
  expect(restored.hasItemDetails, isTrue);
  expect(restored.evaluations, hasLength(original.evaluations.length));
  final evidence = <Map<String, Object?>>[];
  for (var index = 0; index < original.evaluations.length; index++) {
    final leaf = restored.evaluations[index];
    final expected = original.evaluations[index];
    expect(leaf.id, expected.id);
    expect(leaf.channel, expected.channel);
    expect(leaf.suite, suite.identity);
    expect(leaf.identity, _identity);
    expect(leaf.summary, expected.summary);
    expect(leaf.groups, expected.groups);
    expect(
      leaf.toJson()['source_summary'],
      expected.toJson()['source_summary'],
    );
    expect(leaf.toJson()['source_summary'], containsPair('complete', false));
    final actual = _inputEvidence(leaf, suite);
    expect(actual, _inputEvidence(expected, suite));
    evidence.add(actual);
  }
  return evidence;
}

Map<String, Object?> _inputEvidence(
  BenchmarkRun run,
  FrozenQuestionSuite suite,
) {
  expect(run.items, hasLength(suite.tasks.length));
  final ids = <String>{};
  final raw = _StreamingHash();
  final allFields = _StreamingHash();
  final sourceFields = _StreamingHash();
  final numberLiterals = <String, String>{};
  final source = suite.identity['id'] as String;
  if (source == 'adversarial') {
    numberLiterals.addAll(
      Map<String, String>.from(run.suite['original_number_literals'] as Map),
    );
  }
  var rawBytes = 0;
  var unsupportedQuestionFields = 0;
  for (var index = 0; index < run.items.length; index++) {
    final row = run.items[index];
    final task = suite.tasks[index];
    expect(row['id'], task.id);
    expect(ids.add(row['id'] as String), isTrue);
    expect(row['status'], 'cancelled');
    expect(row['dispatched'], isNull);
    expect(row['metadata'], task.metadata, reason: task.id);
    expect(row['request'], task.request(_model), reason: task.id);
    final document = row['original_request_json'] as String;
    expect(document, task.requestDocument(_model), reason: task.id);
    final actualRequest = run.channel == 'http'
        ? document
        : jsonEncode(task.request(_model));
    expect(row['request_json'], actualRequest, reason: task.id);
    final result = row['result'] as Map;
    expect(result['status'], 'cancelled');
    expect(result['request'], task.request(_model), reason: task.id);
    expect(result['request_json'], actualRequest, reason: task.id);
    expect(result['output'], isNull);
    expect(result['raw_response'], isNull);
    raw.add('$document\n');
    rawBytes += utf8.encode('$document\n').length;
    allFields.add('${jsonEncode(row)}\n');
    final metadata = row['metadata'] as Map;
    if (source == 'jeval') {
      final fields = metadata['original_fields'] as Map;
      final originalFields = {
        for (final key in JevalSuite.columns) key: fields[key],
      };
      sourceFields.add('${jsonEncode(originalFields)}\n');
    } else if (source == 'coherence') {
      final request = _object(row['request'])..remove('model');
      sourceFields.add('${jsonEncode(request)}\n');
    } else {
      numberLiterals.addAll(
        Map<String, String>.from(metadata['original_number_literals'] as Map),
      );
      final questions = (row['request'] as Map)['questions'] as Map;
      for (final question in questions.values) {
        unsupportedQuestionFields += (question as Map).keys
            .where(
              (key) =>
                  !const {'type', 'instructions', 'criteria'}.contains(key),
            )
            .length;
      }
    }
  }
  final wireHash = raw.finish();
  final fieldsHash = sourceFields.finish();
  String? literalsHash;
  if (source == 'jeval') {
    expect(fieldsHash, JevalSuite.canonicalOriginalFieldsSha256);
  } else if (source == 'coherence') {
    expect(
      fieldsHash,
      '9a91829af64a2282a3544b1cdc7dabd0b9fb351a6e95870c521d75cc7c9cc9ea',
    );
  } else {
    expect(
      wireHash,
      '22e6b840b346f3c089269a6c1c22b49f6306b6c2c47cf1eb3805963dc0500b2f',
    );
    expect(numberLiterals, hasLength(4564));
    final pointers = numberLiterals.keys.toList()..sort();
    final literals = _StreamingHash();
    for (final pointer in pointers) {
      literals.add('$pointer\t${numberLiterals[pointer]}\n');
    }
    literalsHash = literals.finish();
    expect(
      literalsHash,
      '5850e281676aabc4bd6e33bdbbe40e9aa1eeddcd3e5ff7ec387354fe74be7a1c',
    );
    expect(unsupportedQuestionFields, greaterThan(0));
  }
  return {
    'channel': run.channel,
    'count': run.items.length,
    'unique_ids': ids.length,
    'original_request_jsonl_bytes': rawBytes,
    'original_request_jsonl_sha256': wireHash,
    'all_item_fields_jsonl_sha256': allFields.finish(),
    'canonical_original_fields_sha256': source == 'adversarial'
        ? null
        : fieldsHash,
    'original_number_literals_count': numberLiterals.length,
    'original_number_literals_sha256': literalsHash,
    'unsupported_original_question_fields': unsupportedQuestionFields,
  };
}

Future<Map<String, Object?>> _journalCheckpoint(
  BenchmarkRunStore store,
  String owner,
  int index,
  int count,
) async {
  final headerFile = File('${store.directory.path}/$owner.json');
  final header = _object(jsonDecode(await headerFile.readAsString()));
  final leaf = header['schema_version'] == 3
      ? header
      : _object((header['evaluations'] as List)[index]);
  final journal = File('${store.directory.path}/$owner-$index.items.jsonl');
  final descriptor = _object(leaf['journal']);
  expect(leaf['id'], header['schema_version'] == 3 ? owner : '$owner-$index');
  expect(leaf['items'], isEmpty);
  expect(descriptor['format'], 'gmd-frozen-request-journal-v1');
  expect(descriptor['file'], '$owner-$index.items.jsonl');
  expect(descriptor['count'], count);
  expect(descriptor['bytes'], await journal.length());
  expect(descriptor['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
  final lineCount = await journal
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .length;
  expect(lineCount, count);
  return {
    'owner': owner,
    'leaf_id': leaf['id'],
    'count': count,
    'bytes': await journal.length(),
    'file_sha256': await _fileHash(journal),
    'chain_head_sha256': descriptor['sha256'],
    'header_bytes': await headerFile.length(),
  };
}

Future<Map<String, Object?>> _sourceFiles(FrozenQuestionSuite suite) async {
  final source = suite.identity['id'] as String;
  final files = switch (source) {
    'jeval' => {
      'data/test.parquet': {
        'bytes': 33533925,
        'sha256': JevalSuite.parquetSha256,
      },
    },
    'coherence' => {
      for (final file in CoherenceSuite.resourceFiles)
        file['path'] as String: {
          'bytes': file['bytes'],
          'sha256': file['sha256'],
        },
    },
    'adversarial' => _object(suite.identity['sourceFiles']),
    _ => throw ArgumentError.value(source),
  };
  final actual = <String, Object?>{};
  for (final entry in files.entries) {
    final file = File('benchmarks/sources/$source/${entry.key}');
    final expected = entry.value as Map;
    final bytes = await file.length();
    final digest = await _fileHash(file);
    expect(bytes, expected['bytes']);
    expect(digest, expected['sha256']);
    actual[entry.key] = {'bytes': bytes, 'sha256': digest};
  }
  return actual;
}

Future<void> _recordEvidence(
  String name,
  Future<Map<String, Object?>> Function() body,
) async {
  final directory = Directory('.scratch/playground-benchmarks/implementation');
  await directory.create(recursive: true);
  final artifact = File('${directory.path}/question-scale-$name.json');
  final evidence = <String, Object?>{
    'scope': 'complete original inputs; cancelled persisted-record fixture',
    'inference_performed': false,
    'full_real_model_acceptance': false,
    'per_question_total_io_proven': false,
    'kernel_cumulative_write_bytes_measured': false,
    'test_body_passed': false,
    'process_exit_code': null,
    'outer_queue_must_attach_command_head_and_real_exit': true,
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'state': 'running',
  };
  await artifact.writeAsString(jsonEncode(evidence), flush: true);
  Object? originalFailure;
  try {
    final fingerprints = <String, Object?>{};
    for (final path in [
      'test/benchmark_question_scale_test.dart',
      'lib/benchmark_run_store.dart',
      'lib/frozen_question_suite.dart',
      'lib/jeval.dart',
      'lib/coherence_benchmark.dart',
      'lib/adversarial_benchmark.dart',
      'lib/jev_playground.dart',
      'lib/jev_debug.dart',
    ]) {
      final file = File(path);
      fingerprints[path] = {
        'bytes': await file.length(),
        'sha256': await _fileHash(file),
      };
    }
    evidence['source_fingerprints'] = fingerprints;
    evidence.addAll(await body());
    evidence['test_body_passed'] = true;
    evidence['state'] =
        'test-body-passed; awaiting outer process exit and teardown';
  } catch (error, stack) {
    originalFailure = error;
    evidence['state'] = 'failed';
    evidence['original_error'] = error.toString();
    evidence['original_stack'] = stack.toString();
    rethrow;
  } finally {
    evidence['finished_at'] = DateTime.now().toUtc().toIso8601String();
    try {
      await artifact.writeAsString(
        const JsonEncoder.withIndent('  ').convert(evidence),
        flush: true,
      );
    } catch (evidenceError) {
      if (originalFailure == null) {
        rethrow;
      }
      // Preserve the business assertion as the primary failure if recording
      // its diagnostic file also fails. The queue retains this cleanup error.
      stderr.writeln('Question-scale evidence write failed: $evidenceError');
    }
  }
}

Map<String, Object?> _object(Object? value) =>
    Map<String, Object?>.from(value as Map);

Future<String> _fileHash(File file, {int? end}) async =>
    (await sha256.bind(file.openRead(0, end)).first).toString();

class _ObservedRows extends ListBase<Map<String, Object?>> {
  final values = <Map<String, Object?>>[];
  final _readsPerRow = <int>[];
  bool observing = false;
  int reads = 0;
  int get maximumReadsPerRow => _readsPerRow.fold(0, (a, b) => a > b ? a : b);

  void append(Map<String, Object?> row) {
    values.add(row);
    _readsPerRow.add(0);
  }

  @override
  int get length => values.length;
  @override
  set length(int value) =>
      throw UnsupportedError('append sealed fixture rows only');
  @override
  Map<String, Object?> operator [](int index) {
    if (observing) {
      reads++;
      _readsPerRow[index]++;
    }
    return values[index];
  }

  @override
  void operator []=(int index, Map<String, Object?> value) =>
      throw UnsupportedError('sealed fixture row');
}

class _StreamingHash {
  final _output = _DigestSink();
  late final Sink<List<int>> _input = sha256.startChunkedConversion(_output);
  void add(String text) => _input.add(utf8.encode(text));
  String finish() {
    _input.close();
    return _output.value!.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
