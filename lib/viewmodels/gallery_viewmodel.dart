import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/tweet_item.dart';
import '../services/gallery_repository.dart';
import '../services/github_service.dart';
import '../utils/env_helper.dart';

enum GalleryStatus { initial, loading, authenticated, error }

enum AppendStatus { idle, running, completed, failed }

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

  AppendStatus _appendStatus = AppendStatus.idle;
  AppendStatus get appendStatus => _appendStatus;

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

  /// append_gist.yml をトリガーしてポーリング
  /// isUserGist: true の場合はマスターリロードをスキップ（呼び出し側が処理）
  Future<void> executeAppend({
    required String user,
    required int count,
    required bool stopOnExisting,
    bool isUserGist = false,
  }) async {
    final targetGistId = defaultMasterGistId;
    if (targetGistId.isEmpty) {
      _setError('マスターGist ID (MASTER_GIST_ID) が設定されていません');
      return;
    }

    _appendStatus = AppendStatus.running;
    notifyListeners();

    final dispatchedAt = DateTime.now().toUtc();
    final triggered = await _githubService.triggerAppendGistWorkflow(
      gistId: targetGistId,
      user: user,
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

  /// ユーザーを完全に削除する（子Gistクリア + マスターから除去）
  Future<bool> deleteUser(String username) async {
    try {
      final gistId = _userGists[username];
      if (gistId != null) {
        // 子Gistを空にする（deleted_idsは破棄）
        final emptyJson = jsonEncode({'users': {}});
        await _githubService.updateGistFile(
          gistId: gistId,
          filename: 'data.json',
          content: emptyJson,
        );
      }
      await removeUserFromMaster(username);
      return true;
    } catch (e) {
      debugPrint('deleteUser error: $e');
      return false;
    }
  }

  /// マスターGistの最新状態をGitHubに保存してキャッシュをクリアする
  Future<bool> _saveMasterGist() async {
    final masterGistId = defaultMasterGistId;
    if (masterGistId.isEmpty) {
      debugPrint('_saveMasterGist: defaultMasterGistId is empty, skipping update');
      return true;
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
      }
      return success;
    } catch (e) {
      debugPrint('_saveMasterGist error: $e');
      return false;
    }
  }

  /// ピン留め（最上位移動）時: 優先順位タイムスタンプを現在時刻に更新し、マスターGistに保存して一覧を更新
  Future<bool> bumpUserPriority(String username) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _userPriorities = Map.from(_userPriorities)..[username] = now;
    notifyListeners();
    return await _saveMasterGist();
  }

  /// 新規アカウント登録時: priority_updated_at に現在時刻を設定しマスターGistを更新
  Future<bool> registerUser(String username, {String gistId = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _userGists = Map.from(_userGists)..[username] = gistId;
    _userPriorities = Map.from(_userPriorities)..[username] = now;
    notifyListeners();
    return await _saveMasterGist();
  }

  /// 全ポスト削除後にマスターGistからユーザーを除去する
  Future<void> removeUserFromMaster(String username) async {
    _userGists = Map.from(_userGists)..remove(username);
    _userPriorities = Map.from(_userPriorities)..remove(username);
    _items = _items.where((item) => item.extractedUsername != username).toList();
    notifyListeners();
    await _saveMasterGist();
  }

  /// スクロール位置の保存・復元
  Future<int?> getSavedScrollIndex() => _repository.getSavedScrollIndex();
  Future<void> saveScrollIndex(int index) => _repository.saveScrollIndex(index);
}
