import 'dart:convert';

import 'jev_playground.dart';

/// Original published requests and the source's independent scoring rules.
abstract interface class FrozenQuestionSuite {
  Map<String, Object?> get identity;
  List<FrozenQuestionTask> get tasks;
  FrozenQuestionAccumulator createAccumulator();
}

class FrozenQuestionTask {
  FrozenQuestionTask({
    required this.id,
    required Map<String, Object?> body,
    required Map<String, Object?> metadata,
    this.questionsJson,
  }) : body = Map.unmodifiable(body),
       metadata = Map.unmodifiable(metadata) {
    if (questionsJson != null &&
        jsonEncode(jsonDecode(questionsJson!)) !=
            jsonEncode(body['questions'])) {
      throw const FormatException('原始问题 JSON 与任务字段不一致');
    }
  }

  final String id;
  final Map<String, Object?> body;
  final Map<String, Object?> metadata;
  final String? questionsJson;

  Map<String, Object?> request(String publicModel) => {
    'model': publicModel,
    for (final entry in body.entries)
      if (entry.key != 'model') entry.key: entry.value,
  };

  String requestDocument(String publicModel) {
    final payload = request(publicModel);
    if (questionsJson == null) return jsonEncode(payload);
    return '{${payload.entries.map((entry) => '${jsonEncode(entry.key)}:'
        '${entry.key == 'questions' ? questionsJson : jsonEncode(entry.value)}').join(',')}}';
  }
}

abstract interface class FrozenQuestionAccumulator {
  /// Returns source-specific fields retained beside the ordinary client result.
  Map<String, Object?> record(
    FrozenQuestionTask task,
    JevPlaygroundResult reply,
  );

  /// Complete scores are available only for a completed full original suite.
  FrozenQuestionScore snapshot({required bool complete});
}

class FrozenQuestionScore {
  const FrozenQuestionScore({required this.summary, required this.groups});

  final Map<String, Object?> summary;
  final List<Map<String, Object?>> groups;
}
