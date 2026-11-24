import asyncio
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

try:
    import playwright  # noqa: F401
except ImportError:
    mock_playwright = MagicMock()
    sys.modules["playwright"] = mock_playwright
    sys.modules["playwright.async_api"] = mock_playwright.async_api

import extract_media


def _make_tweet_item(tid, user="alice", is_pinned=False):
    return {
        "tweet": {
            "id_str": str(tid),
            "full_text": f"@{user}: post {tid}",
            "created_at": "2026-11-24 12:00:00 JST",
            "entities": {
                "media": [
                    {
                        "media_url_https": f"https://pbs.twimg.com/media/{tid}?format=jpg",
                        "type": "photo",
                        "expanded_url": f"https://x.com/{user}/status/{tid}/photo/1",
                    }
                ]
            },
            "extended_entities": {
                "media": [
                    {
                        "media_url_https": f"https://pbs.twimg.com/media/{tid}?format=jpg",
                        "type": "photo",
                        "expanded_url": f"https://x.com/{user}/status/{tid}/photo/1",
                    }
                ]
            },
        },
        "is_pinned": is_pinned,
    }


def _make_raw_article(tid, user="alice", is_pinned=False):
    art = MagicMock()
    art.evaluate = AsyncMock(
        return_value={
            "origin_user": user,
            "origin_status_id": str(tid),
            "is_pinned": is_pinned,
            "raw_text": f"post {tid}",
            "photo_urls": [f"https://pbs.twimg.com/media/{tid}?format=jpg"],
            "has_video": False,
            "timestamp": "2026-11-24T03:00:00.000Z",
        }
    )
    return art


