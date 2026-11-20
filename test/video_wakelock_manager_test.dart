import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/utils/video_wakelock_manager.dart';

void main() {
  setUp(() {
    VideoWakelockManager.resetForTesting();
  });

  tearDown(() {
    VideoWakelockManager.resetForTesting();
  });

  group('VideoWakelockManager Tests', () {
    test('enables wakelock when playback starts and disables when paused', () async {
      final wakelockStates = <bool>[];
      VideoWakelockManager.customWakelockHandler = (enable) async {
        wakelockStates.add(enable);
      };

      final playerKey = Object();

      // 再生開始
      await VideoWakelockManager.onPlaybackStateChanged(playerKey, true);
      expect(VideoWakelockManager.hasActivePlaying, isTrue);
      expect(wakelockStates, [true]);

      // 一時停止
      await VideoWakelockManager.onPlaybackStateChanged(playerKey, false);
      expect(VideoWakelockManager.hasActivePlaying, isFalse);
      expect(wakelockStates, [true, false]);
    });

    test('disables wakelock when player is disposed during playback', () async {
      final wakelockStates = <bool>[];
      VideoWakelockManager.customWakelockHandler = (enable) async {
        wakelockStates.add(enable);
      };

      final playerKey = Object();

      // 再生開始
      await VideoWakelockManager.onPlaybackStateChanged(playerKey, true);
      expect(VideoWakelockManager.hasActivePlaying, isTrue);
      expect(wakelockStates, [true]);

      // 画面離脱（dispose）
      await VideoWakelockManager.onDisposed(playerKey);
      expect(VideoWakelockManager.hasActivePlaying, isFalse);
      expect(wakelockStates, [true, false]);
    });

    test('manages multiple players: wakelock stays enabled while at least one is playing', () async {
      final wakelockStates = <bool>[];
      VideoWakelockManager.customWakelockHandler = (enable) async {
        wakelockStates.add(enable);
      };

      final player1 = Object();
      final player2 = Object();

      // player1 再生開始
      await VideoWakelockManager.onPlaybackStateChanged(player1, true);
      expect(wakelockStates.last, isTrue);

      // player2 再生開始
      await VideoWakelockManager.onPlaybackStateChanged(player2, true);
      expect(wakelockStates.last, isTrue);

      // player1 一時停止（player2 はまだ再生中）
      await VideoWakelockManager.onPlaybackStateChanged(player1, false);
      expect(VideoWakelockManager.hasActivePlaying, isTrue);
      expect(wakelockStates.last, isTrue);

      // player2 画面離脱（dispose）
      await VideoWakelockManager.onDisposed(player2);
      expect(VideoWakelockManager.hasActivePlaying, isFalse);
      expect(wakelockStates.last, isFalse);
    });
  });
}
