import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_game_record.dart';
import 'package:ghost_model_deck/jev_playground.dart';

void main() {
  test(
    'game journal validates original trace identity and seals partial evidence',
    () {
      final original = _partial();
      final record = BenchmarkGameRecord.parse(
        original,
        model: 'native-kev',
        channel: JevPlaygroundMode.http,
      );
      expect(record.toJson(), original);
      expect(record.toJson()['complete'], isFalse);
      expect((record.toJson()['recording'] as Map)['frames'], [0.016]);
      (original['result'] as Map)['score'] = 99;
      expect((record.toJson()['result'] as Map)['score'], 0);
      expect(
        () => (record.toJson()['recording'] as Map)['model'] = 'other',
        throwsUnsupportedError,
      );
      for (final invalid in [
        _partial()..['index'] = 101,
        _partial()..['costKnown'] = 'unknown',
        _partial()
          ..['result'] = {...(_partial()['result'] as Map), 'score': 99},
        _partial()
          ..['recording'] = {
            ...(_partial()['recording'] as Map),
            'model': 'other',
          },
        _partial()
          ..['calls'] = [
            {
              'phase': 'game',
              'game': 2,
              'request': {'model': 'native-kev'},
            },
          ],
      ]) {
        expect(
          () => BenchmarkGameRecord.parse(
            invalid,
            model: 'native-kev',
            channel: JevPlaygroundMode.http,
          ),
          throwsFormatException,
        );
      }
    },
  );
}

Map<String, Object?> _partial() => {
  'index': 1,
  'complete': false,
  'costKnown': false,
  'result': {
    'survived': 0.016,
    'score': 0,
    'pellets': 0,
    'deaths': 0,
    'level': 1,
    'calls': 0,
    'decisions': 0,
    'fallbacks': 0,
    'latencyMsSum': 0,
    'cost': 0,
    'fruitSpawned': 0,
    'fruitEaten': 0,
    'ghostsEaten': 0,
    'deathsBy': <String, Object?>{},
  },
  'recording': {
    'version': 1,
    'recordedAt': '2026-10-10T00:00:00Z',
    'model': 'native-kev',
    'frames': [0.016],
    'decisions': <Object?>[],
    'events': <Object?>[],
    'final': {'score': 0, 'lives': 3, 'level': 1, 'frames': 1},
  },
  'calls': <Object?>[],
};
