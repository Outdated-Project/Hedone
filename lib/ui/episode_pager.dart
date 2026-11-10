import '../data/models.dart';
import 'design.dart';

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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pages.hasClients) return;
        if ((_pages.page! - _selected).abs() > .01) {
          _pages.jumpToPage(_selected);
        }
        _candidate = _selected;
      });
    }
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
            _candidate != _selected &&
            _candidate < widget.episodes.length) {
          final number = widget.episodes[_candidate].number;
          // Dispatch after scroll layout; the owner may immediately rebuild.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && number != widget.selected) widget.onSelect(number);
          });
        }
        return false;
      },
      child: PageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        allowImplicitScrolling: false,
        onPageChanged: (value) {
          _candidate = value;
          if (value != _selected) {
            widget.onPrepare?.call(widget.episodes[value].number);
          }
        },
        itemCount: widget.episodes.length,
        itemBuilder: (context, index) => index == _selected
            ? widget.video
            : widget.placeholder(context, widget.episodes[index]),
      ),
    );
  }
}
