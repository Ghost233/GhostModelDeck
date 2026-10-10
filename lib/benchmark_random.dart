/// CPython MT19937 streams used by the published benchmark statistics.
/// The source reports use a fixed integer seed; this is not model sampling.
class BenchmarkRandom {
  BenchmarkRandom({int seed = 0}) {
    if (seed < 0 || seed > _mask) {
      throw RangeError.range(seed, 0, _mask, 'seed');
    }
    _state[0] = 19650218;
    for (var i = 1; i < 624; i++) {
      final previous = _state[i - 1];
      _state[i] = (1812433253 * (previous ^ (previous >>> 30)) + i) & _mask;
    }
    var i = 1;
    for (var k = 0; k < 624; k++) {
      final previous = _state[i - 1];
      _state[i] =
          ((_state[i] ^ ((previous ^ (previous >>> 30)) * 1664525)) + seed) &
          _mask;
      if (++i == 624) {
        _state[0] = _state[623];
        i = 1;
      }
    }
    for (var k = 0; k < 623; k++) {
      final previous = _state[i - 1];
      _state[i] =
          ((_state[i] ^ ((previous ^ (previous >>> 30)) * 1566083941)) - i) &
          _mask;
      if (++i == 624) {
        _state[0] = _state[623];
        i = 1;
      }
    }
    _state[0] = 0x80000000;
  }

  static const _mask = 0xffffffff;
  final _state = List<int>.filled(624, 0);
  int _position = 624;

  int _nextUint32() {
    if (_position == 624) {
      for (var i = 0; i < 624; i++) {
        final value =
            (_state[i] & 0x80000000) | (_state[(i + 1) % 624] & 0x7fffffff);
        _state[i] =
            _state[(i + 397) % 624] ^
            (value >>> 1) ^
            (value.isOdd ? 0x9908b0df : 0);
      }
      _position = 0;
    }
    var value = _state[_position++];
    value ^= value >>> 11;
    value ^= (value << 7) & 0x9d2c5680;
    value ^= (value << 15) & 0xefc60000;
    value ^= value >>> 18;
    return value & _mask;
  }

  int getrandbits(int bits) {
    if (bits < 0 || bits > 32) {
      throw RangeError.range(bits, 0, 32, 'bits');
    }
    return bits == 0 ? 0 : _nextUint32() >>> (32 - bits);
  }

  int index(int length) {
    if (length <= 0) throw RangeError.value(length, 'length');
    var value = getrandbits(length.bitLength);
    while (value >= length) {
      value = getrandbits(length.bitLength);
    }
    return value;
  }

  double nextDouble() =>
      ((_nextUint32() >>> 5) * 67108864.0 + (_nextUint32() >>> 6)) /
      9007199254740992.0;
}
