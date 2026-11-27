import 'dart:async';

import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/gestures.dart' as gestures;
import 'package:flutter/rendering.dart' as rendering;
import 'package:flutter/widgets.dart';

/// Bridges explicit page scroll controllers to the native iOS status-bar tap.
/// Do not intercept touches or install a fake status-bar overlay. A hidden
/// tab, covered route or unrelated scrollable must not move.
class IosStatusBarScrollTarget extends StatefulWidget {
  const IosStatusBarScrollTarget({
    super.key,
    required this.controller,
    required this.child,
    this.hasMoreScrollOffset,
  });

  final ScrollController controller;
  final Widget child;

  /// A nested scroll view can have an inner offset even when its outer
  /// header is already at its minimum extent.
  final bool Function()? hasMoreScrollOffset;

  @override
  State<IosStatusBarScrollTarget> createState() =>
      _IosStatusBarScrollTargetState();
}

class _IosStatusBarScrollTargetState extends State<IosStatusBarScrollTarget>
    with WidgetsBindingObserver {
  bool get _ios => !foundation.kIsWeb &&
      foundation.defaultTargetPlatform == foundation.TargetPlatform.iOS;

  bool _observing = false;
  bool _visible = false;
  int? _viewId;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ios != _observing) {
      _observing = _ios;
      if (_observing) {
        WidgetsBinding.instance.addObserver(this);
      } else {
        WidgetsBinding.instance.removeObserver(this);
      }
    }
    if (!_observing) return;
    _visible = TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    _viewId = View.maybeOf(context)?.viewId;
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void handleStatusBarTap() {
    if (!mounted || !_observing || !_visible || _viewId == null) return;
    final controller = widget.controller;
    if (!controller.hasClients || controller.positions.length != 1) return;
    final position = controller.position;
    if (!position.hasContentDimensions ||
        position.axis != Axis.vertical) {
      return;
    }
    if (position.pixels <= position.minScrollExtent &&
        !(widget.hasMoreScrollOffset?.call() ?? false)) {
      return;
    }

    // Nested tab navigators can have a current route under a root-level
    // player or modal. Confirm that this page is actually hit-testable.
    final render = context.findRenderObject();
    if (render is! rendering.RenderBox || !render.attached || !render.hasSize ||
        render.size.isEmpty) {
      return;
    }
    final result = gestures.HitTestResult();
    final point = render.localToGlobal(render.size.center(Offset.zero));
    if (!point.dx.isFinite || !point.dy.isFinite) return;
    WidgetsBinding.instance.hitTestInView(result, point, _viewId!);
    if (!result.path.any((entry) => identical(entry.target, render))) return;

    final target = position.minScrollExtent;
    if (_reduceMotion) {
      controller.jumpTo(target);
    } else {
      unawaited(controller.animateTo(
        target,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCirc,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_observing) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}
