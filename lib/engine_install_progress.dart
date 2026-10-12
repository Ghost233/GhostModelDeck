enum EngineInstallPhase {
  downloading,
  verifying,
  unpacking,
  complete,
  cancelled,
  failed,
}

class EngineInstallProgress {
  const EngineInstallProgress(
    this.phase, {
    this.received = 0,
    required this.total,
    this.error,
  });
  final EngineInstallPhase phase;
  final int received;
  final int total;
  final String? error;
  bool get active => [
    EngineInstallPhase.downloading,
    EngineInstallPhase.verifying,
    EngineInstallPhase.unpacking,
  ].contains(phase);
}
