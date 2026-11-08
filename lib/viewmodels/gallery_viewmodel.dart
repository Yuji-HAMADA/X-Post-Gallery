import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/tweet_item.dart';
import '../services/gallery_repository.dart';
import '../services/github_service.dart';
import '../utils/env_helper.dart';

enum GalleryStatus { initial, loading, authenticated, error }

const String _externalMasterGistId = String.fromEnvironment('MASTER_GIST_ID');
const String _externalFavoriteGistId = String.fromEnvironment(
  'FAVORITE_GIST_ID',
);

class GalleryViewModel extends ChangeNotifier {
  final GalleryRepository _repository;
  final GitHubService _githubService;

  GalleryViewModel({
    GalleryRepository? repository,
    GitHubService? githubService,
  }) : _repository = repository ?? GalleryRepository(),
       _githubService = githubService ?? GitHubService();

  // --- 状態 ---
  GalleryStatus _status = GalleryStatus.initial;
  GalleryStatus get status => _status;

  List<TweetItem> _items = [];
  List<TweetItem> get items => _items;

  String _userName = '';
  String get userName => _userName;

  Map<String, String> _userGists = {};
  Map<String, String> get userGists => _userGists;

  Map<String, int> _userPriorities = {};
  Map<String, int> get userPriorities => _userPriorities;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  // --- お気に入り ---
  Set<String> _favoriteUsers = {};
  Set<String> get favoriteUsers => _favoriteUsers;
  bool isFavorite(String username) => _favoriteUsers.contains(username);

  // --- 選択状態 ---
  final Set<String> _selectedIds = {};
  Set<String> get selectedIds => _selectedIds;
  bool get isSelectionMode => _selectedIds.isNotEmpty;
  int get selectedCount => _selectedIds.length;

  // --- Helper ---
  String get defaultMasterGistId =>
      resolveEnv(_externalMasterGistId, 'MASTER_GIST_ID');
  String get favoriteGistId =>
      resolveEnv(_externalFavoriteGistId, 'FAVORITE_GIST_ID');

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  // --- アクション ---

  /// 初期ロード：URLパラメータ → SharedPreferences → null（ダイアログ必要）
  Future<bool> handleInitialLoad() async {
    // 1. URLパラメータ
    final String? urlId = Uri.base.queryParameters['id'];
    if (urlId != null && urlId.isNotEmpty) {
      debugPrint("URL parameter 'id' found: $urlId");
      await loadGallery(urlId);
      return true;
    }

    // 2. 保存済みID
    final savedId = await _repository.getSavedGistId();
    if (savedId != null && savedId.isNotEmpty) {
      debugPrint("Saved ID found in SharedPreferences: $savedId");
      await loadGallery(savedId);
      return true;
    }

    // 3. IDが見つからない → UIでダイアログ表示が必要
    return false;
  }

  /// 保存済み Gist ID でマスターギャラリーを再読み込み
  Future<void> reloadGallery() async {
    final savedId = await _repository.getSavedGistId();
    if (savedId == null || savedId.isEmpty) return;
    await loadGallery(savedId);
  }

  /// Gist IDでギャラリーデータをロード
  Future<void> loadGallery(String gistId) async {
    _status = GalleryStatus.loading;
    notifyListeners();

    try {
      // Web版は GitHub API (metadata) をスキップして直接 CDN fetch
      String? remoteUpdatedAt;
      if (!kIsWeb) {
        final meta = await _githubService.fetchGistMetadata(gistId);
        if (!(meta['exists'] as bool)) {
          throw Exception('Invalid Password (ID)');
        }
        remoteUpdatedAt = meta['updatedAt'] as String?;
      }

      final data = await _repository.fetchGalleryData(
        gistId,
        remoteUpdatedAt: remoteUpdatedAt,
      );
      await _repository.saveGistId(gistId);

      // MASTER_GIST_ID でロードした場合は管理者として自動認証
      if (gistId == defaultMasterGistId && defaultMasterGistId.isNotEmpty) {
        await _repository.setAdminAuthenticated(true);
      }

      _items = data.items;
      _userName = data.userName;
      _userGists = data.userGists;
      _userPriorities = data.userPriorities;
      _favoriteUsers = await _repository.loadFavoriteUsers();
      _status = GalleryStatus.authenticated;
      _errorMessage = '';
    } catch (e) {
      debugPrint("Load error: $e");
      _errorMessage = 'Network error or invalid ID';
      _status = GalleryStatus.error;
    }
    notifyListeners();
  }

