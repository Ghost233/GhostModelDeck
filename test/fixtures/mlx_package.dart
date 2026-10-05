import 'dart:convert';
import 'dart:typed_data';

/// Tiny structural I/O fixture, not runnable Qwen weights. File roles follow the
/// fixed a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 MLX acceptance manifest.
Map<String, List<int>> mlxPackageBytes() {
  final header = utf8.encode(
    jsonEncode({
      'layer.weight': {
        'dtype': 'F32',
        'shape': [1],
        'data_offsets': [0, 4],
      },
    }),
  );
  return {
    'model.safetensors': [
      ...(ByteData(
        8,
      )..setUint64(0, header.length, Endian.little)).buffer.asUint8List(),
      ...header,
      0,
      0,
      0,
      0,
    ],
    'config.json': utf8.encode(
      '{"model_type":"qwen2","architectures":["Qwen2ForCausalLM"],"quantization":{"bits":4,"group_size":64}}',
    ),
    'model.safetensors.index.json': utf8.encode(
      '{"weight_map":{"layer.weight":"model.safetensors"}}',
    ),
    'tokenizer.json': utf8.encode(
      '{"model":{"type":"BPE","vocab":{"hello":0},"merges":[]}}',
    ),
    'tokenizer_config.json': utf8.encode(
      '{"chat_template":"{% for message in messages %}{{ message.content }}{% endfor %}"}',
    ),
    'special_tokens_map.json': utf8.encode('{"eos_token":"hello"}'),
    'added_tokens.json': utf8.encode('{"hello":0}'),
    'vocab.json': utf8.encode('{"hello":0}'),
    'merges.txt': utf8.encode('#version: 0.2\nh e\n'),
  };
}
