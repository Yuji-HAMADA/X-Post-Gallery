import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 動画再生ウィジェット（再生/一時停止、シークバー、消音切り替え対応）
class VideoPlayerItem extends StatefulWidget {
  final String videoUrl;
  final String? thumbnailUrl;

  const VideoPlayerItem({
    super.key,
    required this.videoUrl,
    this.thumbnailUrl,
  });

  @override
  State<VideoPlayerItem> createState() => _VideoPlayerItemState();
}

class _VideoPlayerItemState extends State<VideoPlayerItem> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _isMuted = true;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await _controller.initialize();
      await _controller.setVolume(0.0);
      await _controller.setLooping(true);
      await _controller.play();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('VideoPlayer initialization error: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (!_isInitialized) return;
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  void _toggleMute() {
    if (!_isInitialized) return;
    setState(() {
      _isMuted = !_isMuted;
      _controller.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    if (_hasError) {
      return Container(
        width: screenWidth,
        height: 240,
        color: Colors.black,
        alignment: Alignment.center,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            SizedBox(height: 8),
            Text(
              '動画の読み込みに失敗しました',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (!_isInitialized) {
      return Container(
        width: screenWidth,
        height: 240,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty)
              Image.network(
                widget.thumbnailUrl!,
                fit: BoxFit.contain,
                errorBuilder: (c, e, s) => const SizedBox(),
              ),
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white70,
                strokeWidth: 2,
              ),
            ),
          ],
        ),
      );
    }

    final double videoAspect = _controller.value.aspectRatio > 0
        ? _controller.value.aspectRatio
        : (16 / 9);

    // 縦長動画の場合に画面高さを超えないように制約
    final double maxVideoHeight = screenHeight * 0.75;
    final double calculatedHeight = screenWidth / videoAspect;
    final double finalHeight = calculatedHeight > maxVideoHeight
        ? maxVideoHeight
        : calculatedHeight;

    return Container(
      width: screenWidth,
      height: finalHeight,
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePlayPause,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: videoAspect,
                child: VideoPlayer(_controller),
              ),
            ),
            // 一時停止時の再生ボタン表示
            if (!_controller.value.isPlaying)
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(14),
                child: const Icon(
                  Icons.play_arrow,
                  size: 44,
                  color: Colors.white,
                ),
              ),
            // 右上: 音声ミュートトグル（ステータスバー下の「戻る」ボタンと同じ高さに配置）
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 12,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleMute,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isMuted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
            // 下部: シークバー
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: VideoProgressIndicator(
                _controller,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                colors: const VideoProgressColors(
                  playedColor: Colors.blueAccent,
                  bufferedColor: Colors.white30,
                  backgroundColor: Colors.white10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
