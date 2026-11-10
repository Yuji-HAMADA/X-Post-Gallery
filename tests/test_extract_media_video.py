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

    def test_parse_syndication_video_multiple(self):
        """mediaDetails に複数動画が存在する場合、すべての動画が抽出されインデックス付きURLになること"""
        sample_data = {
            "mediaDetails": [
                {
                    "type": "video",
                    "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/1/img/p1.jpg",
                    "video_info": {
                        "variants": [
                            {"bitrate": 1000, "content_type": "video/mp4", "url": "https://video.twimg.com/v1.mp4"}
                        ]
                    }
                },
                {
                    "type": "video",
                    "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/2/img/p2.jpg",
                    "video_info": {
                        "variants": [
                            {"bitrate": 2000, "content_type": "video/mp4", "url": "https://video.twimg.com/v2.mp4"}
                        ]
                    }
                }
            ]
        }
        extracted = parse_syndication_video(sample_data, "artistmatsuoka", "999")
        self.assertEqual(len(extracted), 2)
        self.assertEqual(extracted[0]["expanded_url"], "https://x.com/artistmatsuoka/status/999/video/1")
        self.assertEqual(extracted[1]["expanded_url"], "https://x.com/artistmatsuoka/status/999/video/2")
        self.assertEqual(extracted[0]["video_info"]["variants"][0]["url"], "https://video.twimg.com/v1.mp4")
        self.assertEqual(extracted[1]["video_info"]["variants"][0]["url"], "https://video.twimg.com/v2.mp4")

    def test_convert_to_gist_format_multiple_videos(self):
        """append_to_gist の convert_raw_tweets_to_gist_format で複数動画が video_urls に格納されること"""
        from append_to_gist import convert_raw_tweets_to_gist_format
        raw_tweets = [
            {
                "id_str": "999",
                "full_text": "multiple videos",
                "created_at": "2026-11-09T08:29:08.000Z",
                "extended_entities": {
                    "media": [
                        {
                            "type": "video",
                            "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/1/img/p1.jpg",
                            "expanded_url": "https://x.com/user/status/999/video/1",
                            "video_info": {
                                "variants": [{"bitrate": 1000, "content_type": "video/mp4", "url": "https://video.twimg.com/v1.mp4"}]
                            }
                        },
                        {
                            "type": "video",
                            "media_url_https": "https://pbs.twimg.com/amplify_video_thumb/2/img/p2.jpg",
                            "expanded_url": "https://x.com/user/status/999/video/2",
                            "video_info": {
                                "variants": [{"bitrate": 2000, "content_type": "video/mp4", "url": "https://video.twimg.com/v2.mp4"}]
                            }
                        }
                    ]
                }
            }
        ]
        converted = convert_raw_tweets_to_gist_format(raw_tweets)
        self.assertEqual(len(converted), 1)
        item = converted[0]
        self.assertEqual(item["video_url"], "https://video.twimg.com/v1.mp4")
        self.assertEqual(item["video_urls"], ["https://video.twimg.com/v1.mp4", "https://video.twimg.com/v2.mp4"])
        self.assertEqual(len(item["media_urls"]), 2)

    def test_parse_syndication_video_empty(self):
        """動画情報が存在しない場合は空リストを返すこと"""
        sample_data = {
            "photos": [{"url": "https://pbs.twimg.com/media/abc.jpg"}]
        }
        extracted = parse_syndication_video(sample_data, "test_user", "789")
        self.assertEqual(extracted, [])

if __name__ == "__main__":
    unittest.main()
