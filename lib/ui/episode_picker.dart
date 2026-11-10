import '../data/models.dart';
import 'design.dart';

Future<int?> pickEpisode(
  BuildContext context,
  List<Episode> episodes,
  int selected,
) => M3EDialog.show<int>(
  context,
  dialog: M3EDialog(
    title: '选集 · 共 ${episodes.length} 集',
    content: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * .5,
      child: GridView.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisExtent:
              56 * (MediaQuery.textScalerOf(context).scale(14) / 14),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: episodes.length,
        itemBuilder: (context, i) => M3EButton(
          style: episodes[i].number == selected
              ? M3EButtonStyle.filled
              : M3EButtonStyle.tonal,
          onPressed: () => Navigator.pop(context, episodes[i].number),
          label: Text('第 ${episodes[i].number} 集'),
        ),
      ),
    ),
    actions: [
      M3EButton(
        onPressed: () => Navigator.pop(context),
        label: const Text('关闭'),
        style: M3EButtonStyle.text,
      ),
    ],
  ),
);
