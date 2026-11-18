import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/page/bookshelf/method/local_comic_scanner.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
    '/x8AAusB9Wl2nXQAAAAASUVORK5CYII=';

Future<File> _image(String path) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(base64Decode(_pngBase64));
  return file;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('breeze_local_scan_');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('单章节：cover.* 作为封面并从章节排除', () async {
    await _image(p.join(root.path, 'cover.png'));
    await _image(p.join(root.path, '01.png'));
    await _image(p.join(root.path, '02.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '我的漫画',
    );

    expect(result.coverIsNamed, isTrue);
    expect(p.basename(result.cover!.path), 'cover.png');
    expect(result.chapters, hasLength(1));
    expect(result.chapters.single.name, '我的漫画');
    expect(result.chapters.single.groupTitle, isEmpty);
    expect(
      result.chapters.single.images.map((file) => p.basename(file.path)),
      <String>['01.png', '02.png'],
    );
  });

  test('单章节：没有 cover.* 时第一张图作封面但仍保留在章节', () async {
    await _image(p.join(root.path, '01.png'));
    await _image(p.join(root.path, '02.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '单章',
    );

    expect(result.coverIsNamed, isFalse);
    expect(p.basename(result.cover!.path), '01.png');
    expect(result.chapters.single.images, hasLength(2));
  });

  test('多章节：子目录成章，根目录散图进入未分类', () async {
    await _image(p.join(root.path, 'loose.png'));
    await _image(p.join(root.path, 'ch1', '01.png'));
    await _image(p.join(root.path, 'ch2', '01.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '多章',
    );

    expect(result.chapters.map((chapter) => chapter.name), <String>[
      'ch1',
      'ch2',
      '未分类',
    ]);
    expect(result.chapters.last.images.single.path, endsWith('loose.png'));
    expect(result.coverIsNamed, isFalse);
    expect(p.basename(result.cover!.path), '01.png');
  });

  test('分卷：v01/c001.cbz 递归解压后按卷分组', () async {
    final extracted = await Directory.systemTemp.createTemp(
      'breeze_local_scan_archives_',
    );
    addTearDown(() async {
      if (await extracted.exists()) {
        await extracted.delete(recursive: true);
      }
    });

    final archives = <String, String>{};
    for (final entry in <String, String>{
      'v01/c001.cbz': '001.png',
      'v01/c002.cbz': '002.png',
      'v02/c003.cbz': '003.png',
    }.entries) {
      final archive = File(
        p.joinAll(<String>[root.path, ...entry.key.split('/')]),
      );
      await archive.parent.create(recursive: true);
      await archive.writeAsBytes(const <int>[1, 2, 3]);
      final target = Directory(p.join(extracted.path, entry.key));
      await _image(p.join(target.path, entry.value));
      archives[archive.path] = target.path;
    }

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '分卷漫画',
      extractArchive: (archive) async => archives[archive.path],
    );

    expect(result.chapters.map((chapter) => chapter.name), <String>[
      'c001',
      'c002',
      'c003',
    ]);
    expect(result.chapters.map((chapter) => chapter.groupTitle), <String>[
      'v01',
      'v01',
      'v02',
    ]);
    expect(result.imageCount, 3);
  });

  test('递归扫描：多级目录按相对路径分组', () async {
    await _image(p.join(root.path, 'vol1', 'ch1', '01.png'));
    await _image(p.join(root.path, 'vol1', 'ch2', '01.png'));
    await _image(p.join(root.path, 'vol2', 'ch1', '01.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '递归',
    );

    expect(
      result.chapters.map((chapter) => '${chapter.groupTitle}/${chapter.name}'),
      <String>['vol1/ch1', 'vol1/ch2', 'vol2/ch1'],
    );
  });

  test('子目录里的 cover.* 也作为封面并从该章排除', () async {
    await _image(p.join(root.path, 'ch1', 'cover.png'));
    await _image(p.join(root.path, 'ch1', '01.png'));
    await _image(p.join(root.path, 'ch2', '01.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '嵌套封面',
    );

    expect(result.coverIsNamed, isTrue);
    expect(p.basename(result.cover!.path), 'cover.png');
    expect(result.chapters.first.name, 'ch1');
    expect(result.chapters.first.images, hasLength(1));
  });

  test('自然排序：2 排在 10 前面', () async {
    await _image(p.join(root.path, '1.png'));
    await _image(p.join(root.path, '2.png'));
    await _image(p.join(root.path, '10.png'));

    final result = await const LocalComicScanner().scanDirectory(
      root.path,
      title: '排序',
    );

    expect(
      result.chapters.single.images.map((file) => p.basename(file.path)),
      <String>['1.png', '2.png', '10.png'],
    );
  });

  test('没有图片时抛错', () async {
    await Directory(p.join(root.path, 'empty')).create(recursive: true);
    expect(
      () => const LocalComicScanner().scanDirectory(root.path, title: '空'),
      throwsStateError,
    );
  });
}
