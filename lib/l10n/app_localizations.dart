import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// [JA] アプリ内多言語化文字列を提供するローカライゼーションクラス
/// [EN] Localization class providing multi-language strings for the application
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static const List<Locale> supportedLocales = [
    Locale('ja'),
    Locale('en'),
  ];

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// [JA] BuildContext から AppLocalizations のインスタンスを取得（未設定時はデフォルト英語フォールバック）
  /// [EN] Obtains the AppLocalizations instance from BuildContext (falls back to English if null)
  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizations(const Locale('en'));
  }

  bool get isJapanese => locale.languageCode == 'ja';

  // --- Common Actions & Buttons [JA: 共通アクション・ボタン / EN: Common Actions & Buttons] ---

  String get ok => isJapanese ? 'OK' : 'OK';
  String get cancel => isJapanese ? 'キャンセル' : 'Cancel';
  String get delete => isJapanese ? '削除' : 'Delete';
  String get execute => isJapanese ? '実行' : 'Execute';
  String get reload => isJapanese ? '再読み込み' : 'Reload';
  String get add => isJapanese ? '追加' : 'Add';
  String get back => isJapanese ? '戻る' : 'Back';
  String get show => isJapanese ? '表示' : 'Show';

  // --- Tooltips [JA: ツールチップ / EN: Tooltips] ---

  String get tooltipSwitchToHorizontal =>
      isJapanese ? '横方向レイアウトに切り替え' : 'Switch to horizontal layout';
  String get tooltipToggleGap =>
      isJapanese ? '画像の隙間を切り替え' : 'Toggle image gap';
  String get tooltipPinToTop => isJapanese ? '一番上に移動' : 'Pin to top';
  String get tooltipUnpin => isJapanese ? 'ピン留めを解除' : 'Unpin from top';
  String get tooltipSaveToGist => isJapanese ? 'Gistに保存' : 'Save to Gist';
  String get tooltipLoadFromGist => isJapanese ? 'Gistから読込' : 'Load from Gist';
  String get tooltipDeleteUser => isJapanese ? 'ユーザーを削除' : 'Delete user';
  String get tooltipOpenOriginalPost =>
      isJapanese ? '元の投稿を開く' : 'Open original post';

  // --- Gallery & Navigation [JA: ギャラリー・ナビゲーション / EN: Gallery & Navigation] ---

  String get tabFavorites => isJapanese ? 'お気に入り' : 'Favorites';
  String get tabUsers => isJapanese ? 'ユーザー' : 'Users';
  String get randomSelection => isJapanese ? 'ランダム選択' : 'Random selection';
  String get userSearch => isJapanese ? 'ユーザー検索' : 'User Search';
  String get noFavoritesYet =>
      isJapanese ? 'お気に入りはまだありません\nユーザーカードのハートをタップして追加' : 'No favorites yet\nTap the heart icon on a user card to add';
  String get noPostsFound =>
      isJapanese ? 'ポストが見つかりませんでした' : 'No posts found';
  String get noFavoriteUsersRegistered =>
      isJapanese ? 'お気に入りユーザーが登録されていません' : 'No favorite users registered';
  String get userNotFound => isJapanese ? 'ユーザーが見つかりません' : 'User not found';

  String selectedCount(int count) =>
      isJapanese ? '$count 件選択中' : '$count selected';
  String deletedCount(int count) =>
      isJapanese ? '$count 件を削除しました' : '$count item(s) deleted';

  // --- Toast Notifications & SnackBars [JA: 通知・スナックバー / EN: Toast Notifications & SnackBars] ---

  String pinnedToTop(String username) =>
      isJapanese ? '@$username を一番上に移動しました' : 'Pinned @$username to top';
  String unpinnedFromTop(String username) =>
      isJapanese ? '@$username のピン留めを解除しました' : 'Unpinned @$username';
  String addedToQueue(String username) =>
      isJapanese ? 'キューに追加しました: @$username' : 'Added to fetch queue: @$username';
  String get failedToAddToQueue =>
      isJapanese ? 'キューへの追加に失敗しました' : 'Failed to add to queue';
  String deletedUserSuccess(String username) =>
      isJapanese ? '@$username を削除しました' : 'Deleted user @$username';
  String deleteFailed(String error) =>
      isJapanese ? '削除失敗: $error' : 'Failed to delete: $error';
  String userNotFoundOnX(String username) =>
      isJapanese ? 'ユーザー @$username は見つかりませんでした' : 'User @$username was not found on X';

  // --- Dialogs [JA: ダイアログ / EN: Dialogs] ---

  String get deleteConfirmTitle =>
      isJapanese ? '削除確認' : 'Confirm Delete';
  String deleteImagesConfirmMessage(int count) =>
      isJapanese ? '$count 件の画像を削除しますか？' : 'Delete $count image(s)?';
  String get deleteUserTitle =>
      isJapanese ? 'ユーザー削除' : 'Delete User';
  String deleteUserConfirmMessage(String username) => isJapanese
      ? 'ユーザー @$username と、そのすべてのポストをマスターGistおよびローカルキャッシュから完全に削除しますか？\n(Gist自体の削除ではなく、インデックスからの除外です)'
      : 'Permanently remove @$username and all posts from Master Gist and local cache?\n(Removes from gallery index; does not delete the Gist itself)';

  String get inputUserIdTitle =>
      isJapanese ? 'User IDを入力' : 'Enter User ID';
  String get inputUserIdHint =>
      isJapanese ? 'User IDを入力してください' : 'Please enter User ID';

  String get appendConfigTitle =>
      isJapanese ? '追加設定' : 'Fetch Settings';
  String get fetchCountLabel =>
      isJapanese ? '取得件数' : 'Fetch Count';
  String get stopOnExistingLabel =>
      isJapanese ? 'ストップオン' : 'Stop on Existing';
  String get skipExistingLabel =>
      isJapanese ? 'スキップ' : 'Skip Existing';
  String get fromScratchLabel =>
      isJapanese ? '初めから' : 'From Scratch';

  // --- Gist & Auth [JA: Gist・認証関連 / EN: Gist & Authentication] ---

  String get pleaseLoginWithMasterGist =>
      isJapanese ? 'マスターGist IDでログインしてください' : 'Please log in with Master Gist ID';
  String get savingToGist =>
      isJapanese ? 'Gistに保存中...' : 'Saving to Gist...';
  String get saveCompleted =>
      isJapanese ? '保存完了' : 'Save Completed';
  String get saveFailed =>
      isJapanese ? 'Gistへの保存に失敗しました' : 'Failed to save to Gist';
  String get loadFromGistTitle =>
      isJapanese ? 'Gistから読込' : 'Load from Gist';
  String get loadingFromGist =>
      isJapanese ? '読込中...' : 'Loading from Gist...';
  String get loadedFavoritesSuccess =>
      isJapanese ? 'お気に入りを読み込みました' : 'Loaded favorites successfully';
  String get loadFailedCheckId =>
      isJapanese ? '読込に失敗しました。Gist IDを確認してください' : 'Load failed. Please check Gist ID';
  String get verifyingOnX =>
      isJapanese ? 'Xで確認中...' : 'Verifying on X...';
  String get deletingProgress =>
      isJapanese ? '削除中...' : 'Deleting...';
  String get videoLoadFailed =>
      isJapanese ? '動画の読み込みに失敗しました' : 'Failed to load video';
}

/// [JA] AppLocalizations のローダーデリゲート（システム言語自動追従）
/// [EN] LocalizationsDelegate for AppLocalizations (automatically follows system language)
class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ja', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(AppLocalizations(locale));
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
