import 'dart:convert';
import 'dart:typed_data';

/// Real serialized U32/F16 ranges, but zero payload is NOT runnable model proof.
class Qwen2MlxFixture {
  Qwen2MlxFixture({int layers = 1}) {
    config['num_hidden_layers'] = layers;
    triplet('model.embed_tokens', 4);
    tensors['model.norm.weight'] = ('F16', [64]);
    for (var layer = 0; layer < layers; layer++) {
      final prefix = 'model.layers.$layer';
      for (final entry in {
        'self_attn.q_proj': 64,
        'self_attn.k_proj': 32,
        'self_attn.v_proj': 32,
        'self_attn.o_proj': 64,
        'mlp.gate_proj': 64,
        'mlp.up_proj': 64,
        'mlp.down_proj': 64,
      }.entries) {
        triplet('$prefix.${entry.key}', entry.value);
      }
      for (final entry in {'q': 64, 'k': 32, 'v': 32}.entries) {
        tensors['$prefix.self_attn.${entry.key}_proj.bias'] = (
          'F16',
          [entry.value],
        );
      }
      for (final name in ['input_layernorm', 'post_attention_layernorm']) {
        tensors['$prefix.$name.weight'] = ('F16', [64]);
      }
    }
  }
  final config = <String, Object?>{
    'model_type': 'qwen2',
    'architectures': ['Qwen2ForCausalLM'],
    'hidden_size': 64,
    'intermediate_size': 64,
    'num_attention_heads': 2,
    'num_key_value_heads': 1,
    'vocab_size': 4,
    'quantization': {'bits': 4, 'group_size': 64},
    'tie_word_embeddings': true,
    'rms_norm_eps': 0.000001,
    'rope_theta': 1000000,
    'max_position_embeddings': 128,
    'hidden_act': 'silu',
    'use_sliding_window': false,
    // Metadata is deliberately different from the actual serialized precision.
    'torch_dtype': 'bfloat16',
  };
  final tensors = <String, (String, List<int>)>{};
  void triplet(String name, int rows) {
    tensors['$name.weight'] = ('U32', [rows, 8]);
    tensors['$name.scales'] = ('F16', [rows, 1]);
    tensors['$name.biases'] = ('F16', [rows, 1]);
  }

  Map<String, List<int>> bytes({bool indexed = true, int shards = 1}) {
    final files = <String, List<int>>{};
    final mapping = <String, String>{};
    final entries = tensors.entries.toList();
    for (var shard = 0; shard < shards; shard++) {
      final name = shards == 1
          ? 'model.safetensors'
          : 'model-$shard.safetensors';
      final header = <String, Object?>{
        '__metadata__': {'format': 'mlx'},
      };
      var size = 0;
      for (var i = shard; i < entries.length; i += shards) {
        final entry = entries[i];
        final (dtype, shape) = entry.value;
        final length =
            shape.fold(1, (a, b) => a * b) *
            (dtype == 'U32' || dtype == 'I32' || dtype == 'F32' ? 4 : 2);
        header[entry.key] = {
          'dtype': dtype,
          'shape': shape,
          'data_offsets': [size, size + length],
        };
        size += length;
        mapping[entry.key] = name;
      }
      final encoded = utf8.encode(jsonEncode(header));
      files[name] = [
        ...(ByteData(
          8,
        )..setUint64(0, encoded.length, Endian.little)).buffer.asUint8List(),
        ...encoded,
        ...Uint8List(size),
      ];
    }
    files.addAll({
      'config.json': utf8.encode(jsonEncode(config)),
      if (indexed)
        'model.safetensors.index.json': utf8.encode(
          jsonEncode({'weight_map': mapping}),
        ),
      'tokenizer.json': utf8.encode(
        '{"model":{"type":"BPE","vocab":{"hello":0},"merges":[]}}',
      ),
      'tokenizer_config.json': utf8.encode(
        '{"chat_template":"{{ messages }}"}',
      ),
    });
    return files;
  }
}
