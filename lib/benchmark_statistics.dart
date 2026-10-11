/// Matches sum(float) in the fixed CPython 3.12 scoring reference.
/// Compensation preserves the upstream decisions at exact tolerance boundaries.
double benchmarkSum(Iterable<double> values) {
  var total = 0.0;
  var compensation = 0.0;
  for (final value in values) {
    final next = total + value;
    compensation += total.abs() >= value.abs()
        ? (total - next) + value
        : (value - next) + total;
    total = next;
  }
  return compensation != 0 && compensation.isFinite
      ? total + compensation
      : total;
}
