import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../utils/video_http_headers.dart';
import '../../../utils/video_wakelock_manager.dart';

/// [JA] サムネイル上で画面の大部分を占めた際にミュート自動再生する動画ウィジェット
/// [EN] Video thumbnail widget that automatically plays muted when occupying most of the screen
class ThumbnailVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String thumbnailUrl;
  final double bottomOffset;
  final double progressBarBottomOffset;
  final bool enableAutoplay;

  const ThumbnailVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.thumbnailUrl,
    this.bottomOffset = 8.0,
    this.progressBarBottomOffset = 0.0,
    this.enableAutoplay = true,
  });

  @override
  State<ThumbnailVideoPlayer> createState() => _ThumbnailVideoPlayerState();
}

class _ThumbnailVideoPlayerState extends State<ThumbnailVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isMostlyVisible = false;
  bool _userPaused = false;
  bool _isDisposed = false;
  bool _wasPlaying = false;
  final List<ScrollPosition> _attachedPositions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkVisibility();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateScrollListeners();
  }

  void _updateScrollListeners() {
    for (final pos in _attachedPositions) {
      pos.removeListener(_checkVisibility);
    }
    _attachedPositions.clear();

    // 祖先ツリーのすべての Scrollable (ListView, PageView 等) をリッスン
    context.visitAncestorElements((element) {
      if (element.widget is Scrollable) {
        try {
          final state = (element as StatefulElement).state;
          if (state is ScrollableState) {
            final pos = state.position;
            if (!_attachedPositions.contains(pos)) {
              _attachedPositions.add(pos);
              pos.addListener(_checkVisibility);
            }
          }
        } catch (_) {}
      }
      return true;
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final pos in _attachedPositions) {
      pos.removeListener(_checkVisibility);
    }
    _attachedPositions.clear();
    _controller?.removeListener(_onControllerUpdate);
    VideoWakelockManager.onDisposed(this);
    _controller?.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted || _isDisposed) return;
    final isPlaying = _controller?.value.isPlaying ?? false;
    if (_wasPlaying != isPlaying) {
      _wasPlaying = isPlaying;
      VideoWakelockManager.onPlaybackStateChanged(this, isPlaying);
      setState(() {});
    }
  }

  void _checkVisibility() {
    if (!mounted || _isDisposed) return;
    final rb = context.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return;

    final pos = rb.localToGlobal(Offset.zero);
    final size = rb.size;
    final screenSize = MediaQuery.of(context).size;

    // 水平方向および垂直方向の両方で画面中央線を含むか判定
    final midX = screenSize.width * 0.5;
    final midY = screenSize.height * 0.5;
    final isCenterHorizontal = pos.dx <= midX && (pos.dx + size.width) >= midX;
    final isCenterVertical = pos.dy <= midY && (pos.dy + size.height) >= midY;

    final isMostlyVisible = isCenterHorizontal && isCenterVertical;

    if (isMostlyVisible != _isMostlyVisible) {
      _isMostlyVisible = isMostlyVisible;
      if (_isMostlyVisible) {
        if (widget.enableAutoplay) {
          if (_controller == null) {
            _initAndPlay();
          } else if (!_userPaused && _isInitialized) {
            _controller?.play();
          }
        }
      } else {
        if (_isInitialized) {
          _controller?.pause();
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _initAndPlay({bool forcePlay = false}) async {
    if (widget.videoUrl.isEmpty) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.videoUrl),
      httpHeaders: buildVideoHttpHeaders(widget.videoUrl),
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (_isDisposed) {
        await controller.dispose();
        return;
      }
      await controller.setVolume(0.0); // 常にミュート
      await controller.setLooping(true);
      controller.addListener(_onControllerUpdate);

      final shouldPlay =
          forcePlay || (widget.enableAutoplay && !_userPaused && _isMostlyVisible);
      if (shouldPlay) {
        await controller.play();
      }

      if (mounted && !_isDisposed) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('[ThumbnailVideoPlayer] Init error: $e');
      if (_isDisposed) {
        await controller.dispose();
      }
    }
  }

  Future<void> _togglePlayPause() async {
    if (_controller == null) {
      _userPaused = false;
      await _initAndPlay(forcePlay: true);
      return;
    }

    if (_controller!.value.isPlaying) {
      _userPaused = true;
      await _controller!.pause();
    } else {
      _userPaused = false;
      await _controller!.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _controller?.value.isPlaying ?? false;

    return Stack(
      fit: StackFit.expand,
      children: [
        // サムネイル静止画
        widget.thumbnailUrl.isNotEmpty
            ? Image.network(
                widget.thumbnailUrl,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (c, e, s) => const Center(
                  child: Icon(Icons.broken_image, color: Colors.grey),
                ),
              )
            : const Center(
                child: Icon(Icons.broken_image, color: Colors.grey),
              ),

        // 動画プレイヤー（初期化完了時に表示）
        if (_isInitialized && _controller != null)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _controller!.value.size.width > 0
                    ? _controller!.value.size.width
                    : 1,
                height: _controller!.value.size.height > 0
                    ? _controller!.value.size.height
                    : 1,
                child: VideoPlayer(_controller!),
              ),
            ),
          ),

        // 1列自動再生時のみ下部に動画進捗バー（表示専用）を表示
        if (widget.enableAutoplay && _isInitialized && _controller != null)
          Positioned(
            bottom: widget.progressBarBottomOffset,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: VideoProgressIndicator(
                _controller!,
                allowScrubbing: false,
                padding: EdgeInsets.zero,
                colors: const VideoProgressColors(
                  playedColor: Colors.blueAccent,
                  bufferedColor: Colors.white30,
                  backgroundColor: Colors.white10,
                ),
              ),
            ),
          ),

        // 下部中央の Play/Pause ボタン
        Positioned(
          bottom: widget.bottomOffset,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlayPause,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
