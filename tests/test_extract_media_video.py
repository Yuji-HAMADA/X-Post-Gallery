import unittest
import sys
import os

# scripts ディレクトリを path に追加
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

from extract_media import parse_syndication_video

class TestExtractMediaVideo(unittest.TestCase):
    def test_parse_syndication_video_from_media_details(self):
        """mediaDetails が存在する場合、最高ビットレートの MP4 が選択されること"""
        sample_data = {
            "mediaDetails": [
                {
                    "type": "video",
                    "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/123/img/poster.jpg",
                    "expanded_url": "https://x.com/test_user/status/123/video/1",
                    "video_info": {
                        "variants": [
                            {
                                "content_type": "application/x-mpegURL",
                                "url": "https://video.twimg.com/pl/master.m3u8"
                            },
                            {
                                "bitrate": 632000,
                                "content_type": "video/mp4",
                                "url": "https://video.twimg.com/vid/320x568/low.mp4"
                            },
                            {
                                "bitrate": 2176000,
                                "content_type": "video/mp4",
                                "url": "https://video.twimg.com/vid/720x1280/high.mp4"
                            },
                            {
                                "bitrate": 950000,
                                "content_type": "video/mp4",
                                "url": "https://video.twimg.com/vid/480x852/mid.mp4"
                            }
                        ]
                    }
                }
            ]
        }

        extracted = parse_syndication_video(sample_data, "test_user", "123")
        self.assertEqual(len(extracted), 1)
        item = extracted[0]
        self.assertEqual(item["type"], "video")
        self.assertEqual(item["media_url_https"], "https://pbs.twimg.com/amplify_video_thumb/123/img/poster.jpg")
        self.assertEqual(item["expanded_url"], "https://x.com/test_user/status/123/video/1")
        variants = item["video_info"]["variants"]
        self.assertEqual(len(variants), 1)
        self.assertEqual(variants[0]["url"], "https://video.twimg.com/vid/720x1280/high.mp4")
        self.assertEqual(variants[0]["bitrate"], 2176000)

    def test_parse_syndication_video_fallback(self):
        """mediaDetails がなく video オブジェクトのみの場合、最高画質の MP4 が選択されること"""
        sample_data = {
            "video": {
                "poster": "https://pbs.twimg.com/amplify_video_thumb/456/img/fallback.jpg",
                "variants": [
                    {
                        "type": "video/mp4",
                        "src": "https://video.twimg.com/vid/320x568/low.mp4"
                    },
                    {
                        "type": "video/mp4",
                        "src": "https://video.twimg.com/vid/720x1280/high.mp4"
                    },
                    {
                        "type": "video/mp4",
                        "src": "https://video.twimg.com/vid/480x852/mid.mp4"
                    }
                ]
            }
        }

        extracted = parse_syndication_video(sample_data, "test_user", "456")
        self.assertEqual(len(extracted), 1)
        item = extracted[0]
        self.assertEqual(item["type"], "video")
        self.assertEqual(item["media_url_https"], "https://pbs.twimg.com/amplify_video_thumb/456/img/fallback.jpg")
        variants = item["video_info"]["variants"]
        self.assertEqual(len(variants), 1)
        self.assertEqual(variants[0]["url"], "https://video.twimg.com/vid/720x1280/high.mp4")

    def test_parse_syndication_video_empty(self):
        """動画情報が存在しない場合は空リストを返すこと"""
        sample_data = {
            "photos": [{"url": "https://pbs.twimg.com/media/abc.jpg"}]
        }
        extracted = parse_syndication_video(sample_data, "test_user", "789")
        self.assertEqual(extracted, [])

if __name__ == "__main__":
    unittest.main()
