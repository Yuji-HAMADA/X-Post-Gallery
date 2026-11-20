import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

typedef WakelockHandler = Future<void> Function(bool enable);

/// [JA] 動画再生中の画面スリープ（消灯）抑制を管理するマネージャ
/// 複数の動画プレイヤーが存在する場合でも、少なくとも1つが再生中であればWakelockを維持し、
/// 全ての動画が停止または画面離脱（dispose）した際に解除する。
/// [EN] Manager that suppresses screen sleep (dimming/standby) during video playback.
class VideoWakelockManager {
  static final Set<Object> _activePlayingKeys = {};

  @visibleForTesting
  static WakelockHandler? customWakelockHandler;

  static bool get hasActivePlaying => _activePlayingKeys.isNotEmpty;

  @visibleForTesting
  static void resetForTesting() {
    _activePlayingKeys.clear();
    customWakelockHandler = null;
  }

  /// [JA] 再生状態が変化した際に呼び出す
  /// [EN] Called when playback state changes
  static Future<void> onPlaybackStateChanged(Object key, bool isPlaying) async {
    if (isPlaying) {
      _activePlayingKeys.add(key);
    } else {
      _activePlayingKeys.remove(key);
    }
    await _updateWakelock();
  }

  /// [JA] ウィジェット破棄・画面離脱時に呼び出す
  /// [EN] Called when widget is disposed or user navigates away
  static Future<void> onDisposed(Object key) async {
    _activePlayingKeys.remove(key);
    await _updateWakelock();
  }

  static Future<void> _updateWakelock() async {
    final shouldEnable = _activePlayingKeys.isNotEmpty;
    try {
      if (customWakelockHandler != null) {
        await customWakelockHandler!(shouldEnable);
      } else {
        if (shouldEnable) {
          await WakelockPlus.enable();
        } else {
          await WakelockPlus.disable();
        }
      }
    } catch (e) {
      debugPrint('[VideoWakelockManager] Wakelock update error: $e');
    }
  }
}
