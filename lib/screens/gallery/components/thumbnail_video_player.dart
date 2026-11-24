import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// [JA] サムネイル上で画面の大部分を占めた際にミュート自動再生する動画ウィジェット
/// [EN] Video thumbnail widget that automatically plays muted when occupying most of the screen
class ThumbnailVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String thumbnailUrl;
  final double bottomOffset;

  const ThumbnailVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.thumbnailUrl,
    this.bottomOffset = 8.0,
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
  ScrollPosition? _scrollPosition;

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
    final newPosition = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != newPosition) {
      _scrollPosition?.removeListener(_checkVisibility);
      _scrollPosition = newPosition;
      _scrollPosition?.addListener(_checkVisibility);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scrollPosition?.removeListener(_checkVisibility);
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    if (mounted && !_isDisposed) {
      setState(() {});
    }
  }

  void _checkVisibility() {
    if (!mounted || _isDisposed) return;
    final rb = context.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return;

    final pos = rb.localToGlobal(Offset.zero);
    final size = rb.size;
    final screenHeight = MediaQuery.of(context).size.height;

    // 画面中央線がアイテムの縦幅内にある場合（画面の主役として大部分を占める）
    final midY = screenHeight * 0.5;
    final isCenter = pos.dy <= midY && (pos.dy + size.height) >= midY;

    if (isCenter != _isMostlyVisible) {
      _isMostlyVisible = isCenter;
      if (_isMostlyVisible) {
        if (_controller == null) {
          _initAndPlay();
        } else if (!_userPaused && _isInitialized) {
          _controller?.play();
        }
      } else {
        if (_isInitialized) {
          _controller?.pause();
        }
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _initAndPlay() async {
    if (widget.videoUrl.isEmpty) return;
    final controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
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

      if (!_userPaused && _isMostlyVisible) {
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
      await _initAndPlay();
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
