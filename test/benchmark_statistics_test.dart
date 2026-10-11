import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/benchmark_statistics.dart';

void main() {
  test('original floating sums match independent CPython 3.12 literals', () {
    expect(benchmarkSum(List<double>.filled(10, 0.1)), 1.0);
    expect(benchmarkSum([1e16, 1.0, -1e16]), 1.0);
    expect(benchmarkSum([0.1, 0.2, -0.3]), 2.7755575615628914e-17);
    expect(benchmarkSum([0.2, 0.3, 0.5]), 1.0);
    expect(benchmarkSum(const []), 0.0);
  });
}
