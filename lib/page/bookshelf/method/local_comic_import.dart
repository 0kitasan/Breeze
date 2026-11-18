import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/method/local_comic_scanner.dart';
import 'package:zephyr/page/bookshelf/service/comic_link_service.dart';
import 'package:zephyr/plugin/local_comic_plugin.dart';
import 'package:zephyr/service/download/download_asset_store.dart';
import 'package:zephyr/src/rust/api/comic_archive.dart';
import 'package:zephyr/src/rust/api/simple.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/get_path.dart';

/// 外部漫画导入结果。
class LocalComicImportResult {
  const LocalComicImportResult({
    required this.comicId,
    required this.title,
    required this.chapterCount,
    required this.imageCount,
  });

  final String comicId;
  final String title;
  final int chapterCount;
  final int imageCount;
}

/// 已准备就绪的外部漫画扫描会话。
///
/// 源内容已经复制/解压到缓存目录，[dispose] 会删除缓存。
class LocalComicScanSession {
  LocalComicScanSession({required this.scan, required this.workingRoot});

  final LocalComicScanResult scan;
  final Directory workingRoot;

  Future<void> dispose() async {
    try {
      if (await workingRoot.exists()) {
        await workingRoot.delete(recursive: true);
      }
    } catch (e) {
      logger.w('删除外部漫画导入缓存失败: ${workingRoot.path}', error: e);
    }
  }
}

/// 把外部漫画源复制到缓存并扫描。
///
/// 调用方必须在使用完 [LocalComicScanSession.scan] 后调用
/// [LocalComicScanSession.dispose]。
Future<LocalComicScanSession> prepareLocalComicScan({
  required String sourcePath,
  required bool isDirectory,
  String? title,
  String? cleanupRoot,
  String uncategorizedName = '未分类',
  String rootGroupTitle = '',
}) async {
  final source = isDirectory ? Directory(sourcePath) : File(sourcePath);
  if (!await source.exists()) {
    throw StateError('comic source not found: $sourcePath');
  }
  if (!isDirectory && !LocalComicScanner.isArchiveFile(sourcePath)) {
    throw StateError('unsupported comic archive: $sourcePath');
  }

  final displayTitle = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : (isDirectory
            ? p.basename(sourcePath)
            : p.basenameWithoutExtension(sourcePath));

  final workingRoot = cleanupRoot != null
      ? Directory(cleanupRoot)
      : await _createWorkingRoot();

  try {
    final contentPath = cleanupRoot != null
        ? sourcePath
        : await _copySourceToCache(
            sourcePath: sourcePath,
            isDirectory: isDirectory,
            workingRoot: workingRoot,
          );

    final scanRoot = !isDirectory
        ? await _extractRootArchive(
            archivePath: contentPath,
            workingRoot: workingRoot,
          )
        : contentPath;

    var extractIndex = 0;
    final scanner = LocalComicScanner(uncategorizedName: uncategorizedName);
    var scan = await scanner.scanDirectory(
      scanRoot,
      title: displayTitle,
      rootGroupTitle: rootGroupTitle,
      extractArchive: (archive) async {
        final target = p.join(workingRoot.path, 'nested', '${extractIndex++}');
        await extractComicArchive(
          archivePath: archive.path,
          extractDir: target,
        );
        return target;
      },
    );

    // 选中的是单个压缩包时，压缩包本身就是一章；即使内部只有一个子目录，
    // 章节名也统一使用压缩包名，避免出现 `Chapter 01` 之类的内部目录名。
    if (!isDirectory && scan.chapters.length == 1) {
      final only = scan.chapters.single;
      scan = LocalComicScanResult(
        title: displayTitle,
        cover: scan.cover,
        coverIsNamed: scan.coverIsNamed,
        chapters: <LocalComicScanChapter>[
          LocalComicScanChapter(
            name: displayTitle,
            groupTitle: '',
            images: only.images,
          ),
        ],
      );
    }

    return LocalComicScanSession(scan: scan, workingRoot: workingRoot);
  } catch (_) {
    try {
      if (await workingRoot.exists()) {
        await workingRoot.delete(recursive: true);
      }
    } catch (_) {}
    rethrow;
  }
}

