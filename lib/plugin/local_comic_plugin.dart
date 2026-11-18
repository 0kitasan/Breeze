import 'dart:convert';

import 'package:zephyr/main.dart';
import 'package:zephyr/object_box/model.dart';
import 'package:zephyr/object_box/objectbox.g.dart';

/// 本地导入漫画使用的“幽灵插件” UUID。
///
/// 它只作为漫画来源标识与书架来源筛选项存在：不出现在插件管理、搜索、
/// 聚合搜索里，也不会参与插件更新检查。UUID 带 `zephyr_` 前缀避免与真实
/// 插件冲突。
const String kLocalComicPluginId = 'zephyr_local_comic';

const String kLocalComicPluginVersion = '1.0.0';

const String kLocalComicPluginName = '本地漫画';

/// 最小 getInfo bundle。`init` 故意不实现，宿主会按“未实现 init”跳过。
const String _kLocalComicBundle =
    '''
module.exports = {
  getInfo: function () {
    return {
      uuid: '$kLocalComicPluginId',
      name: '$kLocalComicPluginName',
      version: '$kLocalComicPluginVersion',
      iconUrl: '',
      haveHome: false,
      haveCloudFavorite: false,
      functions: []
    };
  }
};
''';

bool isLocalComicPluginId(String uuid) => uuid.trim() == kLocalComicPluginId;

Map<String, dynamic> localComicPluginInfo() => <String, dynamic>{
  'uuid': kLocalComicPluginId,
  'name': kLocalComicPluginName,
  'version': kLocalComicPluginVersion,
  'iconUrl': '',
  'haveHome': false,
  'haveCloudFavorite': false,
  'functions': const <dynamic>[],
};

/// 确保幽灵插件存在于插件注册表。
///
/// 必须在 [PluginRegistryService.init] 之前调用；已存在时只修复被误删/禁用
/// 或缺失 getInfo 缓存的记录，不覆盖用户数据。
Future<void> ensureLocalComicPluginInstalled() async {
  final query = objectbox.pluginInfoBox
      .query(PluginInfo_.uuid.equals(kLocalComicPluginId))
      .build();
  try {
    final existing = query.findFirst();
    final now = DateTime.now().toUtc();
    if (existing == null) {
      objectbox.pluginInfoBox.put(
        PluginInfo(
          uuid: kLocalComicPluginId,
          version: kLocalComicPluginVersion,
          originScript: _kLocalComicBundle,
          lastLoadSuccess: true,
          insertedAt: now,
          updatedAt: now,
          isEnabled: true,
          isDeleted: false,
          debug: false,
          getInfoJson: jsonEncode(localComicPluginInfo()),
        ),
      );
      return;
    }

    var changed = false;
    if (existing.isDeleted) {
      existing
        ..isDeleted = false
        ..deletedAt = null
        ..isEnabled = true;
      changed = true;
    }
    if (!existing.isEnabled) {
      existing.isEnabled = true;
      changed = true;
    }
    if (existing.originScript.trim().isEmpty) {
      existing.originScript = _kLocalComicBundle;
      changed = true;
    }
    if (existing.getInfoJson.trim().isEmpty) {
      existing.getInfoJson = jsonEncode(localComicPluginInfo());
      changed = true;
    }
    if (existing.version != kLocalComicPluginVersion) {
      existing
        ..version = kLocalComicPluginVersion
        ..originScript = _kLocalComicBundle
        ..getInfoJson = jsonEncode(localComicPluginInfo());
      changed = true;
    }
    if (changed) {
      existing.updatedAt = now;
      objectbox.pluginInfoBox.put(existing);
    }
  } finally {
    query.close();
  }
}
