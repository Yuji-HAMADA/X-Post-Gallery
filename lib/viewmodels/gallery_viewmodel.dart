import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/tweet_item.dart';
import '../services/gallery_repository.dart';
import '../services/github_service.dart';

enum GalleryStatus { initial, loading, authenticated, error }

enum RefreshStatus { idle, running, completed, failed }

enum AppendStatus { idle, running, completed, failed }

const String _externalMasterGistId = String.fromEnvironment('MASTER_GIST_ID');

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

  RefreshStatus _refreshStatus = RefreshStatus.idle;
  RefreshStatus get refreshStatus => _refreshStatus;

  AppendStatus _appendStatus = AppendStatus.idle;
  AppendStatus get appendStatus => _appendStatus;

  List<TweetItem> _items = [];
  List<TweetItem> get items => _items;

  String _userName = '';
  String get userName => _userName;

  Map<String, String> _userGists = {};
  Map<String, String> get userGists => _userGists;

  Map<String, String> _characterGists = {};
  Map<String, String> get characterGists => _characterGists;

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

  static const int defaultRefreshCount = 18;

  // --- Helper ---
  String get defaultMasterGistId {
    return _externalMasterGistId.isNotEmpty
        ? _externalMasterGistId
        : (dotenv.env['MASTER_GIST_ID'] ?? '');
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
      _characterGists = data.characterGists;
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
    final pattern = RegExp(r'^@([^:]+):');
    return _items.where((item) {
      final m = pattern.firstMatch(item.fullText);
      return m != null &&
          m.group(1)?.trim().toLowerCase() == username.toLowerCase();
    }).toList();
  }

  /// キャラクターGistからポストを取得
  Future<List<TweetItem>> fetchCharacterItems(String charName) async {
    final gistId = _characterGists[charName];
    if (gistId == null) return [];
    return await _repository.fetchUserGist(gistId, charName);
  }

  /// マスターギャラリーをリフレッシュ（認証済み前提）
  Future<bool> refreshMasterGallery() async {
    final gistId = defaultMasterGistId;
    if (gistId.isEmpty) {
      _errorMessage = 'マスターGist IDが設定されていません';
      notifyListeners();
      return false;
    }

    final gistExists = await _githubService.validateGistExists(gistId);
    if (!gistExists) {
      _errorMessage = '指定されたGist IDが見つかりません';
      notifyListeners();
      return false;
    }

    await _repository.saveGistId(gistId);
    await loadGallery(gistId);
    return true;
  }

  /// 管理者認証済みかどうか（Refresh / Append 共通）
  Future<bool> isAdminAuthenticated() {
    return _repository.isAdminAuthenticated();
  }

  /// ワークフロー完了をポーリング（10秒間隔、最大120回 = 20分）
  /// [workflowFile]: 'append_gist.yml' など
  /// [dispatchedAt]: ディスパッチ直前の時刻。それ以降のランのみを対象にする
  Future<bool> _pollWorkflowCompletion(
    String workflowFile,
    DateTime dispatchedAt,
  ) async {
    // ディスパッチ時刻より少し前まで許容（時計ズレ対策: 30秒）
    final cutoff = dispatchedAt.subtract(const Duration(seconds: 30));
    int retryCount = 0;

    while (retryCount < 120) {
      await Future.delayed(const Duration(seconds: 10));
      try {
        final info = await _githubService.getWorkflowRunInfo(workflowFile);
        final status = info['status'] ?? '';
        final conclusion = info['conclusion'] ?? '';
        final createdAt = DateTime.tryParse(info['createdAt'] ?? '');

        debugPrint(
          '$workflowFile polling... status=$status conclusion=$conclusion '
          'createdAt=$createdAt (Try $retryCount)',
        );

        // ディスパッチ前の古いランは無視
        if (createdAt == null || createdAt.isBefore(cutoff)) {
          debugPrint('  → 古いランを無視、新しいランを待機中');
          retryCount++;
          continue;
        }

        if (status == 'completed') {
          return conclusion == 'success';
        }
      } catch (e) {
        debugPrint('$workflowFile poll error: $e');
      }
      retryCount++;
    }
    return false;
  }

  /// ワークフローをトリガーしてポーリング
  Future<void> executeRefresh(int count) async {
    final masterGistId = defaultMasterGistId;
    if (masterGistId.isEmpty) {
      _errorMessage = 'マスターGist ID (MASTER_GIST_ID) が設定されていません';
      notifyListeners();
      return;
    }

    _refreshStatus = RefreshStatus.running;
    notifyListeners();

    final dispatchedAt = DateTime.now().toUtc();
    final triggered = await _githubService.triggerUpdateMygistWorkflow(
      gistId: masterGistId,
      count: count,
    );

    if (!triggered) {
      _errorMessage = 'ワークフローの起動に失敗しました';
      _refreshStatus = RefreshStatus.failed;
      notifyListeners();
      return;
    }

    final completed = await _pollWorkflowCompletion(
      'update_mygist.yml',
      dispatchedAt,
    );
    if (completed) {
      final currentGistId = await _repository.getSavedGistId();
      if (currentGistId != null && currentGistId == masterGistId) {
        await loadGallery(currentGistId);
      }
      _refreshStatus = RefreshStatus.completed;
    } else {
      _errorMessage = '更新がタイムアウトまたは失敗しました';
      _refreshStatus = RefreshStatus.failed;
    }
    notifyListeners();
  }

  /// RefreshStatusをリセット（SnackBar表示後など）
  void clearRefreshStatus() {
    _refreshStatus = RefreshStatus.idle;
    _errorMessage = '';
  }

  // --- Append アクション ---

  /// append_gist.yml をトリガーしてポーリング（user と hashtag は排他）
  /// isUserGist: true の場合はマスターリロードをスキップ（呼び出し側が処理）
  Future<void> executeAppend({
    String? user,
    String? hashtag,
    required int count,
    required bool stopOnExisting,
    bool isUserGist = false,
  }) async {
    final targetGistId = defaultMasterGistId;
    if (targetGistId.isEmpty) {
      _errorMessage = 'マスターGist ID (MASTER_GIST_ID) が設定されていません';
      notifyListeners();
      return;
    }

    _appendStatus = AppendStatus.running;
    notifyListeners();

    final dispatchedAt = DateTime.now().toUtc();
    final triggered = await _githubService.triggerAppendGistWorkflow(
      gistId: targetGistId,
      user: user,
      hashtag: hashtag,
      count: count,
      stopOnExisting: stopOnExisting,
    );

    if (!triggered) {
      _errorMessage = 'ワークフローの起動に失敗しました';
      _appendStatus = AppendStatus.failed;
      notifyListeners();
      return;
    }

    final completed = await _pollWorkflowCompletion(
      'append_gist.yml',
      dispatchedAt,
    );
    if (completed) {
      // isUserGist の場合でもリロード: 1000件超過時に新Gistが作成され
      // マスターGistの user_gists マッピングが更新されるため、常に再取得が必要
      await loadGallery(targetGistId);
      _appendStatus = AppendStatus.completed;
    } else {
      _errorMessage = '追加がタイムアウトまたは失敗しました';
      _appendStatus = AppendStatus.failed;
    }
    notifyListeners();
  }

  /// AppendStatusをリセット
  void clearAppendStatus() {
    _appendStatus = AppendStatus.idle;
    _errorMessage = '';
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

  /// ユーザーGist（バッチ形式）から選択中アイテムを削除して更新
  /// 成功時は残件数を返す（失敗時は null）
  Future<int?> deleteSelectedFromUserGist(
    String gistId,
    String username,
    List<TweetItem> currentItems,
  ) async {
    final remainingItems = currentItems
        .where((item) => !_selectedIds.contains(item.id))
        .toList();
    try {
      final jsonStr = await _repository.buildUserBatchGistJson(
        gistId,
        username,
        remainingItems,
      );
      final success = await _githubService.updateGistFile(
        gistId: gistId,
        filename: 'data.json',
        content: jsonStr,
      );
      if (success) {
        _selectedIds.clear();
        notifyListeners();
        return remainingItems.length;
      } else {
        _errorMessage = 'Gist の更新に失敗しました';
        notifyListeners();
        return null;
      }
    } catch (e) {
      debugPrint('deleteSelectedFromUserGist error: $e');
      _errorMessage = 'Gist の更新に失敗しました';
      notifyListeners();
      return null;
    }
  }

  /// 全ポスト削除後にマスターGistからユーザーを除去する
  Future<void> removeUserFromMaster(String username) async {
    final masterGistId = defaultMasterGistId;
    if (masterGistId.isEmpty) return;

    _userGists = Map.from(_userGists)..remove(username);
    _items = _items.where((item) {
      final key =
          item.username ??
          RegExp(r'^@([^:]+):').firstMatch(item.fullText)?.group(1)?.trim();
      return key != username;
    }).toList();

    final filename = _repository.lastGistFilename ?? 'data.json';
    final jsonStr = _repository.buildGistJson(
      _userName,
      _items,
      userGists: _userGists,
      characterGists: _characterGists,
    );
    await _githubService.updateGistFile(
      gistId: masterGistId,
      filename: filename,
      content: jsonStr,
    );
    await _repository.clearCache();
    notifyListeners();
  }

  /// スクロール位置の保存・復元
  Future<int?> getSavedScrollIndex() => _repository.getSavedScrollIndex();
  Future<void> saveScrollIndex(int index) => _repository.saveScrollIndex(index);
}