/// 从文件夹或压缩包导入外部漫画。
///
/// [sourcePath] 可以是文件夹，也可以是 CBZ/CBR/CB7/CBT（或 zip/rar/7z/tar）。
/// 导入前会先把源复制到应用缓存目录，避免选择器权限在导入中途失效。
/// [cleanupRoot] 用于 Android 原生选择器已经复制到缓存的场景：此时直接使用
/// [sourcePath]，导入结束后删除 [cleanupRoot]。
Future<LocalComicImportResult> importLocalComic({
  required String sourcePath,
  required bool isDirectory,
  String? title,
  String? cleanupRoot,
  String uncategorizedName = '未分类',
}) async {
  final session = await prepareLocalComicScan(
    sourcePath: sourcePath,
    isDirectory: isDirectory,
    title: title,
    cleanupRoot: cleanupRoot,
    uncategorizedName: uncategorizedName,
  );
  final createdFiles = <String>[];
  try {
    return await _persistImportedComic(
      scan: session.scan,
      createdFiles: createdFiles,
    );
  } catch (_) {
    for (final path in createdFiles) {
      await _deleteIfExists(File(path));
    }
    rethrow;
  } finally {
    await session.dispose();
  }
}

Future<Directory> _createWorkingRoot() async {
  final cachePath = await getCachePath();
  final root = Directory(
    p.join(
      cachePath,
      'local_comic_import',
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );
  await root.create(recursive: true);
  return root;
}

Future<String> _copySourceToCache({
  required String sourcePath,
  required bool isDirectory,
  required Directory workingRoot,
}) async {
  if (isDirectory) {
    final target = Directory(p.join(workingRoot.path, 'source'));
    await _copyDirectory(Directory(sourcePath), target);
    return target.path;
  }
  final target = File(
    p.join(workingRoot.path, 'source', p.basename(sourcePath)),
  );
  await target.parent.create(recursive: true);
  await File(sourcePath).copy(target.path);
  return target.path;
}

Future<String> _extractRootArchive({
  required String archivePath,
  required Directory workingRoot,
}) async {
  final target = p.join(workingRoot.path, 'extracted');
  await extractComicArchive(archivePath: archivePath, extractDir: target);
  return target;
}

Future<void> _copyDirectory(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    final targetPath = p.join(target.path, name);
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      await File(entity.path).copy(targetPath);
    }
  }
}

