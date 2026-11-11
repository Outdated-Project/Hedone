import 'design.dart';

/// Rotation changes geometry, never the parent of the video or episode pager.
/// Keeping these elements mounted preserves texture and inherited state.
class CinemaLayout extends StatelessWidget {
  const CinemaLayout({
    required this.video,
    this.header = const SizedBox.shrink(),
    this.controls = const SizedBox.shrink(),
    super.key,
  });
  final Widget video, header, controls;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final overlay = constraints.maxWidth > constraints.maxHeight;
      return CustomMultiChildLayout(
        delegate: _CinemaDelegate(overlay: overlay),
        children: [
          LayoutId(id: _Slot.video, child: video),
          LayoutId(
            id: _Slot.header,
            child: ClipRect(child: header),
          ),
          LayoutId(
            id: _Slot.controls,
            child: ColoredBox(
              color: overlay
                  ? Colors.black.withValues(alpha: .8)
                  : Colors.transparent,
              child: SingleChildScrollView(child: controls),
            ),
          ),
        ],
      );
    },
  );
}

enum _Slot { video, header, controls }

class _CinemaDelegate extends MultiChildLayoutDelegate {
  _CinemaDelegate({required this.overlay});
  final bool overlay;

  @override
  void performLayout(Size size) {
    BoxConstraints band(double fraction) => BoxConstraints(
      minWidth: size.width,
      maxWidth: size.width,
      maxHeight: size.height * fraction,
    );
    final header = layoutChild(_Slot.header, band(.25));
    final controls = layoutChild(_Slot.controls, band(overlay ? .5 : .45));
    final videoHeight = overlay
        ? size.height
        : (size.height - header.height - controls.height).clamp(
            0.0,
            size.height,
          );
    layoutChild(
      _Slot.video,
      BoxConstraints.tight(Size(size.width, videoHeight)),
    );
    positionChild(_Slot.video, Offset(0, overlay ? 0 : header.height));
    positionChild(_Slot.header, Offset.zero);
    positionChild(_Slot.controls, Offset(0, size.height - controls.height));
  }

  @override
  bool shouldRelayout(_CinemaDelegate oldDelegate) =>
      overlay != oldDelegate.overlay;
}
