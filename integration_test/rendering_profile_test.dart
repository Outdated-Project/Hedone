import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FrameTiming;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hedone/app.dart';
import 'package:hedone/core/app_model.dart';
import 'package:hedone/data/repository.dart';
import 'package:hedone/ui/design.dart';

import '../test/layout_test.dart' show FixtureTransport, MemoryPreferences;

/// UI isolation benchmark. Local test posters remove upstream latency; this is
/// deliberately not a video-decoding or real-network performance claim.
class _ProfileTransport extends FixtureTransport {
  _ProfileTransport(this.origin);
  final String origin;
  @override
  Future<dynamic> request(Map<String, dynamic> payload) async => {
    'items': List.generate(
      48,
      (i) => {
        'id': i + 1,
        'title': '性能回归故事 ${i + 1}',
        'cover': '$origin/cover/$i',
        'episode_count': 24,
        'score': 8.6,
      },
    ),
    'pagination': {'pages': 1},
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('profile navigation and image residency', (tester) async {
    final asset = await rootBundle.load('assets/brand.png');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(asset.buffer.asUint8List());
      await request.response.close();
    });
    final cache = PaintingBinding.instance.imageCache;
    cache
      ..maximumSize = 96
      ..maximumSizeBytes = 32 * 1024 * 1024;
    final model = AppModel(
      Repository(_ProfileTransport('http://127.0.0.1:${server.port}')),
      MemoryPreferences(),
    );
    final frames = <FrameTiming>[];
    final reportedRates = <double>{};
    var framesOverDisplayBudget = 0;
    void collect(List<FrameTiming> timings) {
      frames.addAll(timings);
      final hz = tester.view.display.refreshRate;
      if (!hz.isFinite || hz <= 0) return;
      reportedRates.add(hz);
      final budgetUs = 1000000 / hz;
      framesOverDisplayBudget += timings
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > budgetUs ||
                f.rasterDuration.inMicroseconds > budgetUs,
          )
          .length;
    }

    try {
      await tester.pumpWidget(HedoneApp(model: model));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 1));
      final before = ProcessInfo.currentRss;
      var peak = before;
      binding.addTimingsCallback(collect);
      for (var round = 0; round < 4; round++) {
        for (final icon in [
          Icons.search_rounded,
          Icons.forum_outlined,
          Icons.bookmarks_outlined,
          Icons.tune_rounded,
          Icons.explore_outlined,
        ]) {
          await tester.tap(find.byIcon(icon).hitTestable().last);
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          peak = math.max(peak, ProcessInfo.currentRss);
        }
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView).first)
            .controller
            ?.jumpTo(0);
        await tester.pump();
        await tester.drag(
          find.byType(CustomScrollView).first,
          const Offset(0, -500),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 16));
      }
      // Exercise retargeting while the previous spring is still moving.
      for (var i = 0; i < 10; i++) {
        await tester.tap(
          find
              .byIcon(i.isEven ? Icons.search_rounded : Icons.explore_outlined)
              .hitTestable()
              .last,
        );
        await tester.pump(const Duration(milliseconds: 70));
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(seconds: 2));
      binding.removeTimingsCallback(collect);
      expect(
        frames,
        isNotEmpty,
        reason: 'No engine frame timings were received',
      );
      double percentile(List<int> values, double p) {
        values.sort();
        return values[((values.length - 1) * p).round()] / 1000;
      }

      final build = frames.map((f) => f.buildDuration.inMicroseconds).toList();
      final raster = frames
          .map((f) => f.rasterDuration.inMicroseconds)
          .toList();
      binding.reportData = {
        'scenario':
            '${Platform.operatingSystem} Profile; 48 local brand-image test posters; 20 settled navigation changes; 10 interrupted changes; 4 scrolls; no video decoder',
        'os': Platform.operatingSystemVersion,
        'frames': frames.length,
        // Sampled at timing delivery; OS rate changes may precede this callback.
        'reported_display_rates_hz': reportedRates.toList()..sort(),
        'frames_over_reported_display_budget': framesOverDisplayBudget,
        'build_ms_p50': percentile(build, .5),
        'build_ms_p90': percentile(build, .9),
        'build_ms_p99': percentile(build, .99),
        'raster_ms_p50': percentile(raster, .5),
        'raster_ms_p90': percentile(raster, .9),
        'raster_ms_p99': percentile(raster, .99),
        'frames_over_16_67ms': frames
            .where(
              (f) =>
                  f.buildDuration.inMicroseconds > 16667 ||
                  f.rasterDuration.inMicroseconds > 16667,
            )
            .length,
        'rss_before_bytes': before,
        'rss_peak_sampled_bytes': peak,
        'rss_after_bytes': ProcessInfo.currentRss,
        'decoded_cache_bytes': cache.currentSizeBytes,
        'live_image_count': cache.liveImageCount,
      };
      expect(tester.takeException(), isNull);
    } finally {
      binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await server.close(force: true);
    }
  });
}
