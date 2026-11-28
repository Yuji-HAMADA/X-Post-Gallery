import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../l10n/app_localizations.dart';
import '../models/data_source.dart';
import '../models/tweet_item.dart';
import '../models/user_gist_entry.dart';
import '../services/gallery_repository.dart';
import '../services/github_service.dart';
import '../utils/date_helper.dart';
import '../utils/env_helper.dart';

enum GalleryStatus { initial, loading, authenticated, error }

const String _externalMasterGistId = String.fromEnvironment('MASTER_GIST_ID');
const String _externalFavoriteGistId = String.fromEnvironment(
  'FAVORITE_GIST_ID',
);
const String _externalIgMasterGistId = String.fromEnvironment(
  'IG_MASTER_GIST_ID',
);
const String _externalIgFavoriteGistId = String.fromEnvironment(
  'IG_FAVORITE_GIST_ID',
);
const String _externalTiktokMasterGistId = String.fromEnvironment(
  'TIKTOK_MASTER_GIST_ID',
);
const String _externalTiktokFavoriteGistId = String.fromEnvironment(
  'TIKTOK_FAVORITE_GIST_ID',
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
  DataSource _currentSource = DataSource.x;
  DataSource get currentSource => _currentSource;

  GalleryStatus _status = GalleryStatus.initial;
  GalleryStatus get status => _status;

  int _mainGridColumnCount = GalleryRepository.defaultGridColumnCount;
  int get mainGridColumnCount => _mainGridColumnCount;

  int _accountGridColumnCount = GalleryRepository.defaultGridColumnCount;
  int get accountGridColumnCount => _accountGridColumnCount;

  /// 既存互換ゲッター（メインギャラリー列数）
  int get gridColumnCount => _mainGridColumnCount;

  String _rowHeightMode = GalleryRepository.defaultRowHeightMode;
  String get rowHeightMode => _rowHeightMode;

  Future<void> loadMainGridColumnCount() async {
    try {
      final count = await _repository.loadMainGridColumnCount();
      if (_mainGridColumnCount != count) {
        _mainGridColumnCount = count;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setMainGridColumnCount(int count) async {
    if (_mainGridColumnCount == count) return;
    _mainGridColumnCount = count;
    notifyListeners();
    await _repository.saveMainGridColumnCount(count);
  }

  Future<void> loadAccountGridColumnCount() async {
    try {
      final count = await _repository.loadAccountGridColumnCount();
      if (_accountGridColumnCount != count) {
        _accountGridColumnCount = count;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setAccountGridColumnCount(int count) async {
    if (_accountGridColumnCount == count) return;
    _accountGridColumnCount = count;
    notifyListeners();
    await _repository.saveAccountGridColumnCount(count);
  }

  /// 既存互換メソッド
  Future<void> loadGridColumnCount() => loadMainGridColumnCount();
  Future<void> setGridColumnCount(int count) => setMainGridColumnCount(count);

  Future<void> loadRowHeightMode() async {
    try {
      final mode = await _repository.loadRowHeightMode();
      if (_rowHeightMode != mode) {
        _rowHeightMode = mode;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setRowHeightMode(String mode) async {
    if (_rowHeightMode == mode) return;
    _rowHeightMode = mode;
    notifyListeners();
    await _repository.saveRowHeightMode(mode);
  }

  List<TweetItem> _items = [];
  List<TweetItem> get items => _items;

  String _userName = '';
  String get userName => _userName;

  Map<String, String> _userGists = {};
  Map<String, String> get userGists => _userGists;

  Map<String, int> _userPriorities = {};
  Map<String, int> get userPriorities => _userPriorities;

  MapEntry<String, V>? _findEntryIgnoreCase<V>(Map<String, V> map, String key) {
    if (map.containsKey(key)) {
      return MapEntry(key, map[key] as V);
    }
    final lower = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry;
      }
    }
    return null;
  }

  Map<String, UserGistEntry> _userGistEntries = {};
  Map<String, UserGistEntry> get userGistEntries => _userGistEntries;
  bool isCandidate(String username) =>
      _findEntryIgnoreCase(_userGistEntries, username)?.value.isCandidate ??
      false;

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

  /// [JA] 同一セッション内で更新した子Gist ID（CDNキャッシュの巻き戻りを防ぐためAPI経由で最新を取得）
  final Set<String> _recentlyModifiedChildGists = {};

  // --- Helper ---
  String get defaultMasterGistId {
    switch (_currentSource) {
      case DataSource.x:
        return resolveEnv(_externalMasterGistId, 'MASTER_GIST_ID');
      case DataSource.instagram:
        return resolveEnv(_externalIgMasterGistId, 'IG_MASTER_GIST_ID');
      case DataSource.tiktok:
        return resolveEnv(_externalTiktokMasterGistId, 'TIKTOK_MASTER_GIST_ID');
    }
  }

  String get favoriteGistId {
    switch (_currentSource) {
      case DataSource.x:
        return resolveEnv(_externalFavoriteGistId, 'FAVORITE_GIST_ID');
      case DataSource.instagram:
        return resolveEnv(_externalIgFavoriteGistId, 'IG_FAVORITE_GIST_ID');
      case DataSource.tiktok:
        return resolveEnv(
          _externalTiktokFavoriteGistId,
          'TIKTOK_FAVORITE_GIST_ID',
        );
    }
  }

  void _applySource(DataSource source) {
    _currentSource = source;
    _repository.setSource(source);
    _githubService.setSource(source);
  }

  /// [JA] データ取得元（X / Instagram）を完全に独立した状態で切り替える
  /// 切替先の Gist ID が存在しロード完了した場合は true、未設定で入力ダイアログが必要な場合は false を返す
  Future<bool> switchSource(DataSource newSource) async {
    if (_currentSource == newSource && _status == GalleryStatus.authenticated) {
      return true;
    }

    _applySource(newSource);
    await _repository.saveSelectedDataSource(newSource);

    // 切替前のプラットフォーム状態をメモリ上から完全にクリア
    _items = [];
    _userName = '';
    _userGists = {};
    _userPriorities = {};
    _userGistEntries = {};
    _favoriteUsers = {};
    _selectedIds.clear();
    _recentlyModifiedChildGists.clear();
    _errorMessage = '';

    final savedId = await _repository.getSavedGistId();
    final targetId = (savedId != null && savedId.isNotEmpty)
        ? savedId
        : defaultMasterGistId;

    if (targetId.isNotEmpty) {
      await loadGallery(targetId);
      return true;
    }

    _status = GalleryStatus.initial;
    notifyListeners();
    return false;
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  // --- アクション ---

  /// 初期ロード：URLパラメータ → SharedPreferences → null（ダイアログ必要）
  Future<bool> handleInitialLoad() async {
    await loadMainGridColumnCount();
    await loadAccountGridColumnCount();
    await loadRowHeightMode();

    // 0. 取得元プラットフォームの復元（URLパラメータ ?source=instagram 優先）
    final urlSource = Uri.base.queryParameters['source'];
    final initialSource = (urlSource != null && urlSource.isNotEmpty)
        ? DataSourceX.fromKey(urlSource)
        : await _repository.loadSelectedDataSource();
    _applySource(initialSource);

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

  /// 保存済み Gist ID でマスターギャラリーを再読み込み（キャッシュを強制破棄して最新取得）
  Future<void> reloadGallery() async {
    final savedId = await _repository.getSavedGistId();
    if (savedId == null || savedId.isEmpty) return;
    await _repository.clearCache();
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
          throw Exception(AppLocalizations.current.invalidGistIdError);
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
      _userGistEntries = data.userGistEntries;
      await _repository.saveUserPriorities(_userPriorities);
      _favoriteUsers = await _repository.loadFavoriteUsers();
      _status = GalleryStatus.authenticated;
      _errorMessage = '';

      // 現在お気に入りになっているアカウントの candidate 属性を解除し、必要なら GIST を更新
      await cleanupCandidateFlagsForFavorites();
      if (_status == GalleryStatus.authenticated && _errorMessage.isNotEmpty) {
        _errorMessage = '';
      }
    } catch (e) {
      debugPrint("Load error: $e");
      _errorMessage = AppLocalizations.current.networkOrInvalidIdError;
      _status = GalleryStatus.error;
    }
    notifyListeners();
  }

  /// 大文字小文字を問わずユーザーのGist IDを取得
  String? getGistIdForUser(String username) {
    final id = _findEntryIgnoreCase(_userGists, username)?.value;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  /// 大文字小文字を問わず登録されている正準アカウント名を取得
  String? getCanonicalUsername(String username) =>
      _findEntryIgnoreCase(_userGists, username)?.key;

  /// GitHub API 経由で子Gistの最新JSONを取得（CDNキャッシュ回避用、失敗時は null でフォールバック）
  Future<String?> _fetchFreshChildGistContent(String gistId) async {
    if (gistId.isEmpty || _githubService.token.isEmpty) return null;
    try {
      return await _githubService.fetchGistContent(gistId, 'data.json');
    } catch (e) {
      debugPrint('_fetchFreshChildGistContent fallback ($gistId): $e');
      return null;
    }
  }

  /// ユーザーの全ツイートを取得（Gist分割対応、大文字小文字不問、新しい順ソート）
  Future<List<TweetItem>> fetchUserItems(String username) async {
    final gistId = getGistIdForUser(username);
    final canonicalName = getCanonicalUsername(username) ?? username;
    List<TweetItem> items;
    if (gistId != null) {
      final freshJson = _recentlyModifiedChildGists.contains(gistId)
          ? await _fetchFreshChildGistContent(gistId)
          : null;
      if (freshJson != null && freshJson.isNotEmpty) {
        items = _repository.parseUserGistJson(freshJson, canonicalName);
      } else {
        items = await _repository.fetchUserGist(gistId, canonicalName);
      }
    } else {
      // マスターデータからフィルタ（1件のみユーザー等）
      items = _items.where((item) {
        final extName = item.extractedUsername;
        return extName != null &&
            extName.toLowerCase() == username.toLowerCase();
      }).toList();
    }
    items.sort(compareTweetsByNewest);
    return items;
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
    bool fromScratch = false,
  }) async {
    return _githubService.addUserToFetchQueue(
      username,
      count: count,
      stopOnExisting: stopOnExisting,
      fromScratch: fromScratch,
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
      if (success) {
        _errorMessage = '';
        return gistId;
      }
    } else {
      gistId = await _githubService.createGist(
        filename: 'favorites.json',
        content: content,
        description: 'PostGallery Favorites',
      );
      if (gistId != null) {
        await _repository.saveFavoritesGistId(gistId);
        _errorMessage = '';
        return gistId;
      }
    }

    _errorMessage = _githubService.lastErrorMessage.isNotEmpty
        ? _githubService.lastErrorMessage
        : AppLocalizations.current.saveFailed;
    return null;
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
      await cleanupCandidateFlagsForFavorites();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('loadFavoritesFromGist error: $e');
      return false;
    }
  }

  Future<String?> loadFavoritesGistId() => _repository.loadFavoritesGistId();

  /// [JA] 現在お気に入り登録されているアカウントの candidate 属性を解除し、必要ならマスターGistを更新する
  /// [EN] Removes candidate flag from all currently favorited users and persists to master Gist
  Future<bool> cleanupCandidateFlagsForFavorites() async {
    if (_favoriteUsers.isEmpty || _userGistEntries.isEmpty) {
      return false;
    }

    final lowerFavs = _favoriteUsers.map((u) => u.toLowerCase()).toSet();
    bool modified = false;
    final updatedEntries = Map<String, UserGistEntry>.from(_userGistEntries);

    for (final entry in _userGistEntries.entries) {
      if (entry.value.isCandidate && lowerFavs.contains(entry.key.toLowerCase())) {
        updatedEntries[entry.key] = entry.value.copyWith(isCandidate: false);
        modified = true;
      }
    }

    if (modified) {
      _userGistEntries = updatedEntries;
      try {
        return await _saveMasterGist();
      } catch (e) {
        debugPrint('cleanupCandidateFlagsForFavorites save error: $e');
        return false;
      }
    }
    return false;
  }

  Future<void> toggleFavorite(String username) async {
    final isAdding = !_favoriteUsers.contains(username);
    if (!isAdding) {
      _favoriteUsers = {..._favoriteUsers}..remove(username);
    } else {
      _favoriteUsers = {..._favoriteUsers, username};
    }
    await _repository.saveFavoriteUsers(_favoriteUsers);

    // Candidateからお気に入りに移動した場合はcandidate属性を永続的に外してマスターGistを更新
    if (isAdding && isCandidate(username)) {
      final lower = username.toLowerCase();
      final updatedEntries = Map<String, UserGistEntry>.from(_userGistEntries);
      final updatedUserGists = Map<String, String>.from(_userGists);
      bool found = false;

      for (final entry in _userGistEntries.entries) {
        if (entry.key.toLowerCase() == lower) {
          updatedEntries[entry.key] = entry.value.copyWith(isCandidate: false);
          found = true;
        }
      }

      if (!found) {
        final canonical = getCanonicalUsername(username) ?? username;
        updatedEntries[canonical] = UserGistEntry(
          gistId: _userGists[canonical] ?? '',
          priorityUpdatedAt: _userPriorities[canonical] ?? 0,
          isCandidate: false,
        );
        if (!updatedUserGists.containsKey(canonical)) {
          updatedUserGists[canonical] = '';
        }
      }

      _userGistEntries = updatedEntries;
      _userGists = updatedUserGists;

      try {
        await _saveMasterGist();
      } catch (e) {
        debugPrint('toggleFavorite save master gist error: $e');
      }
    }

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
        _setError(_githubService.lastErrorMessage.isNotEmpty
            ? _githubService.lastErrorMessage
            : AppLocalizations.current.gistUpdateFailed(null));
        return null;
      }
    } catch (e) {
      debugPrint('_deleteSelectedFromGist error: $e');
      _setError(AppLocalizations.current.gistUpdateFailed(e.toString()));
      return null;
    }
  }

  /// ユーザーGist（バッチ形式）から選択中アイテムを削除して更新
  /// 代表サムネイル（1枚目等）が削除された場合は Master Gist の代表アイテムも最新へ同期する
  Future<int?> deleteSelectedFromUserGist(
    String gistId,
    String username,
    List<TweetItem> currentItems,
  ) async {
    final deletedIds = Set<String>.from(_selectedIds);
    final remainingItems = currentItems
        .where((item) => !deletedIds.contains(item.id))
        .toList()
      ..sort(compareTweetsByNewest);

    final remainingCount = await _deleteSelectedFromGist(
      gistId: gistId,
      currentItems: currentItems,
      buildJson: () async {
        final freshJson = await _fetchFreshChildGistContent(gistId);
        if (freshJson != null && freshJson.isNotEmpty) {
          return _repository.buildUserBatchGistJsonFromRaw(
            freshJson,
            username,
            remainingItems,
            deletedIds: deletedIds,
          );
        }
        return _repository.buildUserBatchGistJson(
          gistId,
          username,
          remainingItems,
          deletedIds: deletedIds,
        );
      },
    );

    if (remainingCount != null) {
      _recentlyModifiedChildGists.add(gistId);

      // Master Gist の代表サムネイルが削除対象に含まれていた場合、残存する最新アイテムへ差し替え
      if (remainingItems.isNotEmpty) {
        final lower = username.toLowerCase();
        final masterNeedsSync = _items.any(
          (item) =>
              item.extractedUsername?.toLowerCase() == lower &&
              deletedIds.contains(item.id),
        );
        if (masterNeedsSync) {
          final canonical = getCanonicalUsername(username) ?? username;
          final nextThumb = remainingItems
              .firstWhere(
                (i) => i.thumbnailUrl.isNotEmpty,
                orElse: () => remainingItems.first,
              )
              .copyWith(username: canonical);
          _items = _items
              .where((item) => item.extractedUsername?.toLowerCase() != lower)
              .toList()
            ..insert(0, nextThumb);
          notifyListeners();
          await _saveMasterGist();
        }
      }
    }

    return remainingCount;
  }

  /// ユーザーを完全に削除する（子Gistから除外 + キューから除外 + お気に入り解除 + マスターから除去）
  Future<bool> deleteUser(String username) async {
    try {
      final gistId = getGistIdForUser(username) ?? '';

      if (gistId.isNotEmpty) {
        try {
          final freshJson = await _fetchFreshChildGistContent(gistId);
          // 子Gist（マルチユーザー形式）から対象ユーザーのみを安全に除外
          final updatedBatchJson = (freshJson != null && freshJson.isNotEmpty)
              ? _repository.buildUserBatchGistJsonFromRaw(
                  freshJson,
                  username,
                  const [],
                )
              : await _repository.buildUserBatchGistJson(
                  gistId,
                  username,
                  const [], // remainingItems が空のとき users.remove(username) が実行される
                );
          final updated = await _githubService.updateGistFile(
            gistId: gistId,
            filename: 'data.json',
            content: updatedBatchJson,
          );
          if (updated) {
            _recentlyModifiedChildGists.add(gistId);
          }
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
      _errorMessage = AppLocalizations.current.masterGistIdNotSet;
      return false;
    }

    try {
      final filename = _repository.lastGistFilename ?? 'data.json';
      final jsonStr = _repository.buildMasterGistJson(
        _items,
        userName: _userName,
        userGists: _userGists,
        userPriorities: _userPriorities,
        userGistEntries: _userGistEntries,
      );
      final success = await _githubService.updateGistFile(
        gistId: masterGistId,
        filename: filename,
        content: jsonStr,
      );
      if (success) {
        await _repository.clearCache();
      } else {
        _errorMessage = _githubService.lastErrorMessage.isNotEmpty
            ? _githubService.lastErrorMessage
            : AppLocalizations.current.masterGistUpdateFailed(null);
      }
      return success;
    } catch (e) {
      debugPrint('_saveMasterGist error: $e');
      _errorMessage = e.toString();
      return false;
    }
  }

  /// [JA] アカウントがピン留め（トップ固定）されているかを判定
  /// [EN] Checks whether the account is pinned to the top
  bool isPinned(String username) =>
      (_findEntryIgnoreCase(_userPriorities, username)?.value ?? 0) > 0;

  /// [JA] ユーザーの優先順位タイムスタンプを更新してマスターGistへ反映する共通処理
  /// [EN] Shared helper to update a user's priority timestamp and persist to master Gist
  Future<bool> _setUserPriority(String username, int newPriority) async {
    final canonical = getCanonicalUsername(username) ?? username;
    final lower = canonical.toLowerCase();
    _userPriorities = Map<String, int>.fromEntries(
      _userPriorities.entries.where((e) => e.key.toLowerCase() != lower),
    )..[canonical] = newPriority;

    final currentEntry = _userGistEntries[canonical];
    _userGistEntries = Map<String, UserGistEntry>.fromEntries(
      _userGistEntries.entries.where((e) => e.key.toLowerCase() != lower),
    )..[canonical] =
        (currentEntry ?? UserGistEntry(gistId: _userGists[canonical] ?? ''))
            .copyWith(priorityUpdatedAt: newPriority);

    await _repository.saveUserPriorities(_userPriorities);
    notifyListeners();
    return await _saveMasterGist();
  }

  /// [JA] ピン留めのトグル処理: ピン留め中なら解除（0にリセット）、未ピン留めなら最上位に固定
  /// [EN] Toggles pin state: resets to 0 if already pinned, or updates timestamp to now if unpinned
  Future<bool> togglePin(String username) async {
    final canonical = getCanonicalUsername(username) ?? username;
    final newPriority =
        isPinned(canonical) ? 0 : DateTime.now().millisecondsSinceEpoch;
    return _setUserPriority(canonical, newPriority);
  }

  /// [JA] ピン留め（最上位移動）時: 優先順位タイムスタンプを現在時刻に更新し、マスターGistに保存して一覧を更新
  /// [EN] Bumps user priority to now, saves to master Gist, and updates the list
  Future<bool> bumpUserPriority(String username) =>
      _setUserPriority(username, DateTime.now().millisecondsSinceEpoch);

  /// [JA] 新規アカウント登録時: priority_updated_at は未操作（0）としてマスターGistを更新
  /// [EN] Registers a new user with priority_updated_at defaulting to 0 (unpinned)
  Future<bool> registerUser(
    String username, {
    String gistId = '',
    bool isCandidate = false,
  }) async {
    _userGists = Map.from(_userGists)..[username] = gistId;
    _userPriorities = Map.from(_userPriorities)..[username] = 0;
    _userGistEntries = Map.from(_userGistEntries)..[username] = UserGistEntry(
      gistId: gistId,
      priorityUpdatedAt: 0,
      isCandidate: isCandidate,
    );
    await _repository.saveUserPriorities(_userPriorities);
    notifyListeners();
    return await _saveMasterGist();
  }

  /// [JA] 全ポスト削除後にマスターGistからユーザーを除去する
  /// [EN] Completely removes a user and their items from master Gist after all posts are deleted
  Future<bool> removeUserFromMaster(String username) async {
    final lower = username.toLowerCase();
    _userGists = Map.fromEntries(
      _userGists.entries.where((e) => e.key.toLowerCase() != lower),
    );
    _userPriorities = Map.fromEntries(
      _userPriorities.entries.where((e) => e.key.toLowerCase() != lower),
    );
    _userGistEntries = Map.fromEntries(
      _userGistEntries.entries.where((e) => e.key.toLowerCase() != lower),
    );
    _items = _items.where((item) {
      final u = item.extractedUsername?.toLowerCase();
      return u != lower;
    }).toList();
    await _repository.saveUserPriorities(_userPriorities);
    notifyListeners();
    return await _saveMasterGist();
  }

  /// [JA] スクロール位置の保存・復元
  /// [EN] Saves and restores scroll index position
  Future<int?> getSavedScrollIndex() => _repository.getSavedScrollIndex();
  Future<void> saveScrollIndex(int index) => _repository.saveScrollIndex(index);
}