Future<LocalComicImportResult> _persistImportedComic({
  required LocalComicScanResult scan,
  required List<String> createdFiles,
}) async {
  final comicId = 'local_${const Uuid().v4()}';
  final now = DateTime.now().toUtc();
  final from = kLocalComicPluginId;

  final chapters = <Map<String, dynamic>>[];
  final eps = <Map<String, dynamic>>[];
  var order = 1;

  for (final chapter in scan.chapters) {
    final chapterId = 'local:${const Uuid().v4()}';
    final storageId = chapterId;
    final usedNames = <String>{};
    final images = <Map<String, dynamic>>[];

    for (final image in chapter.images) {
      final originalName = p.basename(image.path);
      final storedName = uniqueLocalImageName(originalName, usedNames);
      final store = DownloadAssetStore(
        from: from,
        path: storedName,
        cartoonId: comicId,
        chapterId: '',
        storageChapterId: storageId,
        pictureType: PictureType.page,
      );
      final target = await store.canonicalDownloadPath();
      await store.copyFileAtomically(sourcePath: image.path, finalPath: target);
      createdFiles.add(target);
      images.add(<String, dynamic>{
        'id': 'local:${const Uuid().v4()}',
        'name': originalName,
        'path': storedName,
        'url': '',
        'extern': <String, dynamic>{'local': true},
      });
    }

    final chapterMap = <String, dynamic>{
      'id': chapterId,
      'name': chapter.name,
      'order': order,
      'logicalKey': chapterId,
      'taskChapterId': '',
      'storageChapterId': storageId,
      'groupTitle': chapter.groupTitle,
      'images': images,
    };
    chapters.add(chapterMap);
    eps.add(<String, dynamic>{
      'id': chapterId,
      'name': chapter.name,
      'order': order,
      'requestId': '',
      'storageChapterId': storageId,
      'logicalKey': chapterId,
      'groupTitle': chapter.groupTitle,
      'extern': <String, dynamic>{'local': true},
    });
    order++;
  }

  final cover = scan.cover;
  if (cover == null) {
    throw StateError('comic cover not found');
  }
  final coverExtension = p.extension(cover.path);
  final coverName =
      'cover_${DateTime.now().microsecondsSinceEpoch}$coverExtension';
  final coverStore = DownloadAssetStore(
    from: from,
    path: coverName,
    cartoonId: comicId,
    chapterId: '',
    storageChapterId: '',
    pictureType: PictureType.cover,
  );
  final coverTarget = await coverStore.canonicalDownloadPath();
  await coverStore.copyFileAtomically(
    sourcePath: cover.path,
    finalPath: coverTarget,
  );
  createdFiles.add(coverTarget);

  final coverJson = <String, dynamic>{
    'id': 'local_cover_${DateTime.now().microsecondsSinceEpoch}',
    'url': '',
    'name': coverName,
    'path': coverName,
    'extern': <String, dynamic>{'path': coverName, 'local': true},
  };
  final creatorJson = <String, dynamic>{
    'id': '',
    'name': '',
    'avatar': <String, dynamic>{'id': '', 'url': '', 'name': ''},
  };

  final detail = <String, dynamic>{
    'comicInfo': <String, dynamic>{
      'id': comicId,
      'title': scan.title,
      'titleMeta': <dynamic>[],
      'creator': creatorJson,
      'description': '',
      'cover': coverJson,
      'metadata': <dynamic>[],
      'extern': <String, dynamic>{'local': true},
    },
    'preview': <String, dynamic>{},
    'eps': eps,
    'recommend': <dynamic>[],
    'totalViews': 0,
    'totalLikes': 0,
    'totalComments': 0,
    'isFavourite': false,
    'isLiked': false,
    'allowComments': false,
    'allowLike': false,
    'allowCollected': false,
    'allowDownload': true,
    'extern': <String, dynamic>{
      'version': 'v2',
      'source': from,
      'downloadChapters': chapters,
    },
  };

  final uniqueKey = '$from:$comicId';
  final entity = UnifiedComicDownload(
    uniqueKey: uniqueKey,
    source: from,
    comicId: comicId,
    title: scan.title,
    description: '',
    cover: jsonEncode(coverJson),
    creator: jsonEncode(creatorJson),
    titleMeta: '[]',
    metadata: '[]',
    totalViews: 0,
    totalLikes: 0,
    totalComments: 0,
    isFavourite: false,
    isLiked: false,
    allowComment: false,
    allowLike: false,
    allowFavorite: false,
    allowDownload: true,
    chapters: jsonEncode(chapters),
    detailJson: jsonEncode(detail),
    storageRoot: p.join(
      await getDownloadPath(),
      encodePath(path: from),
      encodePath(path: comicId),
    ),
    createdAt: now,
    updatedAt: now,
    downloadedAt: now,
    deleted: false,
    schemaVersion: 2,
  );

  try {
    objectbox.unifiedDownloadBox.put(entity);
    ComicLinkService.addComic(uniqueKey, null, ComicFolderType.download);

    final nowMillis = DateTime.now().toUtc().millisecondsSinceEpoch;
    final links = ComicLinkService.linksOfComic(
      uniqueKey,
      ComicFolderType.download,
    );
    for (final link in links) {
      link
        ..createdAt = nowMillis
        ..updatedAt = nowMillis;
      objectbox.comicLinkBox.put(link);
    }
  } catch (_) {
    objectbox.unifiedDownloadBox.remove(entity.id);
    rethrow;
  }

  return LocalComicImportResult(
    comicId: comicId,
    title: scan.title,
    chapterCount: chapters.length,
    imageCount: scan.imageCount,
  );
}

String uniqueLocalImageName(String name, Set<String> used) {
  if (used.add(name)) return name;
  final extension = p.extension(name);
  final base = p.basenameWithoutExtension(name);
  var index = 2;
  var candidate = '${base}_$index$extension';
  while (!used.add(candidate)) {
    index++;
    candidate = '${base}_$index$extension';
  }
  return candidate;
}

Future<void> _deleteIfExists(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } catch (e) {
    logger.w('删除导入文件失败: ${file.path}', error: e);
  }
}
