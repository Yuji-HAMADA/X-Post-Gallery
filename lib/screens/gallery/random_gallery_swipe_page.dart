import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../detail/detail_image_item.dart';
import 'user_gallery_swipe_page.dart';

/// ランダムに選んだユーザーの画像を左右スワイプで表示するページ
class RandomGallerySwipePage extends StatefulWidget {
  final List<String> usernames;
  final String title;

  const RandomGallerySwipePage({
    super.key,
    required this.usernames,
    required this.title,
  });

  @override
  State<RandomGallerySwipePage> createState() => _RandomGallerySwipePageState();
}

class _RandomGallerySwipePageState extends State<RandomGallerySwipePage> {
  late final PageController _pageController;
  final List<TweetItem> _historyItems = [];
  int _historyIndex = 0;
  bool _isZoomed = false;
  bool _initialized = false;
  bool _initError = false;
  bool _isLoadingNext = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _initRandomGallery();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _initRandomGallery() async {
    if (widget.usernames.isEmpty) {
      if (mounted) {
        setState(() {
          _initError = true;
          _initialized = true;
        });
      }
      return;
    }

    // 最初のアイテムをロード
    await _loadNextRandomItem();
    if (_historyItems.isEmpty) {
      if (mounted) {
        setState(() {
          _initError = true;
          _initialized = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _initialized = true;
      });
    }

    // 2枚目のアイテムをバックグラウンドでロード
    _checkAndLoadMore();
  }

  Future<void> _loadNextRandomItem() async {
    if (_isLoadingNext) return;
    _isLoadingNext = true;

    final vm = context.read<GalleryViewModel>();
    final random = math.Random();

    // 無限ループを防ぐため試行回数を制限
    for (int retry = 0; retry < 15; retry++) {
      if (widget.usernames.isEmpty) break;
      final username = widget.usernames[random.nextInt(widget.usernames.length)];
      try {
        final items = await vm.fetchUserItems(username);
        final imageItems = items.where((item) => item.mediaUrls.isNotEmpty).toList();
        if (imageItems.isNotEmpty) {
          final randomItem = imageItems[random.nextInt(imageItems.length)];
          // 次の画像をプリキャッシュ
          if (randomItem.origUrls.isNotEmpty && mounted) {
            precacheImage(NetworkImage(randomItem.origUrls.first), context);
          }
          if (mounted) {
            setState(() {
              _historyItems.add(randomItem);
              _isLoadingNext = false;
            });
          }
          return;
        }
      } catch (e) {
        debugPrint("Error loading random user items: $e");
      }
    }

    if (mounted) {
      setState(() {
        _isLoadingNext = false;
      });
    }
  }

  String? _getUsername(TweetItem item) {
    if (item.username != null && item.username!.isNotEmpty) {
      return item.username;
    }
    final match = RegExp(r'^@([^:]+):').firstMatch(item.fullText);
    if (match != null) {
      return match.group(1)?.trim();
    }
    return null;
  }

  Future<void> _launchTweet(TweetItem item) async {
    String? urlStr = item.postUrl;
    if (urlStr == null || urlStr.isEmpty) {
      final username = _getUsername(item);
      if (username != null && username.isNotEmpty && item.id.isNotEmpty) {
        urlStr = 'https://x.com/$username/status/${item.id}';
      }
    }
    if (urlStr != null && urlStr.isNotEmpty) {
      final url = Uri.parse(urlStr);
      try {
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        }
      } catch (e) {
        _showError('リンクを開けませんでした: $e');
      }
    }
  }

  void _openUserGallery(String username) {
    if (!mounted) return;
    final vm = context.read<GalleryViewModel>();

    int initialIndex = widget.usernames.indexWhere(
      (u) => u.toLowerCase() == username.toLowerCase(),
    );

    List<String> sortedUsernames = List.from(widget.usernames);
    if (initialIndex < 0) {
      sortedUsernames.insert(0, username);
      initialIndex = 0;
    }

    final gistIds = sortedUsernames.map((u) => vm.userGists[u]).toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserGallerySwipePage(
          usernames: sortedUsernames,
          userGistIds: gistIds,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  void _handleZoomChanged(bool zoomed) {
    if (_isZoomed != zoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _isZoomed = false;
      _historyIndex = index;
    });

    _checkAndLoadMore();
  }

  Future<void> _checkAndLoadMore() async {
    int failCount = 0;
    while (_historyIndex >= _historyItems.length - 1) {
      if (failCount > 5) break; // 最大5回連続の失敗で無限ループを防ぐ
      if (_isLoadingNext) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (!mounted) return;
        continue;
      }
      final prevLength = _historyItems.length;
      await _loadNextRandomItem();
      if (!mounted) return;
      if (_historyItems.length == prevLength) {
        failCount++;
      } else {
        failCount = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: Text(widget.title),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_initError || _historyItems.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: Text(widget.title),
        ),
        body: const Center(
          child: Text(
            '画像を読み込めませんでした。\n対象ユーザーが存在するか確認してください。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final currentItem = _historyIndex < _historyItems.length ? _historyItems[_historyIndex] : null;
    final currentUsername = currentItem != null ? _getUsername(currentItem) : null;

    return Consumer<GalleryViewModel>(
      builder: (context, vm, _) {
        final isFav = currentUsername != null && vm.isFavorite(currentUsername);

        return Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            title: currentUsername != null
                ? GestureDetector(
                    onTap: () => _openUserGallery(currentUsername),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '@$currentUsername',
                            style: const TextStyle(fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: Colors.white70,
                        ),
                      ],
                    ),
                  )
                : Text(widget.title),
            actions: [
              if (currentUsername != null)
                IconButton(
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? Colors.redAccent : null,
                  ),
                  onPressed: () => vm.toggleFavorite(currentUsername),
                ),
              if (currentItem != null)
                IconButton(
                  icon: const Icon(Icons.open_in_new),
                  tooltip: '元の投稿を開く',
                  onPressed: () => _launchTweet(currentItem),
                ),
            ],
          ),
          body: PageView.builder(
            controller: _pageController,
            physics: _isZoomed
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            onPageChanged: _onPageChanged,
            itemCount: _historyItems.length + 1, // +1 is the loading indicator/next placeholder
            itemBuilder: (context, index) {
              if (index < _historyItems.length) {
                return DetailImageItem(
                  item: _historyItems[index],
                  onZoomChanged: _handleZoomChanged,
                );
              } else {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }
            },
          ),
        );
      },
    );
  }
}
