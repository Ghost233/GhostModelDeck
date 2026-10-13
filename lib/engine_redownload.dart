import 'dart:io';

/// Replaces only a managed installation, restoring it if downloading fails.
Future<void> redownloadEngine(
  Directory target,
  Future<void> Function() install,
) async {
  await target.parent.create(recursive: true);
  final type = await FileSystemEntity.type(target.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      (type != FileSystemEntityType.directory ||
          await target.resolveSymbolicLinks() != target.absolute.path)) {
    throw StateError('重新下载目标不是受管目录');
  }
  final staging = await target.parent.createTemp('.gmd-redownload-');
  final previous = Directory('${staging.path}/previous');
  var backedUp = false;
  try {
    if (type == FileSystemEntityType.directory) {
      await target.rename(previous.path);
      backedUp = true;
    }
    try {
      await install();
    } catch (error) {
      if (backedUp) {
        try {
          if (await target.exists()) {
            if (await target.resolveSymbolicLinks() != target.absolute.path) {
              throw StateError('重新下载目标路径发生变化');
            }
            await target.delete(recursive: true);
          }
          await previous.rename(target.path);
          backedUp = false;
        } catch (restore) {
          throw StateError('$error；原安装恢复失败：$restore；保留位置：${previous.path}');
        }
      }
      rethrow;
    }
    if (backedUp) {
      await previous.delete(recursive: true);
      backedUp = false;
    }
  } finally {
    if (!backedUp) await staging.delete(recursive: true);
  }
}
