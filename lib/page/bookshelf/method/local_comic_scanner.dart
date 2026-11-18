import 'dart:io';

import 'package:path/path.dart' as p;

/// 外部漫画扫描出的章节。
class LocalComicScanChapter {
  const LocalComicScanChapter({
    required this.name,
    required this.groupTitle,
    required this.images,
  });

  final String name;
  final String groupTitle;
  final List<File> images;
}

/// 外部漫画扫描结果。
class LocalComicScanResult {
  const LocalComicScanResult({
    required this.title,
    required this.cover,
    required this.coverIsNamed,
    required this.chapters,
  });

  final String title;
  final File? cover;

  /// 封面文件本身名为 `cover.*` 时为 true，此时它不会进入章节图片。
  final bool coverIsNamed;
  final List<LocalComicScanChapter> chapters;

  int get imageCount =>
      chapters.fold(0, (total, chapter) => total + chapter.images.length);
}

/// 递归扫描外部漫画目录。
///
/// 规则：
/// - 没有子目录/压缩包的目录视为一个章节；根目录单章使用漫画标题命名。
/// - 含子目录/压缩包的目录是容器，容器里直接散落的图片进入“未分类”章节。
/// - 压缩包由 [extractArchive] 解压后再按同样规则扫描；嵌套压缩包也支持。
/// - `cover.*` 优先作为封面并从章节中排除；否则取第一章第一张图作为封面，
///   但仍保留在章节里。
class LocalComicScanner {
  const LocalComicScanner({this.uncategorizedName = '未分类'});

  static const Set<String> imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  static const Set<String> archiveExtensions = <String>{
    'cbz',
    'cbr',
    'cb7',
    'cbt',
    'zip',
    'rar',
    '7z',
    'tar',
  };

  final String uncategorizedName;

  static bool isImageFile(String path) => imageExtensions.contains(
    p.extension(path).toLowerCase().replaceFirst('.', ''),
  );

  static bool isArchiveFile(String path) => archiveExtensions.contains(
    p.extension(path).toLowerCase().replaceFirst('.', ''),
  );

  Future<LocalComicScanResult> scanDirectory(
    String rootPath, {
    required String title,
    String rootGroupTitle = '',
    Future<String?> Function(File archive)? extractArchive,
  }) async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      throw StateError('comic directory not found: $rootPath');
    }

    final namedCover = await _findNamedCover(root);
    final walker = _LocalComicScanWalker(
      root: root,
      title: title,
      rootGroupTitle: rootGroupTitle,
      coverPath: namedCover?.path ?? '',
      uncategorizedName: uncategorizedName,
      extractArchive: extractArchive,
    );
    final chapters = await walker.run();

    if (chapters.isEmpty) {
      throw StateError('no comic images found in $rootPath');
    }

    final cover = namedCover ?? chapters.first.images.first;
    return LocalComicScanResult(
      title: title,
      cover: cover,
      coverIsNamed: namedCover != null,
      chapters: chapters,
    );
  }

  Future<File?> _findNamedCover(Directory root) async {
    final candidates = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (!isImageFile(name)) continue;
      if (p.basenameWithoutExtension(name).toLowerCase() != 'cover') continue;
      candidates.add(entity);
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final depth = _depthOf(root.path, a.path) - _depthOf(root.path, b.path);
      if (depth != 0) return depth;
      return naturalCompare(a.path, b.path);
    });
    return candidates.first;
  }

  int _depthOf(String root, String path) {
    final relative = p.relative(path, from: root);
    return p.split(relative).where((part) => part.isNotEmpty).length;
  }
}

class _LocalComicScanWalker {
  _LocalComicScanWalker({
    required this.root,
    required this.title,
    required this.rootGroupTitle,
    required this.coverPath,
    required this.uncategorizedName,
    required this.extractArchive,
  });

  final Directory root;
  final String title;
  final String rootGroupTitle;
  final String coverPath;
  final String uncategorizedName;
  final Future<String?> Function(File archive)? extractArchive;

  final List<LocalComicScanChapter> chapters = <LocalComicScanChapter>[];
  final List<File> uncategorized = <File>[];

  Future<List<LocalComicScanChapter>> run() async {
    await walk(root, groupTitle: '', isRoot: true);

    if (uncategorized.isNotEmpty) {
      uncategorized.sort(
        (a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)),
      );
      chapters.add(
        LocalComicScanChapter(
          name: uncategorizedName,
          groupTitle: '',
          images: List<File>.unmodifiable(uncategorized),
        ),
      );
    }

