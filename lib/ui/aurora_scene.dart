import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_3_expressive/material_3_expressive.dart'
    show M3EMotion;

import 'design.dart';

/// A sampled pose retains momentum when a transition changes direction.
class AuroraScenePose {
  const AuroraScenePose({
    required this.opacity,
    this.dx = 0,
    this.scale = 1,
    this.velocity = 0,
    this.scaleVelocity = 0,
  });
  final double opacity, dx, scale, velocity, scaleVelocity;
}

class _SceneTrack {
  _SceneTrack(this.start, this.end)
    : position = SpringSimulation(
        M3EMotion.expressiveSpatialDefault.toDescription(),
        start.dx,
        end.dx,
        start.velocity,
      ),
      size = SpringSimulation(
        M3EMotion.expressiveSpatialDefault.toDescription(),
        start.scale,
        end.scale,
        start.scaleVelocity,
      );

  final AuroraScenePose start, end;
  final SpringSimulation position, size;
}

/// All scenes share the shell's VSync clock. Tracks are allocated only when
/// navigation changes; animation frames never rebuild or lay out page widgets.
class AuroraSceneTransition {
  AuroraSceneTransition._(this.selected, this._tracks, this._paintOrder);

  factory AuroraSceneTransition.settled(int selected, int count) =>
      AuroraSceneTransition._(
        selected,
        List.generate(count, (i) {
          final pose = AuroraScenePose(opacity: i == selected ? 1 : 0);
          return _SceneTrack(pose, pose);
        }),
        List.generate(count, (i) => i),
      );

  final int selected;
  final List<_SceneTrack> _tracks;
  final List<int> _paintOrder;
  static const _springSeconds = .6;

  bool visible(int index) =>
      index == selected || _tracks[index].start.opacity > 0;

  AuroraScenePose sample(int index, double progress) =>
      _sample(index, progress, AuroraMotion.curve.transform(progress));

  AuroraScenePose _sample(int index, double progress, double blend) {
    final track = _tracks[index];
    if (progress >= 1) return track.end;
    if (progress <= 0) return track.start;
    final seconds = progress * _springSeconds;
    return AuroraScenePose(
      opacity:
          (track.start.opacity +
                  (track.end.opacity - track.start.opacity) * blend)
              .clamp(0, 1),
      dx: track.position.x(seconds),
      scale: track.size.x(seconds),
      velocity: track.position.dx(seconds),
      scaleVelocity: track.size.dx(seconds),
    );
  }

  AuroraSceneTransition retarget(int next, double progress) {
    final direction = next > selected ? 1.0 : -1.0;
    final order = [..._paintOrder];
    // Changing the stacking order of translucent, visible scenes would change
    // the composed image immediately even if every individual pose is intact.
    if (sample(next, progress).opacity <= 0) {
      order
        ..remove(next)
        ..add(next);
    }
    return AuroraSceneTransition._(
      next,
      List.generate(_tracks.length, (i) {
        final current = sample(i, progress);
        // Only invisible scenes may be repositioned for a new entrance.
        final start = current.opacity > 0
            ? current
            : AuroraScenePose(opacity: 0, dx: direction * 32, scale: .985);
        final end = i == next
            ? const AuroraScenePose(opacity: 1)
            : AuroraScenePose(opacity: 0, dx: -direction * 32, scale: .985);
        return _SceneTrack(start, end);
      }),
      order,
    );
  }
}

/// Flow submits paint transforms; settled pages need no opacity layer.
class AuroraSceneDelegate extends FlowDelegate {
  AuroraSceneDelegate({required this.animation, required this.transition})
    : super(repaint: animation);

  final Animation<double> animation;
  final AuroraSceneTransition transition;

  double opacity(int index) =>
      transition.sample(index, animation.value).opacity;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints;

  @override
  void paintChildren(FlowPaintingContext context) {
    if (animation.isCompleted) {
      context.paintChild(transition.selected);
      return;
    }
    final blend = AuroraMotion.curve.transform(animation.value);
    var coverage = 0.0;
    void paint(int i) {
      if (!transition.visible(i)) return;
      final pose = transition._sample(i, animation.value, blend);
      if (pose.opacity <= 0) return;
      coverage += pose.opacity;
      // Opaque page backgrounds allow weighted source-over blending: the
      // bottom scene needs no opacity layer, and the surface never fades through.
      final alpha = (pose.opacity / coverage).clamp(0.0, 1.0);
      context.paintChild(
        i,
        opacity: alpha,
        transform: Matrix4.identity()
          ..translateByDouble(
            pose.dx + context.size.width * (1 - pose.scale) / 2,
            context.size.height * (1 - pose.scale) / 2,
            0,
            1,
          )
          ..scaleByDouble(pose.scale, pose.scale, 1, 1),
      );
    }

    for (final i in transition._paintOrder) {
      paint(i);
    }
  }

  @override
  bool shouldRepaint(AuroraSceneDelegate old) =>
      old.animation != animation || old.transition != transition;
}
