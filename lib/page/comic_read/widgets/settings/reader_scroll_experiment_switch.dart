import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// 实验项仅在本次启动内启用，不加入正式阅读偏好和同步数据。
final zoomedContinuousScrollEnabled = ValueNotifier<bool>(false);

class ReaderScrollExperimentSwitch extends StatelessWidget {
  const ReaderScrollExperimentSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return ValueListenableBuilder<bool>(
      valueListenable: zoomedContinuousScrollEnabled,
      builder: (context, enabled, _) => SwitchListTile(
        title: Text(chinese
            ? '条漫放大后连续滚动（实验性）'
            : 'Continuous scrolling while zoomed (experimental)'),
        subtitle: Text(chinese
            ? '仅条漫模式。本次启动内有效，重启后关闭；异常时请关闭。'
            : 'Webtoon mode only. Resets on restart; disable if gestures misbehave.'),
        value: enabled,
        onChanged: (value) => zoomedContinuousScrollEnabled.value = value,
      ),
    );
  }
}