    chapters.removeWhere((chapter) => chapter.images.isEmpty);
    return chapters;
  }

  Future<void> walk(
    Directory dir, {
    required String groupTitle,
    required bool isRoot,
  }) async {
    final entries = await _sortedEntries(dir);
    final images = <File>[];
    final subdirs = <Directory>[];
    final archives = <File>[];

    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || name == '__MACOSX') continue;
      if (entry is File) {
        if (LocalComicScanner.isImageFile(entry.path)) {
          if (entry.path != coverPath) images.add(entry);
        } else if (LocalComicScanner.isArchiveFile(entry.path)) {
          archives.add(entry);
        }
      } else if (entry is Directory) {
        subdirs.add(entry);
      }
    }

    final hasNesting = subdirs.isNotEmpty || archives.isNotEmpty;
    if (!hasNesting) {
      if (images.isNotEmpty) {
        chapters.add(
          LocalComicScanChapter(
            name: isRoot ? title : p.basename(dir.path),
            groupTitle: groupTitle,
            images: images,
          ),
        );
      }
      return;
    }

    // 容器目录里直接散落的图片不符合“一章一目录/压缩包”的标准结构。
    uncategorized.addAll(images);

    // 根目录的直接章节使用 rootGroupTitle（章节导入时可能是卷名）；
    // 更深层才把当前目录名拼进分组。
    final childGroup = isRoot
        ? rootGroupTitle
        : _joinGroup(groupTitle, p.basename(dir.path));

    for (final archive in archives) {
      final extracted = await extractArchive?.call(archive);
      if (extracted == null) continue;
      await walkArchiveRoot(
        Directory(extracted),
        archiveName: p.basenameWithoutExtension(archive.path),
        parentGroup: childGroup,
        rootArchive: false,
      );
    }

    for (final subdir in subdirs) {
      await walk(subdir, groupTitle: childGroup, isRoot: false);
    }
  }

  Future<void> walkArchiveRoot(
    Directory dir, {
    required String archiveName,
    required String parentGroup,
    required bool rootArchive,
  }) async {
    if (!await dir.exists()) return;
    final entries = await _sortedEntries(dir);
    final images = <File>[];
    final subdirs = <Directory>[];
    final archives = <File>[];

    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') || name == '__MACOSX') continue;
      if (entry is File) {
        if (LocalComicScanner.isImageFile(entry.path)) {
          if (entry.path != coverPath) images.add(entry);
        } else if (LocalComicScanner.isArchiveFile(entry.path)) {
          archives.add(entry);
        }
      } else if (entry is Directory) {
        subdirs.add(entry);
      }
    }

    // 压缩包根目录直接就是图片：整个压缩包算一章。
    if (subdirs.isEmpty && archives.isEmpty) {
      if (images.isNotEmpty) {
        chapters.add(
          LocalComicScanChapter(
            name: archiveName,
            groupTitle: parentGroup,
            images: images,
          ),
        );
      }
      return;
    }

    // 常见 CBZ：压缩包里只有一个章节目录，仍按“压缩包名 = 章节名”处理。
    if (images.isEmpty && archives.isEmpty && subdirs.length == 1) {
      final only = subdirs.single;
      final onlyEntries = await _sortedEntries(only);
      final onlyImages = <File>[];
      var onlyHasNesting = false;
      for (final entry in onlyEntries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.') || name == '__MACOSX') continue;
        if (entry is File) {
          if (LocalComicScanner.isImageFile(entry.path)) {
            if (entry.path != coverPath) onlyImages.add(entry);
          } else if (LocalComicScanner.isArchiveFile(entry.path)) {
            onlyHasNesting = true;
          }
        } else if (entry is Directory) {
          onlyHasNesting = true;
        }
      }
      if (!onlyHasNesting && onlyImages.isNotEmpty) {
        onlyImages.sort(
          (a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)),
        );
        chapters.add(
          LocalComicScanChapter(
            name: archiveName,
            groupTitle: parentGroup,
            images: onlyImages,
          ),
        );
        return;
      }
    }

    uncategorized.addAll(images);
    final archiveGroup = rootArchive
        ? ''
        : _joinGroup(parentGroup, archiveName);

    for (final nested in archives) {
      final extracted = await extractArchive?.call(nested);
      if (extracted == null) continue;
      await walkArchiveRoot(
        Directory(extracted),
        archiveName: p.basenameWithoutExtension(nested.path),
        parentGroup: archiveGroup,
        rootArchive: false,
      );
    }
    for (final subdir in subdirs) {
      await walk(subdir, groupTitle: parentGroup, isRoot: false);
    }
  }

  Future<List<FileSystemEntity>> _sortedEntries(Directory dir) async {
    final entries = await dir.list(followLinks: false).toList();
    entries.sort(
      (a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)),
    );
    return entries;
  }

  String _joinGroup(String parent, String child) {
    if (parent.isEmpty) return child;
    return '$parent/$child';
  }
}

/// 自然排序：让 `2.jpg` 排在 `10.jpg` 前面。
int naturalCompare(String a, String b) {
  final left = _naturalChunks(a);
  final right = _naturalChunks(b);
  final length = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = left[i];
    final r = right[i];
    if (l is int && r is int) {
      final result = l.compareTo(r);
      if (result != 0) return result;
    } else {
      final result = l.toString().compareTo(r.toString());
      if (result != 0) return result;
    }
  }
  return left.length.compareTo(right.length);
}

List<Object> _naturalChunks(String value) {
  final chunks = <Object>[];
  for (final match in RegExp(r'\d+|\D+').allMatches(value.toLowerCase())) {
    final text = match.group(0)!;
    chunks.add(int.tryParse(text) ?? text);
  }
  return chunks;
}
