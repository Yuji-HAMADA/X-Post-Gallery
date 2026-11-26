/// [JA] 動画URLのホストに応じて再生リクエストに必要な HTTP ヘッダーを返す
/// [EN] Returns required HTTP headers for video playback based on URL host
Map<String, String> buildVideoHttpHeaders(String videoUrl) {
  final uri = Uri.tryParse(videoUrl);
  final host = uri?.host.toLowerCase() ?? '';
  if (host == 'tiktok.com' ||
      host.endsWith('.tiktok.com') ||
      host.endsWith('.tiktokcdn.com') ||
      host.endsWith('.tiktokcdn-us.com') ||
      host.endsWith('.tiktokv.com') ||
      host.endsWith('.tiktokv.us')) {
    return const {'Referer': 'https://www.tiktok.com/'};
  }
  return const {};
}
