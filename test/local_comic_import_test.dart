import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/page/bookshelf/method/local_comic_import.dart';
import 'package:zephyr/page/bookshelf/service/comic_link_service.dart';
import 'package:zephyr/page/comic_info/json/normal/normal_comic_all_info.dart';
import 'package:zephyr/page/comic_read/method/get_local_info.dart';
import 'package:zephyr/plugin/local_comic_plugin.dart';
import 'package:zephyr/service/download/download_asset_store.dart';
import 'package:zephyr/type/enum.dart';
import 'package:zephyr/util/get_path.dart';
import 'package:zephyr/util/rust_loader.dart';

import 'test_helper.dart';

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
  late Directory downloadRoot;
  late Directory tempRoot;

  setUpAll(() async {
    await initRustLib(silent: true);
    await TestObjectBoxHelper.setUpTestObjectBox();
    downloadRoot = await Directory.systemTemp.createTemp(
      'breeze_local_import_downloads_',
    );
    debugDownloadRootPath = downloadRoot.path;
  });

  tearDownAll(() async {
    debugDownloadRootPath = null;
    if (await downloadRoot.exists()) {
      await downloadRoot.delete(recursive: true);
    }
    await TestObjectBoxHelper.tearDownTestObjectBox();
  });

  setUp(() async {
    objectbox.unifiedDownloadBox.removeAll();
    objectbox.comicLinkBox.removeAll();
    objectbox.comicFolderBox.removeAll();
    tempRoot = await Directory.systemTemp.createTemp('breeze_local_import_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('文件夹导入：封面、单章节、图片与 ComicLink', () async {
    final source = Directory(p.join(tempRoot.path, 'My Comic'));
    await _image(p.join(source.path, 'cover.png'));
    await _image(p.join(source.path, '01.png'));
    await _image(p.join(source.path, '02.png'));

    final result = await importLocalComic(
      sourcePath: source.path,
      isDirectory: true,
    );

    expect(result.title, 'My Comic');
    expect(result.chapterCount, 1);
    expect(result.imageCount, 2);

    final record = objectbox.unifiedDownloadBox.getAll().single;
    expect(record.source, kLocalComicPluginId);
    expect(record.uniqueKey, '$kLocalComicPluginId:${result.comicId}');
    expect(record.allowLike, isFalse);
    expect(record.allowComment, isFalse);
    expect(record.allowFavorite, isFalse);
    expect(record.allowDownload, isTrue);

    final chapters = jsonDecode(record.chapters) as List;
    expect(chapters, hasLength(1));
    final chapter = chapters.single as Map;
    expect(chapter['name'], 'My Comic');
    final chapterImages = (chapter['images'] as List).cast<Map>();
    expect(chapterImages, hasLength(2));
    expect(
      chapterImages.every((image) => (image['id'] as String).isNotEmpty),
      isTrue,
    );
    expect(chapterImages.map((image) => image['id']).toSet(), hasLength(2));

    final cover = jsonDecode(record.cover) as Map;
    final coverStore = DownloadAssetStore(
      from: kLocalComicPluginId,
      path: cover['path'] as String,
      cartoonId: result.comicId,
      chapterId: '',
      storageChapterId: '',
      pictureType: PictureType.cover,
    );
    expect(await coverStore.findCanonicalDownload(), isNotNull);

    final links = ComicLinkService.listAllLinks(ComicFolderType.download);
    expect(links, hasLength(1));
    expect(links.single.comicUniqueKey, record.uniqueKey);

    final detail = NormalComicAllInfo.fromJson(
      jsonDecode(record.detailJson) as Map<String, dynamic>,
    );
    expect(detail.comicInfo.title, 'My Comic');
    expect(detail.eps, hasLength(1));
    expect(detail.eps.single.name, 'My Comic');

    final localInfo = await getPluginInfoFromLocal(
      kLocalComicPluginId,
      result.comicId,
      1,
    );
    expect(localInfo.docs, hasLength(2));
  });

  test('旧记录图片 id 为空时用 path 兜底生成阅读页 key', () async {
    final source = Directory(p.join(tempRoot.path, 'Legacy'));
    await _image(p.join(source.path, '01.png'));
    await _image(p.join(source.path, '02.png'));
    final result = await importLocalComic(
      sourcePath: source.path,
      isDirectory: true,
    );

    final record = objectbox.unifiedDownloadBox.getAll().single;
    final chapters = jsonDecode(record.chapters) as List;
    for (final chapter in chapters.cast<Map>()) {
      for (final image in (chapter['images'] as List).cast<Map>()) {
        image['id'] = '';
      }
    }
    record.chapters = jsonEncode(chapters);
    objectbox.unifiedDownloadBox.put(record);

    final info = await getPluginInfoFromLocal(
      kLocalComicPluginId,
      result.comicId,
      1,
    );
    expect(info.docs.map((doc) => doc.id).toList(), <String>[
      '01.png',
      '02.png',
    ]);
    expect(info.docs.map((doc) => doc.id).toSet(), hasLength(2));
  });

  test('CBZ 导入：压缩包名作为标题与章节名', () async {
    final archive = Archive();
    archive.addFile(ArchiveFile.bytes('cover.png', base64Decode(_pngBase64)));
    archive.addFile(ArchiveFile.bytes('01.png', base64Decode(_pngBase64)));
    archive.addFile(ArchiveFile.bytes('02.png', base64Decode(_pngBase64)));
    final zipBytes = ZipEncoder().encodeBytes(archive);
    final zipFile = File(p.join(tempRoot.path, 'Book.cbz'));
    await zipFile.writeAsBytes(zipBytes);

    final result = await importLocalComic(
      sourcePath: zipFile.path,
      isDirectory: false,
    );

    expect(result.title, 'Book');
    expect(result.chapterCount, 1);
    expect(result.imageCount, 2);

    final record = objectbox.unifiedDownloadBox.getAll().single;
    final chapters = jsonDecode(record.chapters) as List;
    expect((chapters.single as Map)['name'], 'Book');
    expect(((chapters.single as Map)['images'] as List), hasLength(2));
  });

  test('CBR 导入：RAR 解压后封面与图片正确', () async {
    final fixture = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'comic.rar',
    );
    final result = await importLocalComic(
      sourcePath: fixture,
      isDirectory: false,
    );

    expect(result.title, 'comic');
    expect(result.chapterCount, 1);
    expect(result.imageCount, 2);

    final record = objectbox.unifiedDownloadBox.getAll().single;
    final chapters = jsonDecode(record.chapters) as List;
    expect((chapters.single as Map)['name'], 'comic');
    expect(((chapters.single as Map)['images'] as List), hasLength(2));
    final cover = jsonDecode(record.cover) as Map;
    expect(cover['path'], startsWith('cover_'));
  });

  test('cleanupRoot 在导入结束后删除', () async {
    final cacheRoot = Directory(p.join(tempRoot.path, 'cache'));
    final source = Directory(p.join(cacheRoot.path, 'source'));
    await _image(p.join(source.path, '01.png'));

    await importLocalComic(
      sourcePath: source.path,
      isDirectory: true,
      cleanupRoot: cacheRoot.path,
    );

    expect(await cacheRoot.exists(), isFalse);
  });

  test('多章节 + 未分类导入', () async {
    final source = Directory(p.join(tempRoot.path, 'Multi'));
    await _image(p.join(source.path, 'loose.png'));
    await _image(p.join(source.path, 'ch1', '01.png'));
    await _image(p.join(source.path, 'ch2', '01.png'));

    final result = await importLocalComic(
      sourcePath: source.path,
      isDirectory: true,
      uncategorizedName: '未分类',
    );

    expect(result.chapterCount, 3);
    final record = objectbox.unifiedDownloadBox.getAll().single;
    final chapters = (jsonDecode(record.chapters) as List)
        .cast<Map<String, dynamic>>();
    expect(chapters.map((chapter) => chapter['name']), <String>[
      'ch1',
      'ch2',
      '未分类',
    ]);
  });
}
