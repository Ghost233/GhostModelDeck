import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/jev_debug.dart';

void main() {
  test('rejected benchmark output cannot grant task roles to malformed credential fields', () {
    const secret = 'malformed-response-credential';
    final malformed = {
      'model': 'public-name',
      'answers': {
        'decision': {
          'type': 'choice',
          'choice': 'allow',
          'probabilities': {'API_KEY': secret},
        },
      },
      'echo': secret,
    };
    final safe = sealDebugJson({
      'items': [
        {
          'result': {'status': 'invalidResponse', 'output': malformed},
        },
      ],
    }, projection: JevDebugProjection.benchmarkRun);
    expect(safe.toString(), isNot(contains(secret)));
    final result = ((safe['items'] as List).single as Map)['result'] as Map;
    expect(
      (((result['output'] as Map)['answers'] as Map)['decision']
          as Map)['probabilities'],
      {'API_KEY': '[redacted]'},
    );
  });
  test('benchmark evidence preserves original tasks and removes cross-area credentials', () {
    const credential = 'benchmark-owned-secret';
    final request = {
      'model': 'api_key: public-name',
      'state': {'authorization': 'allow', 'echo': credential},
      'questions': {
        'api_key': {
          'type': 'choice',
          'instructions': 'Authorization: allow is task content.',
          'criteria': {'authorization': 'Allow', 'cookie': 'Reject'},
        },
      },
    };
    final safe = sealDebugJson({
      'model': 'api_key: public-name',
      'identity': {
        'model': 'api_key: public-name',
        'source': 'council',
        'configuration': {'name': 'api_key: public-name'},
        'api_key': credential,
        'unknown': {
          'request': {
            'model': 'untrusted',
            'state': {'authorization': 'metadata-only-secret'},
            'questions': {
              'decision': {
                'type': 'choice',
                'instructions': 'Metadata question',
                'criteria': {'a': 'A', 'b': 'B'},
              },
            },
          },
        },
      },
      'items': [
        {
          'id': 'api_key: original-id',
          'pair_id': 'authorization: original-pair',
          'gold': 'authorization',
          'request': request,
          'result': {
            'status': 'success',
            'request': request,
            'output': {
              'model': 'api_key: public-name',
              'answers': {
                'api_key': {
                  'type': 'choice',
                  'choice': 'authorization',
                  'probabilities': {'authorization': 0.5, 'cookie': 0.5},
                },
              },
            },
          },
        },
      ],
    }, projection: JevDebugProjection.benchmarkRun);
    expect(safe['model'], 'api_key: public-name');
    final item = (safe['items'] as List).single as Map;
    expect(item['id'], 'api_key: original-id');
    expect(item['pair_id'], 'authorization: original-pair');
    final submitted = item['request'] as Map;
    expect(submitted['state'], {
      'authorization': 'allow',
      'echo': '[redacted]',
    });
    expect(submitted['questions'], request['questions']);
    expect((item['result'] as Map)['request'], submitted);
    expect((safe['identity'] as Map)['api_key'], '[redacted]');
    expect((safe['identity'] as Map)['model'], 'api_key: public-name');
    expect(
      ((safe['identity'] as Map)['configuration'] as Map)['name'],
      'api_key: public-name',
    );
    final unknown = (safe['identity'] as Map)['unknown'] as Map;
    expect(
      ((unknown['request'] as Map)['state'] as Map)['authorization'],
      '[redacted]',
    );
    expect(safe.toString(), isNot(contains(credential)));
  });
}
