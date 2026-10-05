import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

List<int> engineArchive() {
  final body = utf8.encode('server fixture');
  final header = Uint8List(512);
  void field(int offset, int length, String value) =>
      header.setRange(offset, offset + value.length, ascii.encode(value));
  field(0, 100, 'llama-b11381/llama-server');
  field(100, 8, '0000755\x00');
  field(108, 8, '0000000\x00');
  field(116, 8, '0000000\x00');
  field(124, 12, '${body.length.toRadixString(8).padLeft(11, '0')}\x00');
  field(136, 12, '00000000000\x00');
  header.fillRange(148, 156, 32);
  header[156] = 48;
  field(257, 6, 'ustar\x00');
  field(263, 2, '00');
  field(
    148,
    8,
    '${header.fold(0, (a, b) => a + b).toRadixString(8).padLeft(6, '0')}\x00 ',
  );
  return gzip.encode([
    ...header,
    ...body,
    ...List.filled((512 - body.length % 512) % 512 + 1024, 0),
  ]);
}
