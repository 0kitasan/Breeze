import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/util/get_path.dart';

const MethodChannel _filePickerChannel = MethodChannel(
  'com.zephyr.breeze/file_picker',
);

const List<String> localComicArchiveExtensions = <String>[
  'cbz',
  'cbr',
  'cb7',
  'cbt',
  'zip',
  'rar',
  '7z',
  'tar',
];

/// 用户选中的外部漫画来源。
class LocalComicPickResult {
  const LocalComicPickResult({
    required this.path,
    required this.isDirectory,
    this.cleanupRoot,
  });

  final String path;
  final bool isDirectory;

  /// Android 原生选择器已经把内容复制到该缓存目录；导入结束后删除。
  final String? cleanupRoot;
}

Future<LocalComicPickResult?> pickLocalComicArchive() async {
  if (Platform.isAndroid) {
    final destDir = await _createAndroidPickCacheDir();
    try {
      final payload = await _filePickerChannel.invokeMapMethod<String, dynamic>(
        'pickComicArchive',
        {'destDir': destDir},
      );
      if (payload == null) {
        await _deleteDir(destDir);
        return null;
      }
      final path = payload['path']?.toString() ?? '';
      if (path.isEmpty) {
        await _deleteDir(destDir);
        return null;
      }
      return LocalComicPickResult(
        path: path,
        isDirectory: false,
        cleanupRoot: payload['cleanupRoot']?.toString() ?? destDir,
      );
    } on PlatformException catch (e) {
      await _deleteDir(destDir);
      throw StateError(e.message ?? e.code);
    }
  }

  const typeGroup = XTypeGroup(
    label: 'comic archives',
    extensions: localComicArchiveExtensions,
    uniformTypeIdentifiers: <String>[
      'public.zip-archive',
      'com.rarlab.rar-archive',
      'org.7-zip.7-zip-archive',
      'public.tar-archive',
      'public.data',
    ],
  );
  final file = await openFile(acceptedTypeGroups: const [typeGroup]);
  if (file == null) return null;
  return LocalComicPickResult(path: file.path, isDirectory: false);
}

Future<LocalComicPickResult?> pickLocalComicDirectory() async {
  if (Platform.isIOS) return null;

  if (Platform.isAndroid) {
    final destDir = await _createAndroidPickCacheDir();
    try {
      final payload = await _filePickerChannel.invokeMapMethod<String, dynamic>(
        'pickComicDirectory',
        {'destDir': destDir},
      );
      if (payload == null) {
        await _deleteDir(destDir);
        return null;
      }
      final path = payload['path']?.toString() ?? '';
      if (path.isEmpty) {
        await _deleteDir(destDir);
        return null;
      }
      return LocalComicPickResult(
        path: path,
        isDirectory: true,
        cleanupRoot: payload['cleanupRoot']?.toString() ?? destDir,
      );
    } on PlatformException catch (e) {
      await _deleteDir(destDir);
      throw StateError(e.message ?? e.code);
    }
  }

  final path = await getDirectoryPath();
  if (path == null || path.trim().isEmpty) return null;
  return LocalComicPickResult(path: path, isDirectory: true);
}

Future<String> _createAndroidPickCacheDir() async {
  final cachePath = await getCachePath();
  final dir = Directory(
    p.join(
      cachePath,
      'local_comic_import',
      'pick_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await dir.create(recursive: true);
  return dir.path;
}

Future<void> _deleteDir(String path) async {
  try {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } catch (_) {}
}