  /// ユーザーの全ツイートを取得（Gist分割対応）
  Future<List<TweetItem>> fetchUserItems(String username) async {
    final gistId = _userGists[username];
    if (gistId != null) {
      return await _repository.fetchUserGist(gistId, username);
    }
    // マスターデータからフィルタ（1件のみユーザー等）
    return _items.where((item) {
      final extName = item.extractedUsername;
      return extName != null &&
          extName.toLowerCase() == username.toLowerCase();
    }).toList();
  }

  /// 管理者認証済みかどうか（Append 共通）
  Future<bool> isAdminAuthenticated() {
    return _repository.isAdminAuthenticated();
  }

  // --- Append アクション ---

  /// ユーザーをキューに追加する（ローカルクローラーが定期巡回して取得）
  Future<bool> queueUserForFetch(
    String username, {
    required int count,
    required bool stopOnExisting,
  }) async {
    return _githubService.addUserToFetchQueue(
      username,
      count: count,
      stopOnExisting: stopOnExisting,
    );
  }

  // --- 選択・削除アクション ---

  void toggleSelection(String id) {
    if (_selectedIds.contains(id)) {
      _selectedIds.remove(id);
    } else {
      _selectedIds.add(id);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedIds.clear();
    notifyListeners();
  }

  Future<bool> checkUserExistsOnX(String username) =>
      _repository.checkUserExistsOnX(username);

  // --- お気に入り Gist 保存・読込 ---

  /// お気に入りを Gist に保存する。保存済みGistがあれば更新、なければ新規作成。
  /// 成功時は Gist ID を返す。失敗時は null。
  Future<String?> saveFavoritesToGist() async {
    final content = jsonEncode({'favorite_users': _favoriteUsers.toList()});
    String? gistId = await _repository.loadFavoritesGistId();

    if (gistId != null && gistId.isNotEmpty) {
      final success = await _githubService.updateGistFile(
        gistId: gistId,
        filename: 'favorites.json',
        content: content,
      );
      return success ? gistId : null;
    } else {
      gistId = await _githubService.createGist(
        filename: 'favorites.json',
        content: content,
        description: 'PostGallery Favorites',
      );
      if (gistId != null) {
        await _repository.saveFavoritesGistId(gistId);
        return gistId;
      }
      return null;
    }
  }

  /// Gist IDを指定してお気に入りを読み込み、ローカルの SharedPreferences に上書きする
  Future<bool> loadFavoritesFromGist(String gistId) async {
    try {
      final content = await _githubService.fetchGistContent(
        gistId,
        'favorites.json',
      );
      if (content == null) return false;
      final data = jsonDecode(content) as Map<String, dynamic>;
      final users = (data['favorite_users'] as List? ?? [])
          .cast<String>()
          .toSet();
      _favoriteUsers = users;
      await _repository.saveFavoriteUsers(users);
      await _repository.saveFavoritesGistId(gistId);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('loadFavoritesFromGist error: $e');
      return false;
    }
  }

  Future<String?> loadFavoritesGistId() => _repository.loadFavoritesGistId();

  Future<void> toggleFavorite(String username) async {
    if (_favoriteUsers.contains(username)) {
      _favoriteUsers = {..._favoriteUsers}..remove(username);
    } else {
      _favoriteUsers = {..._favoriteUsers, username};
    }
    await _repository.saveFavoriteUsers(_favoriteUsers);
    notifyListeners();
  }

  /// Gistから選択中アイテムを削除する共通ヘルパー
  Future<int?> _deleteSelectedFromGist({
    required String gistId,
    required List<TweetItem> currentItems,
    required Future<String> Function() buildJson,
  }) async {
    final remainingCount = currentItems
        .where((item) => !_selectedIds.contains(item.id))
        .length;
    try {
      final jsonStr = await buildJson();
      final success = await _githubService.updateGistFile(
        gistId: gistId,
        filename: 'data.json',
        content: jsonStr,
      );
      if (success) {
        _selectedIds.clear();
        notifyListeners();
        return remainingCount;
      } else {
        _setError('Gist の更新に失敗しました');
        return null;
      }
    } catch (e) {
      debugPrint('_deleteSelectedFromGist error: $e');
      _setError('Gist の更新に失敗しました');
      return null;
    }
  }

  /// ユーザーGist（バッチ形式）から選択中アイテムを削除して更新
  Future<int?> deleteSelectedFromUserGist(
    String gistId,
    String username,
    List<TweetItem> currentItems,
  ) {
    final remainingItems = currentItems
        .where((item) => !_selectedIds.contains(item.id))
        .toList();
    return _deleteSelectedFromGist(
      gistId: gistId,
      currentItems: currentItems,
      buildJson: () => _repository.buildUserBatchGistJson(
        gistId,
        username,
        remainingItems,
        deletedIds: _selectedIds,
      ),
    );
  }

  /// ユーザーを完全に削除する（子Gistから除外 + キューから除外 + お気に入り解除 + マスターから除去）
  Future<bool> deleteUser(String username) async {
    try {
      final gistId = _userGists[username] ??
          _userGists.entries
              .firstWhere(
                (e) => e.key.toLowerCase() == username.toLowerCase(),
                orElse: () => const MapEntry('', ''),
              )
              .value;

      if (gistId.isNotEmpty) {
        try {
          // 子Gist（マルチユーザー形式）から対象ユーザーのみを安全に除外
          final updatedBatchJson = await _repository.buildUserBatchGistJson(
            gistId,
            username,
            const [], // remainingItems が空のとき users.remove(username) が実行される
          );
          await _githubService.updateGistFile(
            gistId: gistId,
            filename: 'data.json',
            content: updatedBatchJson,
          );
        } catch (e) {
          debugPrint('deleteUser child gist update error: $e');
        }
      }

      // キュー（fetch_queue.json）からも削除してクローラーによる自動復活を防止
      try {
        await _githubService.removeUserFromFetchQueue(username);
      } catch (e) {
        debugPrint('deleteUser removeUserFromFetchQueue error: $e');
      }

      // お気に入りに入っていれば解除
      if (isFavorite(username)) {
        await toggleFavorite(username);
      }

      // マスターGistから除去して保存
      final success = await removeUserFromMaster(username);
      return success;
    } catch (e) {
      debugPrint('deleteUser error: $e');
      _errorMessage = e.toString();
      return false;
    }
  }

  /// マスターGistの最新状態をGitHubに保存してキャッシュをクリアする
  Future<bool> _saveMasterGist() async {
    String masterGistId = defaultMasterGistId;
    if (masterGistId.isEmpty) {
      masterGistId = await _repository.getSavedGistId() ?? '';
    }
    if (masterGistId.isEmpty) {
      debugPrint('_saveMasterGist: masterGistId is empty, skipping update');
      _errorMessage = 'マスターGist IDが設定されていません';
      return false;
    }

    try {
      final filename = _repository.lastGistFilename ?? 'data.json';
      final jsonStr = _repository.buildMasterGistJson(
        _items,
        userName: _userName,
        userGists: _userGists,
        userPriorities: _userPriorities,
      );
      final success = await _githubService.updateGistFile(
        gistId: masterGistId,
        filename: filename,
        content: jsonStr,
      );
      if (success) {
        await _repository.clearCache();
      } else {
        _errorMessage = 'マスターGistの更新に失敗しました';
      }
      return success;
    } catch (e) {
      debugPrint('_saveMasterGist error: $e');
      _errorMessage = e.toString();
      return false;
    }
  }

  /// アカウントがピン留め（トップ固定）されているかを判定
  bool isPinned(String username) {
    return (_userPriorities[username] ?? 0) > 0;
  }

  /// ピン留めのトグル処理: ピン留め中なら解除（0にリセット）、未ピン留めなら最上位に固定
  Future<bool> togglePin(String username) async {
    final isCurrentlyPinned = isPinned(username);
    final newPriority = isCurrentlyPinned ? 0 : DateTime.now().millisecondsSinceEpoch;
    _userPriorities = Map.from(_userPriorities)..[username] = newPriority;
    notifyListeners();
    return await _saveMasterGist();
  }

  /// ピン留め（最上位移動）時: 優先順位タイムスタンプを現在時刻に更新し、マスターGistに保存して一覧を更新
  Future<bool> bumpUserPriority(String username) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _userPriorities = Map.from(_userPriorities)..[username] = now;
    notifyListeners();
    return await _saveMasterGist();
  }

  /// 新規アカウント登録時: priority_updated_at は未操作（0）としてマスターGistを更新
  Future<bool> registerUser(String username, {String gistId = ''}) async {
    _userGists = Map.from(_userGists)..[username] = gistId;
    _userPriorities = Map.from(_userPriorities)..[username] = 0;
    notifyListeners();
    return await _saveMasterGist();
  }

  /// 全ポスト削除後にマスターGistからユーザーを除去する
  Future<bool> removeUserFromMaster(String username) async {
    final lower = username.toLowerCase();
    _userGists = Map.fromEntries(
      _userGists.entries.where((e) => e.key.toLowerCase() != lower),
    );
    _userPriorities = Map.fromEntries(
      _userPriorities.entries.where((e) => e.key.toLowerCase() != lower),
    );
    _items = _items.where((item) {
      final u = item.extractedUsername?.toLowerCase();
      return u != lower;
    }).toList();
    notifyListeners();
    return await _saveMasterGist();
  }

  /// スクロール位置の保存・復元
  Future<int?> getSavedScrollIndex() => _repository.getSavedScrollIndex();
  Future<void> saveScrollIndex(int index) => _repository.saveScrollIndex(index);
}
