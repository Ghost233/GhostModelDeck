/// External engine wire fixture, not protocol/controller/business state.
Map<String, Object> typedAnswers(Map questions) => {
  for (final entry in questions.entries)
    entry.key as String: switch (entry.value['type']) {
      'score' => {
        'type': 'score',
        'score': 0.75,
        'legend': {
          for (var i = 0; i < (entry.value['criteria'] as List).length; i++)
            '$i': entry.value['criteria'][i],
        },
        'probabilities': {
          for (var i = 0; i < (entry.value['criteria'] as List).length; i++)
            '$i': i == 0
                ? 0.25
                : i == 1
                ? 0.75
                : 0.0,
        },
      },
      'noul' => {'type': 'noul', 'noul': 0.8},
      _ => {
        'type': 'choice',
        'choice': (entry.value['criteria'] as Map).keys.last,
        'probabilities': {
          for (final id in (entry.value['criteria'] as Map).keys)
            id: id == (entry.value['criteria'] as Map).keys.first
                ? 0.25
                : id == (entry.value['criteria'] as Map).keys.last
                ? 0.75
                : 0.0,
        },
      },
    },
};
