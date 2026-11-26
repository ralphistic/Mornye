import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/ios_status_bar_scroll_target.dart';

Widget _list(ScrollController controller) => IosStatusBarScrollTarget(
  controller: controller,
  child: ListView.builder(
    controller: controller,
    itemExtent: 60,
    itemCount: 200,
    itemBuilder: (_, index) => Text('Row $index'),
  ),
);

void main() {
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  testWidgets('native status bar event returns an explicit list to the top', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: _list(controller)),
    ));
    controller.jumpTo(5000);
    await tester.pump();
    expect(controller.offset, 5000);
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.minScrollExtent);
    expect(find.text('Row 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: ios);

  testWidgets('only the visible tab moves', (tester) async {
    final first = ScrollController();
    final second = ScrollController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget screen(int selected) => MaterialApp(
      home: Scaffold(
        body: IndexedStack(
          index: selected,
          children: [
            TickerMode(enabled: selected == 0, child: _list(first)),
            TickerMode(enabled: selected == 1, child: _list(second)),
          ],
        ),
      ),
    );
    await tester.pumpWidget(screen(0));
    first.jumpTo(4000);
    second.jumpTo(3000);
    await tester.pump();
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(first.offset, 0);
    expect(second.offset, 3000);
    first.jumpTo(2000);
    await tester.pumpWidget(screen(1));
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(first.offset, 2000);
    expect(second.offset, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: ios);

  testWidgets('a root modal cannot scroll the nested page underneath', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final root = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: root,
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: _list(controller)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    controller.jumpTo(2000);
    await tester.pump();
    showDialog<void>(
      context: root.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Modal')),
    );
    await tester.pumpAndSettle();
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(controller.offset, 2000);
    root.currentState!.pop();
    await tester.pumpAndSettle();
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: ios);

  testWidgets('nested song list and header both return to the top', (
    tester,
  ) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    final key = GlobalKey<NestedScrollViewState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IosStatusBarScrollTarget(
          controller: outer,
          hasMoreScrollOffset: () =>
              key.currentState!.innerController.positions.any(
                (position) => position.pixels > position.minScrollExtent,
              ),
          child: NestedScrollView(
            key: key,
            controller: outer,
            // No collapsible header extent: an inner offset is the only
            // evidence of scrolling. The real header is handled too.
            headerSliverBuilder: (_, _) => [],
            body: ListView.builder(
              primary: true,
              itemExtent: 60,
              itemCount: 200,
              itemBuilder: (_, index) => Text('Song $index'),
            ),
          ),
        ),
      ),
    ));
    final inner = key.currentState!.innerController;
    inner.jumpTo(3000);
    await tester.pump();
    expect(outer.offset, 0);
    expect(inner.position.pixels, greaterThan(0));
    tester.simulateStatusBarTap();
    await tester.pumpAndSettle();
    expect(outer.offset, 0);
    expect(inner.position.pixels, inner.position.minScrollExtent);
    expect(find.text('Song 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: ios);
}
