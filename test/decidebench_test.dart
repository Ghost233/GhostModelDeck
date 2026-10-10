import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/decidebench.dart';

void main() {
  test('complete original suite preserves all default JEV requests', () async {
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    expect(suite.items, hasLength(400));
    expect(suite.items.map((item) => item.pairId).toSet(), hasLength(200));
    expect(suite.identity['exampleCount'], 297);
    expect(suite.identity['templateCount'], 63);
    // Independent vector: the fixed author's build_body over all 400 items,
    // computed by the original Python implementation before Dart code existed.
    final requests = suite.items
        .map(
          (item) =>
              '${jsonEncode(item.request('__fixed_public_call_name__'))}\n',
        )
        .join();
    expect(
      sha256.convert(utf8.encode(requests)).toString(),
      '8c7c3a6f663dd9bc73131776c8bce67a32c3aacb5c1bf799b9e6cd0e77b4aa25',
    );
    expect(
      suite.items.first.request('kev-local').keys,
      orderedEquals(['model', 'state', 'questions']),
    );
    expect(suite.items.first.request('kev-local')['model'], 'kev-local');
  });

  test('original full400 scoring preserves failures and pair denominators', () async {
    final suite = await DecideBenchSuite.load(
      Directory('benchmarks/sources/decidebench'),
    );
    final correct = {for (final item in suite.items) item.id: item.gold};
    final wrong = {
      for (final item in suite.items)
        item.id: item.options.keys.firstWhere((key) => key != item.gold),
    };
    final oneWrong = {
      ...correct,
      suite.items.first.id: wrong[suite.items.first.id],
    };
    final unusable = {for (final item in suite.items) item.id: null};
    final oneUnusable = {...correct, suite.items.first.id: null};
    // Expected counts come from the author's score.summarize over the complete
    // 400 original labels, checked independently before this implementation.
    final vectors = [
      (correct, 400, 200, 0, 1.0, 1.0),
      (wrong, 0, 0, 0, 0.0, 0.0),
      (oneWrong, 399, 199, 0, 0.9975, 0.995),
      (unusable, 0, 0, 400, 0.0, 0.0),
      (oneUnusable, 399, 199, 1, 0.9975, 0.995),
    ];
    for (final vector in vectors) {
      final score = suite.score(vector.$1);
      expect(score.attempted, 400);
      expect(score.missing, 0);
      expect(score.complete, isTrue);
      expect(score.correct, vector.$2);
      expect(score.pairsCorrect, vector.$3);
      expect(score.unusable, vector.$4);
      expect(score.accuracy, vector.$5);
      expect(score.pairAccuracy, vector.$6);
      expect(score.brier, isNull);
      expect(score.ece, isNull);
    }
    final incomplete = suite.score({...correct}..remove(suite.items.first.id));
    expect(incomplete.attempted, 399);
    expect(incomplete.missing, 1);
    expect(incomplete.complete, isFalse);
    expect(incomplete.accuracy, isNull);
    expect(incomplete.pairAccuracy, isNull);
  });

  test(
    'original probability metrics require ninety percent real coverage',
    () async {
      final suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      final predictions = {for (final item in suite.items) item.id: item.gold};
      final probabilities = {
        for (final item in suite.items)
          item.id: {
            for (final key in item.options.keys)
              key: key == item.gold ? 0.8 : 0.2 / (item.options.length - 1),
          },
      };
      final all = suite.score(predictions, probabilities: probabilities);
      expect(all.brier, closeTo(0.05304666666666665, 1e-12));
      expect(all.ece, closeTo(0.19999999999999996, 1e-12));
      final enough = suite.score(
        predictions,
        probabilities: {
          for (final item in suite.items.take(360))
            item.id: probabilities[item.id]!,
        },
      );
      expect(enough.brier, closeTo(0.05339999999999998, 1e-12));
      expect(enough.ece, closeTo(0.19999999999999996, 1e-12));
      final insufficient = suite.score(
        predictions,
        probabilities: {
          for (final item in suite.items.take(359))
            item.id: probabilities[item.id]!,
        },
      );
      expect(insufficient.brier, isNull);
      expect(insufficient.ece, isNull);
    },
  );

  test(
    'response label extraction stays separate from probability validity',
    () async {
      final suite = await DecideBenchSuite.load(
        Directory('benchmarks/sources/decidebench'),
      );
      final item = suite.items.first;
      final valid = {
        'answers': {
          'decision': {
            'choice': item.gold,
            'probabilities': {
              for (final key in item.options.keys)
                key: key == item.gold ? 0.8 : 0.2 / (item.options.length - 1),
            },
          },
        },
      };
      expect(item.extractChoice(valid), item.gold);
      expect(item.extractProbabilities(valid), isNotNull);
      final missingProbs = {
        'answers': {
          'decision': {'choice': item.gold},
        },
      };
      expect(item.extractChoice(missingProbs), item.gold);
      expect(item.extractProbabilities(missingProbs), isNull);
      final badProbs = {
        'answers': {
          'decision': {
            'choice': item.gold,
            'probabilities': {item.gold: 0.8},
          },
        },
      };
      expect(item.extractChoice(badProbs), item.gold);
      expect(item.extractProbabilities(badProbs), isNull);
      expect(item.extractChoice(const {}), isNull);
      expect(
        item.extractChoice({
          'answers': {
            'decision': {'choice': 'unknown'},
          },
        }),
        isNull,
      );
    },
  );
}
