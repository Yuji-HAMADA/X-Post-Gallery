import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../models/tweet_item.dart';
import '../services/gallery_repository.dart';
import '../services/github_service.dart';

enum GalleryStatus { initial, loading, authenticated, error }

enum RefreshStatus { idle, running, completed, failed }

enum AppendStatus { idle, running, completed, failed }

const String _externalPwAdmin = String.fromEnvironment('PW_ADMIN');
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

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  // --- 選択状態 ---
  final Set<String> _selectedIds = {};
  Set<String> get selectedIds => _selectedIds;
  bool get isSelectionMode => _selectedIds.isNotEmpty;
  int get selectedCount => _selectedIds.length;

  static const int defaultRefreshCount = 18;

  // --- Helper ---
  bool checkAdminPassword(String password) {
    final correctPw = _externalPwAdmin.isNotEmpty
        ? _externalPwAdmin
        : (dotenv.env['PW_ADMIN'] ?? '');
    return password.isNotEmpty && password == correctPw;
  }

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

      _items = data.items;
      _userName = data.userName;
      _userGists = data.userGists;
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

  /// リフレッシュ認証を検証し、結果を保存
  /// 成功時にギャラリーもロードする
  Future<bool> authenticateRefresh({
    required String password,
    required String gistId,
  }) async {
    final correctPw = _externalPwAdmin.isNotEmpty
        ? _externalPwAdmin
        : (dotenv.env['PW_ADMIN'] ?? '');

    if (password != correctPw) {
      _errorMessage = 'パスワードが正しくありません';
      notifyListeners();
      return false;
    }

    final gistExists = await _githubService.validateGistExists(gistId);
    if (!gistExists) {
      _errorMessage = '指定されたGist IDが見つかりません';
      notifyListeners();
      return false;
    }

    await _repository.setRefreshAuthenticated(true);
    await _repository.saveGistId(gistId);
    await loadGallery(gistId);
    return true;
  }

  /// リフレッシュ認証済みかどうか
  Future<bool> isRefreshAuthenticated() {
    return _repository.isRefreshAuthenticated();
  }

  /// ワークフローをトリガーしてポーリング
  Future<void> executeRefresh(int count) async {
    final gistId = await _repository.getSavedGistId();
    if (gistId == null || gistId.isEmpty) {
      _errorMessage = 'Gist IDが設定されていません';
      notifyListeners();
      return;
    }

    _refreshStatus = RefreshStatus.running;
    notifyListeners();

    final triggered = await _githubService.triggerUpdateMygistWorkflow(
      gistId: gistId,
      count: count,
    );

    if (!triggered) {
      _errorMessage = 'ワークフローの起動に失敗しました';
      _refreshStatus = RefreshStatus.failed;
      notifyListeners();
      return;
    }

    // ポーリング
    String pollStatus = '';
    int retryCount = 0;
    while (pollStatus != 'completed' && retryCount < 120) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        pollStatus = await _githubService.getWorkflowStatus();
        debugPrint('Polling... Status: $pollStatus (Try $retryCount)');
      } catch (e) {
        pollStatus = 'error';
      }
      retryCount++;
    }

    if (pollStatus == 'completed') {
      await loadGallery(gistId);
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

  /// Append認証済みかどうか
  Future<bool> isAppendAuthenticated() {
    return _repository.isAppendAuthenticated();
  }

  /// Appendパスワードを検証して保存
  Future<bool> authenticateAppend({required String password}) async {
    final correctPw = _externalPwAdmin.isNotEmpty
        ? _externalPwAdmin
        : (dotenv.env['PW_ADMIN'] ?? '');

    if (password != correctPw) {
      _errorMessage = 'パスワードが正しくありません';
      notifyListeners();
      return false;
    }

    await _repository.setAppendAuthenticated(true);
    return true;
  }

  /// append_gist.yml をトリガーしてポーリング（user と hashtag は排他）
  /// gistIdOverride: ユーザーGistへの追記時に指定（省略時はマスターGist）
  Future<void> executeAppend({
    String? user,
    String? hashtag,
    required String mode,
    required int count,
    required bool stopOnExisting,
    String? gistIdOverride,
  }) async {
    final gistId = gistIdOverride ?? await _repository.getSavedGistId();
    if (gistId == null || gistId.isEmpty) {
      _errorMessage = 'Gist IDが設定されていません';
      notifyListeners();
      return;
    }

    _appendStatus = AppendStatus.running;
    notifyListeners();

    final triggered = await _githubService.triggerAppendGistWorkflow(
      gistId: gistId,
      user: user,
      hashtag: hashtag,
      mode: mode,
      count: count,
      stopOnExisting: stopOnExisting,
    );

    if (!triggered) {
      _errorMessage = 'ワークフローの起動に失敗しました';
      _appendStatus = AppendStatus.failed;
      notifyListeners();
      return;
    }

    // ポーリング
    String pollStatus = '';
    int retryCount = 0;
    while (pollStatus != 'completed' && retryCount < 120) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        pollStatus = await _githubService.getWorkflowStatus();
        debugPrint('Append polling... Status: $pollStatus (Try $retryCount)');
      } catch (e) {
        pollStatus = 'error';
      }
      retryCount++;
    }

    if (pollStatus == 'completed') {
      // gistIdOverride がない場合のみマスターをリロード（ユーザーGistは呼び出し側が処理）
      if (gistIdOverride == null) {
        await loadGallery(gistId);
      }
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

  /// 選択中のアイテムを削除し、Gist を更新
  Future<bool> deleteSelected() async {
    final gistId = await _repository.getSavedGistId();
    final filename = _repository.lastGistFilename;

    if (gistId == null || gistId.isEmpty || filename == null) {
      _errorMessage = 'Gist ID またはファイル名が不明です';
      notifyListeners();
      return false;
    }

    // 復元用バックアップ
    final backup = List<TweetItem>.from(_items);

    // ローカル状態を先に更新
    _items.removeWhere((item) => _selectedIds.contains(item.id));

    // Gist を更新（user_gists マッピングを保持）
    final jsonStr = _repository.buildGistJson(
      _userName,
      _items,
      userGists: _userGists,
    );
    final success = await _githubService.updateGistFile(
      gistId: gistId,
      filename: filename,
      content: jsonStr,
    );

    if (success) {
      await _repository.clearCache(); // Gist更新後はキャッシュ破棄
      _selectedIds.clear();
      notifyListeners();
      return true;
    } else {
      // 失敗時は復元
      _items = backup;
      _errorMessage = 'Gist の更新に失敗しました';
      notifyListeners();
      return false;
    }
  }

  /// ユーザーGist（バッチ形式）から選択中アイテムを削除して更新
  Future<bool> deleteSelectedFromUserGist(
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
      } else {
        _errorMessage = 'Gist の更新に失敗しました';
        notifyListeners();
      }
      return success;
    } catch (e) {
      debugPrint('deleteSelectedFromUserGist error: $e');
      _errorMessage = 'Gist の更新に失敗しました';
      notifyListeners();
      return false;
    }
  }

  /// スクロール位置の保存・復元
  Future<int?> getSavedScrollIndex() => _repository.getSavedScrollIndex();
  Future<void> saveScrollIndex(int index) => _repository.saveScrollIndex(index);
}
