import 'package:flutter_test/flutter_test.dart';
import 'package:x_post_gallery/utils/video_http_headers.dart';

void main() {
  group('buildVideoHttpHeaders', () {
    test('TikTok 動画URLには Referer ヘッダーを付与する', () {
      expect(
        buildVideoHttpHeaders(
          'https://www.tiktok.com/aweme/v1/play/?video_id=abc123',
        ),
        {'Referer': 'https://www.tiktok.com/'},
      );
      expect(
        buildVideoHttpHeaders(
          'https://v16-web-newkey.tiktokcdn.com/video/tos/sample.mp4',
        ),
        {'Referer': 'https://www.tiktok.com/'},
      );
    });

    test('X / Instagram の動画URLには余分なヘッダーを付与しない', () {
      expect(
        buildVideoHttpHeaders('https://video.twimg.com/ext_tw_video/123/pu/vid/sample.mp4'),
        isEmpty,
      );
      expect(
        buildVideoHttpHeaders('https://scontent-nrt1-1.cdninstagram.com/v/sample.mp4'),
        isEmpty,
      );
    });
  });
}
