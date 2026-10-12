import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_model_deck/engine_catalog.dart';
import 'package:ghost_model_deck/engine_labels.dart';
import 'package:ghost_model_deck/llama_engine.dart';

void main() {
  test('repository labels use the owner/repo for HTTPS, releases and SSH', () {
    for (final source in [
      'https://github.com/1bananachicken/MaaNTE/releases',
      'https://github.com/1bananachicken/MaaNTE.git',
      'git@github.com:1bananachicken/MaaNTE.git',
    ]) {
      expect(repositoryDisplayLabel(source), '1bananachicken/MaaNTE');
    }
    expect(
      repositoryDisplayLabel('/Users/me/code/Local Git'),
      '/Users/me/code/Local Git',
    );
  });

  test('existing custom names are preserved but labels use actual source', () {
    const entry = EngineRegistration(
      id: 'source-existing',
      name: 'Qwen candidate-logits local Git',
      source: EngineSource.linked,
      status: LlamaInstallationStatus.installed,
      path: '/managed/build/bin/llama-server',
      sourceBuild: {'source': '/Users/me/code/llama.cpp'},
    );
    expect(engineDisplayName(entry), 'llama.cpp');
    expect(engineSourceLabel(entry), '/Users/me/code/llama.cpp');
    expect(entry.name, 'Qwen candidate-logits local Git');
    final managed = EngineRegistration(
      id: EngineCatalog.standardId,
      name: 'llama.cpp · 标准 v0.5.0',
      source: EngineSource.managed,
      status: LlamaInstallationStatus.absent,
      release: standardLlamaRelease,
    );
    expect(engineDisplayName(managed), 'llama.cpp · b11146');
    expect(engineSourceLabel(managed), 'ggml-org/llama.cpp');
  });
}