class TestExtractMediaResumeHelpers(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.orig_data_dir = extract_media.DATA_DIR
        self.orig_resume_dir = extract_media.RESUME_DIR
        self.orig_output_file = extract_media.OUTPUT_FILE
        self.orig_auth_path = extract_media.AUTH_PATH
        self.orig_result_file = extract_media.RESULT_FILE

        extract_media.DATA_DIR = self.tmp_dir.name
        extract_media.RESUME_DIR = os.path.join(self.tmp_dir.name, "resume")
        extract_media.OUTPUT_FILE = os.path.join(self.tmp_dir.name, "tweets.js")
        extract_media.AUTH_PATH = os.path.join(self.tmp_dir.name, "auth.json")
        extract_media.RESULT_FILE = os.path.join(self.tmp_dir.name, ".last_fetch_result.json")

        with open(extract_media.AUTH_PATH, "w", encoding="utf-8") as f:
            json.dump({"cookies": []}, f)

    def tearDown(self):
        extract_media.DATA_DIR = self.orig_data_dir
        extract_media.RESUME_DIR = self.orig_resume_dir
        extract_media.OUTPUT_FILE = self.orig_output_file
        extract_media.AUTH_PATH = self.orig_auth_path
        extract_media.RESULT_FILE = self.orig_result_file
        self.tmp_dir.cleanup()

    def test_parse_args_no_resume_flag(self):
        """--no-resume 引数のデフォルト(False)および指定時(True)が正しくパースされること"""
        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice"]):
            args = extract_media.parse_args()
            self.assertFalse(args.no_resume)

        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice", "--no-resume"]):
            args = extract_media.parse_args()
            self.assertTrue(args.no_resume)

    def test_save_load_clear_resume_state(self):
        """チェックポイントの保存・読み込み・期限切れ破棄・削除が正しく動作すること"""
        tweets = [_make_tweet_item("100"), _make_tweet_item("101")]
        extract_media.save_resume_state("Alice", tweets, {"100", "101", "102"}, cursor="CUR_1", target_num=300)

        loaded = extract_media.load_resume_state("alice")
        self.assertIsNotNone(loaded)
        self.assertEqual(len(loaded["tweets"]), 2)
        self.assertEqual(loaded["cursor"], "CUR_1")
        self.assertEqual(set(loaded["seen_ids"]), {"100", "101", "102"})
        self.assertEqual(loaded["target_num"], 300)

        # TTL 超過時は None を返しファイルも削除される
        expired = extract_media.load_resume_state(
            "alice",
            ttl_seconds=60,
            now=loaded["saved_at"] + 120,
        )
        self.assertIsNone(expired)
        self.assertFalse(os.path.exists(extract_media.get_resume_file_path("alice")))

    def test_save_resume_state_ignores_empty(self):
        """ツイートもカーソルも空の場合はチェックポイントを作成しないこと"""
        extract_media.save_resume_state("alice", [], set(), cursor=None, target_num=100)
        self.assertFalse(os.path.exists(extract_media.get_resume_file_path("alice")))

    def test_load_resume_state_corrupt_json(self):
        """破損したJSONファイルは安全に破棄され None を返すこと"""
        os.makedirs(extract_media.RESUME_DIR, exist_ok=True)
        path = extract_media.get_resume_file_path("alice")
        with open(path, "w", encoding="utf-8") as f:
            f.write("{corrupt json")
        self.assertIsNone(extract_media.load_resume_state("alice"))
        self.assertFalse(os.path.exists(path))

    def test_apply_resume_state_dedups_and_filters_skip_ids(self):
        """復元時に skip_ids 該当・重複を除外しつつ resumed_ids に保持すること"""
        state = {
            "tweets": [_make_tweet_item("10"), _make_tweet_item("11"), _make_tweet_item("11"), _make_tweet_item("12")],
            "seen_ids": ["10", "11", "12", "13"],
            "cursor": "CUR_X",
        }
        restored, resumed_ids, cursor = extract_media.apply_resume_state(state, skip_ids={"10"})
        self.assertEqual([t["tweet"]["id_str"] for t in restored], ["11", "12"])
        self.assertEqual(resumed_ids, {"10", "11", "12", "13"})
        self.assertEqual(cursor, "CUR_X")

    def test_graphql_url_helpers(self):
        """UserTweets GraphQL URL の判定・cursor 抽出・cursor 注入が正しく動作すること"""
        base_url = (
            "https://x.com/i/api/graphql/AbCdEf/UserTweets"
            "?variables=%7B%22userId%22%3A%2242%22%2C%22count%22%3A20%7D&features=%7B%7D"
        )
        replies_url = (
            "https://x.com/i/api/graphql/AbCdEf/UserTweetsAndReplies"
            "?variables=%7B%22userId%22%3A%2242%22%7D"
        )
        self.assertTrue(extract_media.is_user_tweets_graphql_url(base_url))
        self.assertFalse(extract_media.is_user_tweets_graphql_url(replies_url))
        self.assertFalse(extract_media.is_user_tweets_graphql_url("https://x.com/alice"))

        self.assertIsNone(extract_media.extract_cursor_from_graphql_url(base_url))

        injected = extract_media.inject_cursor_into_graphql_url(base_url, "DAABCgAB123")
        self.assertIsNotNone(injected)
        self.assertEqual(extract_media.extract_cursor_from_graphql_url(injected), "DAABCgAB123")

        # 既に cursor がある後続リクエストには二重注入しない
        self.assertIsNone(extract_media.inject_cursor_into_graphql_url(injected, "OTHER_CUR"))

    def test_extract_user_tweets_page_info(self):
        """UserTweets レスポンスから通常ツイート・スレッド・Bottomカーソルを抽出し広告を除外すること"""
        payload = {
            "data": {
                "user": {
                    "result": {
                        "timeline_v2": {
                            "timeline": {
                                "instructions": [
                                    {
                                        "type": "TimelineAddEntries",
                                        "entries": [
                                            {"entryId": "tweet-1001", "content": {"itemContent": {}}},
                                            {"entryId": "promoted-tweet-9999", "content": {"itemContent": {"promotedMetadata": {}}}},
                                            {
                                                "entryId": "profile-conversation-1002",
                                                "content": {
                                                    "items": [
                                                        {
                                                            "item": {
                                                                "itemContent": {
                                                                    "tweet_results": {
                                                                        "result": {"rest_id": "1002"}
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    ]
                                                },
                                            },
                                            {
                                                "entryId": "cursor-bottom-1",
                                                "content": {"cursorType": "Bottom", "value": "CUR_BOTTOM_1"},
                                            },
                                        ],
                                    }
                                ]
                            }
                        }
                    }
                }
            }
        }
        tids, bottom = extract_media.extract_user_tweets_page_info(payload)
        self.assertEqual(tids, ["1001", "1002"])
        self.assertEqual(bottom, "CUR_BOTTOM_1")

    def test_select_resume_cursor(self):
        """中断直前ツイートを含むページの要求カーソルが選ばれ、未登録時はフォールバックされること"""
        page_map = {"100": None, "200": "CUR_PAGE2", "201": "CUR_PAGE2"}
        self.assertEqual(extract_media.select_resume_cursor("201", page_map, fallback_cursor="OLD"), "CUR_PAGE2")
        self.assertIsNone(extract_media.select_resume_cursor("100", page_map, fallback_cursor="OLD"))
        self.assertEqual(extract_media.select_resume_cursor("999", page_map, fallback_cursor="OLD"), "OLD")


class TestExtractMediaResumeFlow(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.orig_data_dir = extract_media.DATA_DIR
        self.orig_resume_dir = extract_media.RESUME_DIR
        self.orig_output_file = extract_media.OUTPUT_FILE
        self.orig_auth_path = extract_media.AUTH_PATH
        self.orig_result_file = extract_media.RESULT_FILE

        extract_media.DATA_DIR = self.tmp_dir.name
        extract_media.RESUME_DIR = os.path.join(self.tmp_dir.name, "resume")
        extract_media.OUTPUT_FILE = os.path.join(self.tmp_dir.name, "tweets.js")
        extract_media.AUTH_PATH = os.path.join(self.tmp_dir.name, "auth.json")
        extract_media.RESULT_FILE = os.path.join(self.tmp_dir.name, ".last_fetch_result.json")

        with open(extract_media.AUTH_PATH, "w", encoding="utf-8") as f:
            json.dump({"cookies": []}, f)

    def tearDown(self):
        extract_media.DATA_DIR = self.orig_data_dir
        extract_media.RESUME_DIR = self.orig_resume_dir
        extract_media.OUTPUT_FILE = self.orig_output_file
        extract_media.AUTH_PATH = self.orig_auth_path
        extract_media.RESULT_FILE = self.orig_result_file
        self.tmp_dir.cleanup()

    def _build_mock_playwright(self, page):
        browser = MagicMock()
        browser.close = AsyncMock()
        context = MagicMock()
        context.route = AsyncMock()
        context.new_page = AsyncMock(return_value=page)
        browser.new_context = AsyncMock(return_value=context)

        pw = MagicMock()
        pw.chromium.launch = AsyncMock(return_value=browser)

        cm = MagicMock()
        cm.__aenter__ = AsyncMock(return_value=pw)
        cm.__aexit__ = AsyncMock(return_value=False)
        return cm, browser

    def test_checkpoint_completes_immediately_when_target_already_met(self):
        """復元時点で既に -n 件数以上ある場合、ブラウザ起動なしで tweets.js 出力・チェックポイント削除すること"""
        saved = [_make_tweet_item("1"), _make_tweet_item("2"), _make_tweet_item("3")]
        extract_media.save_resume_state("alice", saved, {"1", "2", "3"}, cursor="CUR_1", target_num=5)

        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice", "-n", "2"]), \
             patch.object(extract_media, "async_playwright") as mock_pw:
            asyncio.run(extract_media.run())
            mock_pw.assert_not_called()

        self.assertFalse(os.path.exists(extract_media.get_resume_file_path("alice")))
        with open(extract_media.OUTPUT_FILE, "r", encoding="utf-8") as f:
            content = f.read().replace("window.YTD.tweets.part0 = ", "")
            out = json.loads(content)
        self.assertEqual([t["tweet"]["id_str"] for t in out], ["1", "2"])

    def test_rate_limit_saves_checkpoint_and_next_run_resumes_to_completion(self):
        """Run1でレート制限(42)中断時にチェックポイント保存し、Run2でカーソル注入＋残り件数のみ取得して完了すること"""
        # --- Run 1: 5件指定中、3件取得後に 429 発生 ---
        response_handlers = []
        page1 = MagicMock()
        page1.add_init_script = AsyncMock()
        page1.route = AsyncMock()
        page1.on = MagicMock(side_effect=lambda ev, fn: response_handlers.append(fn) if ev == "response" else None)
        page1.goto = AsyncMock()
        page1.inner_text = AsyncMock(return_value="normal body")
        page1.query_selector = AsyncMock(return_value=None)

        call_idx = {"n": 0}

        async def page1_query_all(sel):
            if sel != "article":
                return []
            call_idx["n"] += 1
            if call_idx["n"] == 1:
                # Page 2 の GraphQL レスポンス（cursor="CUR_P2" で 201, 202, 203 を取得した想定）を通知
                resp_ok = MagicMock()
                resp_ok.status = 200
                resp_ok.url = (
                    "https://x.com/i/api/graphql/xyz/UserTweets"
                    "?variables=%7B%22userId%22%3A%221%22%2C%22cursor%22%3A%22CUR_P2%22%7D"
                )
                resp_ok.json = AsyncMock(
                    return_value={
                        "data": {
                            "user": {
                                "result": {
                                    "timeline_v2": {
                                        "timeline": {
                                            "instructions": [
                                                {
                                                    "type": "TimelineAddEntries",
                                                    "entries": [
                                                        {"entryId": "tweet-201", "content": {}},
                                                        {"entryId": "tweet-202", "content": {}},
                                                        {"entryId": "tweet-203", "content": {}},
                                                        {"entryId": "cursor-bottom-0", "content": {"cursorType": "Bottom", "value": "CUR_P3"}},
                                                    ],
                                                }
                                            ]
                                        }
                                    }
                                }
                            }
                        }
                    }
                )
                for h in response_handlers:
                    await h(resp_ok)
                return [_make_raw_article("201"), _make_raw_article("202"), _make_raw_article("203")]
            return []

        async def page1_scroll(expr):
            # 1回目のスクロール時に 429 レート制限が返る
            resp_429 = MagicMock()
            resp_429.status = 429
            resp_429.url = "https://x.com/i/api/graphql/xyz/UserTweets?variables=%7B%7D"
            for h in response_handlers:
                await h(resp_429)

        page1.query_selector_all = AsyncMock(side_effect=page1_query_all)
        page1.evaluate = AsyncMock(side_effect=page1_scroll)

        cm1, _ = self._build_mock_playwright(page1)

        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice", "-n", "5", "--stop-on-existing"]), \
             patch.object(extract_media, "async_playwright", return_value=cm1), \
             patch.object(extract_media, "dismiss_modals", new=AsyncMock()), \
             patch.object(extract_media, "check_account_status", new=AsyncMock(return_value=None)), \
             patch.object(extract_media, "wait_for_timeline", new=AsyncMock(return_value="ready")), \
             patch.object(extract_media.asyncio, "sleep", new=AsyncMock()):
            with self.assertRaises(SystemExit) as ctx:
                asyncio.run(extract_media.run())
            self.assertEqual(ctx.exception.code, 42)

        # チェックポイントが保存されていること
        cp = extract_media.load_resume_state("alice")
        self.assertIsNotNone(cp)
        self.assertEqual([t["tweet"]["id_str"] for t in cp["tweets"]], ["201", "202", "203"])
        self.assertEqual(cp["cursor"], "CUR_P2")
        self.assertFalse(os.path.exists(extract_media.OUTPUT_FILE))

        # --- Run 2: 再実行でカーソル注入＋重複203をスキップし残り204,205のみ取得して5件完了 ---
        route_handlers = []
        page2 = MagicMock()
        page2.add_init_script = AsyncMock()

        async def register_route(pattern, handler):
            route_handlers.append(handler)

        page2.route = AsyncMock(side_effect=register_route)
        page2.unroute = AsyncMock()
        page2.on = MagicMock()
        page2.inner_text = AsyncMock(return_value="normal body")
        page2.query_selector = AsyncMock(return_value=None)
        page2.evaluate = AsyncMock()

        injected_urls = []

        async def page2_goto(url, **kwargs):
            # 初期 UserTweets リクエストがルートフックを通過するシミュレーション
            req_route = MagicMock()
            req_route.request.url = (
                "https://x.com/i/api/graphql/xyz/UserTweets"
                "?variables=%7B%22userId%22%3A%221%22%2C%22count%22%3A20%7D"
            )
            async def _continue(url=None):
                injected_urls.append(url)
            req_route.continue_ = AsyncMock(side_effect=_continue)
            for rh in route_handlers:
                await rh(req_route)

        page2.goto = AsyncMock(side_effect=page2_goto)
        # 203 は重複（resumed_ids でスキップされ --stop-on-existing を誤発火しない）、204, 205 が新規取得
        page2.query_selector_all = AsyncMock(
            return_value=[_make_raw_article("203"), _make_raw_article("204"), _make_raw_article("205")]
        )

        cm2, _ = self._build_mock_playwright(page2)

        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice", "-n", "5", "--stop-on-existing"]), \
             patch.object(extract_media, "async_playwright", return_value=cm2), \
             patch.object(extract_media, "dismiss_modals", new=AsyncMock()), \
             patch.object(extract_media, "check_account_status", new=AsyncMock(return_value=None)), \
             patch.object(extract_media, "wait_for_timeline", new=AsyncMock(return_value="ready")), \
             patch.object(extract_media.asyncio, "sleep", new=AsyncMock()):
            asyncio.run(extract_media.run())

        # カーソルが初期リクエストに注入されたこと
        self.assertEqual(len(injected_urls), 1)
        self.assertEqual(extract_media.extract_cursor_from_graphql_url(injected_urls[0]), "CUR_P2")

        # 5件すべてが tweets.js に出力され、チェックポイントは削除されていること
        self.assertFalse(os.path.exists(extract_media.get_resume_file_path("alice")))
        with open(extract_media.OUTPUT_FILE, "r", encoding="utf-8") as f:
            out = json.loads(f.read().replace("window.YTD.tweets.part0 = ", ""))
        self.assertEqual([t["tweet"]["id_str"] for t in out], ["201", "202", "203", "204", "205"])

    def test_cursor_fallback_to_top_scroll_preserves_resumed_tweets_and_guards(self):
        """カーソル再開が失敗/空だった場合、先頭スクロールへフォールバックし既存取得分を保持・no_new_scrolls誤停止せず完了すること"""
        saved = [_make_tweet_item("10"), _make_tweet_item("11")]
        extract_media.save_resume_state("alice", saved, {"10", "11"}, cursor="EXPIRED_CUR", target_num=3)

        route_handlers = []
        page = MagicMock()
        page.add_init_script = AsyncMock()
        page.route = AsyncMock(side_effect=lambda pat, fn: route_handlers.append(fn))
        page.unroute = AsyncMock()
        page.on = MagicMock()
        page.inner_text = AsyncMock(return_value="normal body")
        page.query_selector = AsyncMock(return_value=None)
        page.evaluate = AsyncMock()

        goto_count = {"n": 0}

        async def mock_goto(url, **kwargs):
            goto_count["n"] += 1
            if goto_count["n"] == 1:
                req_route = MagicMock()
                req_route.request.url = (
                    "https://x.com/i/api/graphql/xyz/UserTweets"
                    "?variables=%7B%22userId%22%3A%221%22%7D"
                )
                req_route.continue_ = AsyncMock()
                for rh in route_handlers:
                    await rh(req_route)

        page.goto = AsyncMock(side_effect=mock_goto)

        # スクロール1回目: 10 (resumed), 2回目: 11 (resumed), 3回目: 12 (new!)
        # --max-no-new-scrolls 1 でも resumed 通過中はリセットされ停止しないことを検証
        scroll_batches = [
            [_make_raw_article("10")],
            [_make_raw_article("11")],
            [_make_raw_article("12")],
        ]
        batch_idx = {"i": 0}

        async def mock_qsa(sel):
            if sel != "article":
                return []
            i = batch_idx["i"]
            batch_idx["i"] += 1
            return scroll_batches[i] if i < len(scroll_batches) else []

        page.query_selector_all = AsyncMock(side_effect=mock_qsa)
        cm, _ = self._build_mock_playwright(page)

        # 1回目の wait_for_timeline は empty（期限切れカーソル）、フォールバック後の2回目は ready
        wait_mock = AsyncMock(side_effect=["empty", "ready"])

        with patch.object(sys, "argv", ["extract_media.py", "-u", "alice", "-n", "3", "--max-no-new-scrolls", "1"]), \
             patch.object(extract_media, "async_playwright", return_value=cm), \
             patch.object(extract_media, "dismiss_modals", new=AsyncMock()), \
             patch.object(extract_media, "check_account_status", new=AsyncMock(return_value=None)), \
             patch.object(extract_media, "wait_for_timeline", new=wait_mock), \
             patch.object(extract_media.asyncio, "sleep", new=AsyncMock()):
            asyncio.run(extract_media.run())

        self.assertEqual(goto_count["n"], 2)
        page.unroute.assert_awaited()
        self.assertFalse(os.path.exists(extract_media.get_resume_file_path("alice")))
        with open(extract_media.OUTPUT_FILE, "r", encoding="utf-8") as f:
            out = json.loads(f.read().replace("window.YTD.tweets.part0 = ", ""))
        self.assertEqual([t["tweet"]["id_str"] for t in out], ["10", "11", "12"])


if __name__ == "__main__":
    unittest.main()
