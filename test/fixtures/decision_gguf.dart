import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<File> writeDecisionKev(Directory root) async {
  final fields = <String, Object>{
    'general.architecture': 'qwen35',
    'qwen35.block_count': 1,
    'qwen35.embedding_length': 1,
    'qwen35.embedding_length_out': 2,
    'qwen35.attention.head_count': 1,
    'qwen35.attention.head_count_kv': 1,
    'qwen35.attention.key_length': 1,
    'qwen35.attention.value_length': 1,
    'qwen35.full_attention_interval': 1,
    'qwen35.feed_forward_length': 1,
    'qwen35.context_length': 16,
    'qwen35.attention.layer_norm_rms_epsilon': 0.000001,
    'qwen35.rope.dimension_sections': [1, 0, 0, 0],
    'qwen35.ssm.conv_kernel': 1,
    'qwen35.ssm.inner_size': 1,
    'qwen35.ssm.state_size': 1,
    'qwen35.ssm.time_step_rank': 1,
    'qwen35.ssm.group_count': 1,
    'qwen35.decision.type': 'kev',
    'qwen35.decision.temperature.choice': 1.0,
    'qwen35.decision.temperature.score': 1.0,
    'qwen35.decision.temperature.noul': 1.0,
    'tokenizer.ggml.model': 'gpt2',
    'tokenizer.ggml.tokens': ['token'],
    'tokenizer.chat_template.systemone': '{{ state }}{{ instructions }}{% for o in options %}{{ o.key }}{% endfor %}',
  };
  final tensors = <String, List<int>>{
    'token_embd.weight': [1, 1],
    'output_norm.weight': [1],
    'blk.0.attn_norm.weight': [1],
    'blk.0.post_attention_norm.weight': [1],
    'blk.0.attn_q.weight': [1, 2],
    'blk.0.attn_k.weight': [1, 1],
    'blk.0.attn_v.weight': [1, 1],
    'blk.0.attn_output.weight': [1, 1],
    'blk.0.attn_q_norm.weight': [1],
    'blk.0.attn_k_norm.weight': [1],
    'blk.0.ffn_gate.weight': [1, 1],
    'blk.0.ffn_up.weight': [1, 1],
    'blk.0.ffn_down.weight': [1, 1],
    'cls.output.weight': [1, 2],
    'cls.output.bias': [2],
  };
  final bytes = BytesBuilder()..add([71, 71, 85, 70]);
  void u32(int value) => bytes.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(int value) => bytes.add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void string(String value) {
    final encoded = utf8.encode(value);
    u64(encoded.length);
    bytes.add(encoded);
  }

  u32(3);
  u64(tensors.length);
  u64(fields.length);
  for (final entry in fields.entries) {
    string(entry.key);
    switch (entry.value) {
      case String value:
        u32(8);
        string(value);
      case int value:
        u32(4);
        u32(value);
      case double value:
        u32(6);
        bytes.add(
          (ByteData(
            4,
          )..setFloat32(0, value, Endian.little)).buffer.asUint8List(),
        );
      case List<String> value:
        u32(9);
        u32(8);
        u64(value.length);
        for (final item in value) {
          string(item);
        }
      case List<int> value:
        u32(9);
        u32(4);
        u64(value.length);
        for (final item in value) {
          u32(item);
        }
    }
  }
  var offset = 0;
  for (final tensor in tensors.entries) {
    string(tensor.key);
    u32(tensor.value.length);
    for (final dimension in tensor.value) {
      u64(dimension);
    }
    u32(0);
    u64(offset);
    final size = tensor.value.fold(4, (a, b) => a * b);
    offset += ((size + 31) ~/ 32) * 32;
  }
  bytes.add(Uint8List((32 - bytes.length % 32) % 32 + offset));
  final file = File('${root.path}/author/Kev/Kev-Q8_0.gguf');
  await file.parent.create(recursive: true);
  return file.writeAsBytes(bytes.toBytes());
}
