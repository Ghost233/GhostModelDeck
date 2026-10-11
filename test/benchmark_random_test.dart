import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_random.dart';

void main() {
  test(
    'fixed seed reproduces independent CPython bootstrap random streams',
    () {
      final bits = BenchmarkRandom(seed: 0);
      expect(
        [for (var i = 0; i < 10; i++) bits.getrandbits(32)],
        [
          3626764237,
          1654615998,
          3255389356,
          3823568514,
          1806341205,
          173879092,
          1112038970,
          4146640122,
          2195908194,
          2087043557,
        ],
      );
      final indices = BenchmarkRandom(seed: 0);
      expect(
        [for (var i = 0; i < 20; i++) indices.index(240)],
        [
          216,
          98,
          194,
          227,
          107,
          10,
          66,
          130,
          124,
          103,
          235,
          200,
          212,
          77,
          122,
          91,
          149,
          228,
          232,
          55,
        ],
      );
      final doubles = BenchmarkRandom(seed: 0);
      expect(
        [for (var i = 0; i < 10; i++) doubles.nextDouble()],
        [
          0.8444218515250481,
          0.7579544029403025,
          0.420571580830845,
          0.25891675029296335,
          0.5112747213686085,
          0.4049341374504143,
          0.7837985890347726,
          0.30331272607892745,
          0.4765969541523558,
          0.5833820394550312,
        ],
      );
    },
  );
}
