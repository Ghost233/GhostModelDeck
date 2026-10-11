import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/embedding_protocol.dart';

void main() {
  test('公开嵌入请求保留原文，批次响应按输入索引关联有限向量和实际用量', () {
    final request = EmbeddingRequest.fromJson({
      'model': 'embedding-model',
      'input': [' query: 苹果 ', 'passage: 水果'],
      'dimensions': 2,
    });
    expect(request.input, [' query: 苹果 ', 'passage: 水果']);
    final result = EmbeddingResult.parse(
      jsonEncode({
        'object': 'list',
        'model': 'embedding-model',
        'data': [
          {
            'object': 'embedding',
            'index': 1,
            'embedding': [0, 4],
          },
          {
            'object': 'embedding',
            'index': 0,
            'embedding': [3, 0],
          },
        ],
        'usage': {'prompt_tokens': 8, 'total_tokens': 8},
      }),
      request: request,
    );
    expect(result.vectors, [
      [3.0, 0.0],
      [0.0, 4.0],
    ]);
    expect(result.dimensions, 2);
    expect(result.norm(0), 3);
    expect(result.cosineSimilarity(0, 1), 0);
    expect(result.usage['prompt_tokens'], 8);
  });

  test('嵌入请求拒绝token数组、空批次、base64和无效维度', () {
    for (final input in [
      [],
      [1, 2],
      ['valid', ''],
      '',
      null,
    ]) {
      expect(
        () => EmbeddingRequest.fromJson({'model': 'm', 'input': input}),
        throwsA(isA<EmbeddingProtocolException>()),
      );
    }
    for (final dimensions in [0, -1, 1.5, '128']) {
      expect(
        () => EmbeddingRequest.fromJson({
          'model': 'm',
          'input': 'text',
          'dimensions': dimensions,
        }),
        throwsA(isA<EmbeddingProtocolException>()),
      );
    }
    expect(
      () => EmbeddingRequest.fromJson({
        'model': 'm',
        'input': 'text',
        'encoding_format': 'base64',
      }),
      throwsA(isA<EmbeddingProtocolException>()),
    );
  });

  test('嵌入响应拒绝错误模型、重复/缺失索引、不等长向量和缺失用量', () {
    final request = EmbeddingRequest.fromJson({
      'model': 'm',
      'input': ['a', 'b'],
    });
    Map<String, Object?> response() => {
      'model': 'm',
      'data': [
        {
          'index': 0,
          'embedding': [1, 0],
        },
        {
          'index': 1,
          'embedding': [0, 1],
        },
      ],
      'usage': {'prompt_tokens': 2, 'total_tokens': 2},
    };
    final invalid = [
      response()..['model'] = 'other',
      response()..remove('usage'),
      response()
        ..['data'] = [
          {
            'index': 0,
            'embedding': [1],
          },
        ],
      response()
        ..['data'] = [
          {
            'index': 0,
            'embedding': [1],
          },
          {
            'index': 0,
            'embedding': [1],
          },
        ],
      response()
        ..['data'] = [
          {
            'index': 0,
            'embedding': [1],
          },
          {
            'index': 1,
            'embedding': [0, 1],
          },
        ],
      response()
        ..['data'] = [
          {
            'index': 0,
            'embedding': ['1'],
          },
          {
            'index': 1,
            'embedding': [1],
          },
        ],
    ];
    for (final value in invalid) {
      expect(
        () => EmbeddingResult.parse(jsonEncode(value), request: request),
        throwsA(isA<EmbeddingProtocolException>()),
      );
    }
  });

  test('未指定维度时保留引擎真实宽度，零向量不伪造余弦相似度', () {
    final request = EmbeddingRequest.fromJson({
      'model': 'm',
      'input': ['a', 'b'],
    });
    final result = EmbeddingResult.parse(
      jsonEncode({
        'model': 'm',
        'data': [
          {
            'index': 0,
            'embedding': [0, 0, 0],
          },
          {
            'index': 1,
            'embedding': [0, 0, 2],
          },
        ],
        'usage': {'prompt_tokens': 2, 'total_tokens': 2},
      }),
      request: request,
    );
    expect(result.dimensions, 3);
    expect(result.norm(0), 0);
    expect(result.cosineSimilarity(0, 1), isNull);
  });

  test('引擎显式alias绑定不会接受公开model或其他实例的响应', () {
    final request = EmbeddingRequest.fromJson({
      'model': 'public-model',
      'input': 'a',
    });
    expect(request.toJson(model: 'engine-alias')['model'], 'engine-alias');
    String response(String model) => jsonEncode({
      'model': model,
      'data': [
        {
          'index': 0,
          'embedding': [1],
        },
      ],
      'usage': {'prompt_tokens': 1, 'total_tokens': 1},
    });
    expect(
      EmbeddingResult.parse(
        response('engine-alias'),
        request: request,
        expectedModel: 'engine-alias',
      ).model,
      'engine-alias',
    );
    expect(
      () => EmbeddingResult.parse(
        response('public-model'),
        request: request,
        expectedModel: 'engine-alias',
      ),
      throwsA(isA<EmbeddingProtocolException>()),
    );
  });
}
