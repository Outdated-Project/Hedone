import '../data/models.dart';
import 'design.dart';
import 'haptics.dart';

/// Lazily builds adjacent episode pages. Only the selected page owns the video
/// widget; a completed gesture, not each drag update, requests another episode.
class EpisodePager extends StatefulWidget {
  const EpisodePager({
    required this.episodes,
    required this.selected,
    required this.video,
    required this.placeholder,
    required this.onSelect,
    this.onPrepare,
    super.key,
  });
  final List<Episode> episodes;
  final int selected;
  final Widget video;
  final Widget Function(BuildContext, Episode) placeholder;
  final ValueChanged<int> onSelect;
  final ValueChanged<int>? onPrepare;
  @override
  State<EpisodePager> createState() => _EpisodePagerState();
}

class _EpisodePagerState extends State<EpisodePager> {
  late final PageController _pages;
  late Map<int, int> _positions;
  int _candidate = 0;
  int _syncEpoch = 0;
  bool _syncPending = false;
  Size? _viewport;
  int get _selected => _positions[widget.selected] ?? 0;

  @override
  void initState() {
    super.initState();
    _index();
    _candidate = _selected;
    _pages = PageController(initialPage: _selected);
  }

  void _index() {
    _positions = {
      for (var i = 0; i < widget.episodes.length; i++)
        widget.episodes[i].number: i,
    };
  }

  @override
  void didUpdateWidget(EpisodePager old) {
    super.didUpdateWidget(old);
    if (!identical(old.episodes, widget.episodes)) _index();
    if (old.selected != widget.selected ||
        !identical(old.episodes, widget.episodes)) {
      _synchronize();
    }
  }

  void _synchronize() {
    final epoch = ++_syncEpoch;
    _candidate = _selected;
    _syncPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _syncEpoch) return;
      // Attachment alone does not guarantee PageController.page is non-null.
      // jumpToPage also handles an unmeasured or zero-size viewport.
      if (_pages.hasClients) _pages.jumpToPage(_selected);
      _candidate = _selected;
      _syncPending = false;
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.episodes.isEmpty) return widget.video;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (event) {
        if (event.depth == 0 &&
            !_syncPending &&
            _candidate != _selected &&
            _candidate >= 0 &&
            _candidate < widget.episodes.length) {
          final number = widget.episodes[_candidate].number;
          final epoch = _syncEpoch;
          // Dispatch after scroll layout; the owner may immediately rebuild.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                !_syncPending &&
                epoch == _syncEpoch &&
                _positions.containsKey(number) &&
                number != widget.selected) {
              AppHaptics.selection(context);
              widget.onSelect(number);
            }
          });
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          if (_viewport != viewport) {
            final previous = _viewport;
            // Buffering/controls can change the available height during a
            // gesture. Only a width change or collapsed viewport cancels it.
            if (previous != null &&
                (previous.width != viewport.width ||
                    previous.height == 0 ||
                    viewport.height == 0)) {
              _synchronize();
            }
            _viewport = viewport;
          }
          return PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            allowImplicitScrolling: false,
            onPageChanged: (value) {
              if (_syncPending) return;
              _candidate = value;
              if (value != _selected) {
                widget.onPrepare?.call(widget.episodes[value].number);
              }
            },
            itemCount: widget.episodes.length,
            itemBuilder: (context, index) => index == _selected
                ? widget.video
                : widget.placeholder(context, widget.episodes[index]),
          );
        },
      ),
    );
  }
}
