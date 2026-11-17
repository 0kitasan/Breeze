import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zephyr/widgets/fluent_dropdown.dart';

void main() {
  testWidgets(
    'scrolls to selected item, blocks outside scroll, closes on back',
    (tester) async {
      final items = <String, String>{
        for (var i = 1; i <= 30; i++)
          'v$i': i.isEven ? '2026第$i期02.06 - 01.30' : '第$i期',
      };
      items['v11'] = '2026第225期02.06 - 01.30 很长很长的标题';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FluentDropdown<String>(
                value: 'v11',
                displayValue: '第11期',
                items: items,
                onChanged: (_) {},
                panelColor: const Color(0xFFF3F3F3),
                selectedColor: const Color(0xFFE5E5E5),
                hoverColor: const Color(0xFFEDEDED),
                panelBorderRadius: 12,
                itemBorderRadius: 8,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('第11期'));
      await tester.pumpAndSettle();

      // 选中项只用左侧主色竖条标记，不再出现 Material 对勾。
      expect(find.byIcon(Icons.check), findsNothing);

      // 多行标签也能准确滚到选中项：选中项顶部落在菜单可视区域内。
      final selectedFinder = find.text(items['v11']!);
      expect(selectedFinder, findsOneWidget);
      final selectedBox = tester.renderObject<RenderBox>(selectedFinder);
      final menuBox = tester.renderObject<RenderBox>(find.byType(ListView));
      final selectedTop = selectedBox.localToGlobal(Offset.zero).dy;
      expect(menuBox.size.height, lessThanOrEqualTo(320));
      final menuTop = menuBox.localToGlobal(Offset.zero).dy;
      final menuBottom = menuTop + menuBox.size.height;
      expect(selectedTop, greaterThanOrEqualTo(menuTop - 1));
      expect(selectedTop, lessThan(menuBottom));

      final itemBox = tester.renderObject<RenderBox>(
        find
            .ancestor(of: selectedFinder, matching: find.byType(Container))
            .first,
      );
      expect(
        selectedBox.size.height,
        lessThanOrEqualTo(itemBox.size.height - 20),
      );

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(scrollable.position.pixels, greaterThan(0));

      // 菜单内部仍然可以滚动，后面的选项不会被“删掉”。
      final beforeDrag = scrollable.position.pixels;
      await tester.dragFrom(
        tester.getCenter(find.byType(ListView)),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(beforeDrag));

      // 滚到末尾能完整看到最后一项，说明总高度没有被截断。
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text(items['v30']!), findsOneWidget);

      // 菜单打开时外部拖动被拦截，菜单不关闭。
      await tester.dragFrom(const Offset(10, 10), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.text('第11期'), findsOneWidget);

      // 返回键只关闭下拉框，不退出页面。
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('第11期'), findsOneWidget);
      expect(find.byType(FluentDropdown<String>), findsOneWidget);

      // 点击外部关闭。
      await tester.tap(find.text('第11期'));
      await tester.pumpAndSettle();
      expect(selectedFinder, findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(selectedFinder, findsNothing);
    },
  );

  testWidgets('menu stays attached when the navigator is offset', (
    tester,
  ) async {
    // 桌面端 MaterialApp.builder 在 Navigator 上方插了 40px 的自定义标题栏，
    // 浮层坐标系因此整体下移；菜单必须按浮层坐标定位，不能直接用全局坐标。
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Column(
          children: [
            const SizedBox(height: 40),
            Expanded(child: child!),
          ],
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: FluentDropdown<String>(
                value: 'a',
                displayValue: 'A',
                items: const {'a': 'A', 'b': 'B'},
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final triggerRect = tester.getRect(find.byType(FluentDropdown<String>));
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    final menuRect = tester.getRect(find.byType(ListView));
    expect(menuRect.top - triggerRect.bottom, closeTo(7, 1));
  });

  testWidgets('FluentPopupMenu.show returns the tapped value', (tester) async {
    late BuildContext anchorContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              anchorContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    final future = FluentPopupMenu.show<String>(
      context: anchorContext,
      anchor: const Rect.fromLTWH(40, 40, 120, 40),
      items: const [
        FluentPopupMenuItem(value: 'a', title: Text('Rename')),
        FluentPopupMenuItem(value: 'b', title: Text('Delete')),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    // 菜单紧贴锚点矩形（anchor.bottom = 80，间距 6，面板边框 1）。
    expect(tester.getRect(find.byType(ListView)).top, closeTo(87, 1));

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await future, 'b');
    expect(find.text('Rename'), findsNothing);
  });

  testWidgets('keyboard navigation moves and selects, escape closes', (
    tester,
  ) async {
    String? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FluentDropdown<String>(
              value: 'a',
              displayValue: 'A',
              items: const {'a': 'A', 'b': 'B', 'c': 'C'},
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(changed, 'b');
    expect(find.byType(ListView), findsNothing);

    // Esc 只关闭菜单，不触发选择。
    changed = null;
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);
    expect(changed, isNull);
  });
}
