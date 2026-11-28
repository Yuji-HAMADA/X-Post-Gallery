import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/data_source.dart';
import '../../models/tweet_item.dart';
import '../../viewmodels/gallery_viewmodel.dart';
import '../detail/detail_image_item.dart';
import 'components/dialog_helpers.dart';
import 'user_gallery_swipe_page.dart';

/// [JA] ランダムに選んだ投稿（すべて / 動画のみ）を左右スワイプで表示するページ
/// [EN] Page that displays randomly selected posts (all or videos only) via horizontal swipe
class RandomGallerySwipePage extends StatefulWidget {
  final List<String> usernames;
  final String title;
  final bool videosOnly;
  final List<TweetItem>? preloadedItems;
  final bool allowOpenUserGallery;

  const RandomGallerySwipePage({
    super.key,
    required this.usernames,
    required this.title,
    this.videosOnly = false,
    this.preloadedItems,
    this.allowOpenUserGallery = true,
  });

  @override
  State<RandomGallerySwipePage> createState() => _RandomGallerySwipePageState();
}

class _RandomGallerySwipePageState extends State<RandomGallerySwipePage> {
  late final PageController _pageController;
  final List<TweetItem> _historyItems = [];
  final Set<String> _emptyUsers = {};
  final ValueNotifier<bool> _firstVideoMutedNotifier = ValueNotifier<bool>(true);
  int _historyIndex = 0;
  bool _isZoomed = false;
  bool _initialized = false;
  bool _initError = false;
  bool _isLoadingNext = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // preloadedItems がある場合は同期的に precacheImage(..., context) へ到達するため、
    // initState 完了後（初回フレーム後）に初期化を開始する
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initRandomGallery();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _firstVideoMutedNotifier.dispose();
    super.dispose();
  }

  List<TweetItem> _filterEligibleItems(List<TweetItem> items) {
    if (widget.videosOnly) {
      return items
          .where((item) => item.isVideo && item.videoUrl != null)
          .toList();
    }
    return items.where((item) => item.mediaUrls.isNotEmpty).toList();
  }

  TweetItem _pickRandomItem(List<TweetItem> pool, math.Random random) {
    if (pool.length >= 2 && _historyItems.isNotEmpty) {
      final lastId = _historyItems.last.id;
      final nonRepeat = pool.where((item) => item.id != lastId).toList();
      if (nonRepeat.isNotEmpty) {
        return nonRepeat[random.nextInt(nonRepeat.length)];
      }
    }
    return pool[random.nextInt(pool.length)];
  }

  List<String> _resolveCandidateUsernames(GalleryViewModel vm) {
    final available = widget.usernames
        .where((u) => !_emptyUsers.contains(u.toLowerCase()))
        .toList();
    if (available.isEmpty) return [];
    if (!widget.videosOnly) return available;

    // 動画限定時は hasVideo=true または代表アイテムが動画のアカウントを優先して無駄なフェッチを減らす
    final videoUsersFromMaster = vm.items
        .where((item) => item.isVideo && item.extractedUsername != null)
        .map((item) => item.extractedUsername!.toLowerCase())
        .toSet();
    final prioritized = available.where((u) {
      final lower = u.toLowerCase();
      if (videoUsersFromMaster.contains(lower)) return true;
      final entry = vm.userGistEntries[u];
      if (entry != null) return entry.hasVideo;
      for (final e in vm.userGistEntries.entries) {
        if (e.key.toLowerCase() == lower) return e.value.hasVideo;
      }
      return false;
    }).toList();

    return prioritized.isNotEmpty ? prioritized : available;
  }

  Future<void> _initRandomGallery() async {
    if (widget.preloadedItems == null && widget.usernames.isEmpty) {
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

    final random = math.Random();

    // アカウント単位など、既に読み込み済みリストが渡されている場合は即座に抽選
    if (widget.preloadedItems != null) {
      final eligible = _filterEligibleItems(widget.preloadedItems!);
      if (eligible.isNotEmpty) {
        final randomItem = _pickRandomItem(eligible, random);
        if (!randomItem.isVideo && randomItem.origUrls.isNotEmpty && mounted) {
          precacheImage(
            NetworkImage(randomItem.origUrls.first),
            context,
            onError: (_, _) {},
          );
        }
        if (mounted) {
          setState(() {
            _historyItems.add(randomItem);
            _isLoadingNext = false;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _isLoadingNext = false;
        });
      }
      return;
    }

    final vm = context.read<GalleryViewModel>();

    // 無限ループを防ぐため試行回数を制限
    for (int retry = 0; retry < 15; retry++) {
      final candidateUsers = _resolveCandidateUsernames(vm);
      if (candidateUsers.isEmpty) break;
      final username = candidateUsers[random.nextInt(candidateUsers.length)];
      try {
        final items = await vm.fetchUserItems(username);
        final eligible = _filterEligibleItems(items);
        if (eligible.isNotEmpty) {
          final randomItem = _pickRandomItem(eligible, random);
          // 次の静止画像をプリキャッシュ
          if (!randomItem.isVideo &&
              randomItem.origUrls.isNotEmpty &&
              mounted) {
            precacheImage(
              NetworkImage(randomItem.origUrls.first),
              context,
              onError: (_, _) {},
            );
          }
          if (mounted) {
            setState(() {
              _historyItems.add(randomItem);
              _isLoadingNext = false;
            });
          }
          return;
        } else {
          _emptyUsers.add(username.toLowerCase());
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

  Future<void> _launchTweet(TweetItem item) async {
    String? urlStr = item.postUrl;
    if (urlStr == null || urlStr.isEmpty) {
      final username = item.extractedUsername;
      if (username != null && username.isNotEmpty && item.id.isNotEmpty) {
        final source = context.read<GalleryViewModel>().currentSource;
        urlStr = source.fallbackPostUrl(username, item.id);
      }
    }
    if (urlStr != null && urlStr.isNotEmpty) {
      await launchExternalUrl(context, urlStr);
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
      final canonical = vm.getCanonicalUsername(username) ?? username;
      sortedUsernames.insert(0, canonical);
      initialIndex = 0;
    }

    final gistIds = sortedUsernames.map((u) => vm.getGistIdForUser(u)).toList();

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
    // 新しい動画へ切り替わった際は意図しない音声出力を防ぐため必ずMUTE ONへ戻す
    _firstVideoMutedNotifier.value = true;

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
    final l10n = AppLocalizations.of(context);
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
        body: Center(
          child: Text(
            widget.videosOnly
                ? l10n.noVideosFound
                : l10n.failedToLoadImagesCheckUser,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    final currentItem = _historyIndex < _historyItems.length ? _historyItems[_historyIndex] : null;
    final currentUsername = currentItem?.extractedUsername;
    final hasVideo = currentItem?.isVideo ?? false;

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
                ? (widget.allowOpenUserGallery
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
                    : Text(
                        '@$currentUsername',
                        style: const TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ))
                : Text(widget.title),
            actions: [
              if (hasVideo)
                ValueListenableBuilder<bool>(
                  valueListenable: _firstVideoMutedNotifier,
                  builder: (context, isMuted, _) {
                    return IconButton(
                      icon: Icon(
                        isMuted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                      ),
                      tooltip: isMuted ? l10n.tooltipUnmute : l10n.tooltipMute,
                      onPressed: () {
                        _firstVideoMutedNotifier.value =
                            !_firstVideoMutedNotifier.value;
                      },
                    );
                  },
                ),
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
                  tooltip: l10n.tooltipOpenOriginalPost,
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
                  muteNotifier:
                      index == _historyIndex ? _firstVideoMutedNotifier : null,
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
