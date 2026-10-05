import 'model_library.dart';

class ModelUseRegistry {
  ModelUseRegistry(this.library);
  final ModelLibrary library;
  final _owners = <Object, Set<String>>{};
  Future<void> _pending = Future.value();
  Future<void> update(Object owner, Iterable<String> paths) {
    final selected = paths.toSet();
    final operation = _pending.then((_) async {
      final next = {..._owners, owner: selected};
      await library.setFilesInUse(next.values.expand((value) => value));
      if (selected.isEmpty) {
        _owners.remove(owner);
      } else {
        _owners[owner] = selected;
      }
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
