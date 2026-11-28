import unittest
from unittest.mock import patch, MagicMock
import sys
import os
import json

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "scripts"))
from append_to_gist import process_multi_user_append
from expand_timeline_candidates import process_account

class TestCandidateLogic(unittest.TestCase):
    def test_new_user_with_is_candidate(self):
        master_data = {
            "user_gists": {},
            "tweets": []
        }
        new_tweets = [
            {
                "username": "new_candidate_user",
                "id_str": "11111",
                "media_urls": ["http://example.com/pic.jpg"]
            }
        ]

        with patch("append_to_gist.create_gist_for_user", return_value="gist_new"), \
             patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_new", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=True
            )

        user_entry = res["user_gists"].get("new_candidate_user")
        self.assertIsNotNone(user_entry)
        self.assertTrue(user_entry.get("is_candidate"))

    def test_existing_user_preserves_regular_status(self):
        # 既存ユーザー（通常ユーザー、is_candidate なし）
        master_data = {
            "user_gists": {
                "regular_user": {
                    "gist_id": "gist_existing",
                    "priority_updated_at": 1000
                }
            },
            "tweets": []
        }
        new_tweets = [
            {
                "username": "regular_user",
                "id_str": "22222",
                "media_urls": ["http://example.com/pic2.jpg"]
            }
        ]

        with patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {"regular_user": {"tweets": []}}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_existing", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=True  # タイムライン取得側が is_candidate を要求しても既存なら維持
            )

        user_entry = res["user_gists"].get("regular_user")
        self.assertIsNotNone(user_entry)
        self.assertFalse(user_entry.get("is_candidate", False))

    def test_existing_candidate_preserves_candidate_status(self):
        # 既存ユーザー（Candidate）
        master_data = {
            "user_gists": {
                "candidate_user": {
                    "gist_id": "gist_cand",
                    "priority_updated_at": 2000,
                    "is_candidate": True
                }
            },
            "tweets": []
        }
        new_tweets = [
            {
                "username": "candidate_user",
                "id_str": "33333",
                "media_urls": ["http://example.com/pic3.jpg"]
            }
        ]

        with patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {"candidate_user": {"tweets": []}}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_cand", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=False  # 通常アペンドでも candidate 状態を維持
            )

        user_entry = res["user_gists"].get("candidate_user")
        self.assertIsNotNone(user_entry)
        self.assertTrue(user_entry.get("is_candidate"))

    @patch("subprocess.run")
    def test_process_account_command_args(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)

        # 既存ユーザーの場合: -s と --skip-queue-check が付くこと、および500件渡せること
        process_account("dummy_gist", "existing_user", 500, is_existing=True)
        call_args_existing = mock_run.call_args[0][0]
        self.assertIn("-s", call_args_existing)
        self.assertIn("--skip-queue-check", call_args_existing)
        self.assertNotIn("--is-candidate", call_args_existing)
        self.assertIn("500", call_args_existing)

        # 新規ユーザーの場合: --is-candidate と --skip-queue-check が付き、-s は付かないこと、および300件渡せること
        process_account("dummy_gist", "new_user", 300, is_existing=False)
        call_args_new = mock_run.call_args[0][0]
        self.assertIn("--is-candidate", call_args_new)
        self.assertIn("--skip-queue-check", call_args_new)
        self.assertNotIn("-s", call_args_new)
        self.assertIn("300", call_args_new)

    def test_parse_args_fetch_counts(self):
        from expand_timeline_candidates import parse_args
        with patch("sys.argv", ["expand_timeline_candidates.py"]):
            args = parse_args()
            self.assertEqual(args.num, 300)
            self.assertEqual(args.num_existing, 500)

        with patch("sys.argv", ["expand_timeline_candidates.py", "-n", "150", "--num-existing", "600"]):
            args = parse_args()
            self.assertEqual(args.num, 150)
            self.assertEqual(args.num_existing, 600)

    @patch("subprocess.run")
    def test_fetch_master_user_gists_raw_url(self, mock_run):
        from expand_timeline_candidates import fetch_master_user_gists
        # 1回目の呼び出し: gh api gists/xxx
        mock_api_res = MagicMock(returncode=0)
        mock_api_res.stdout = json.dumps({
            "files": {
                "data.json": {
                    "raw_url": "https://gist.githubusercontent.com/raw/data.json"
                }
            }
        })
        # 2回目の呼び出し: curl -sf -L raw_url
        mock_curl_res = MagicMock(returncode=0)
        mock_curl_res.stdout = json.dumps({
            "user_gists": {
                "userA": {"gist_id": "g1"}
            },
            "users": {
                "userB": {"tweets": []}
            },
            "tweets": [
                {"username": "userC", "id_str": "123"}
            ]
        })
        mock_run.side_effect = [mock_api_res, mock_curl_res]

        users = fetch_master_user_gists("dummy_id")
        self.assertIn("userA", users)
        self.assertIn("userB", users)
        self.assertIn("userC", users)
        self.assertEqual(len(users), 3)

    def test_rate_limit_url_filtering(self):
        # サードパーティドメインの429は除外、X APIドメインの429は検知
        valid_domains = ["api.twitter.com", "api.x.com", "x.com/i/api/", "twitter.com/i/api/"]

        def is_x_api_rate_limit(url):
            url_lower = url.lower()
            return any(d in url_lower for d in valid_domains)

        self.assertTrue(is_x_api_rate_limit("https://x.com/i/api/graphql/xxx/UserTweets"))
        self.assertTrue(is_x_api_rate_limit("https://api.x.com/2/users/by/username/test"))
        self.assertFalse(is_x_api_rate_limit("https://analytics.google.com/g/collect?v=2"))
        self.assertFalse(is_x_api_rate_limit("https://adservice.google.com/adsid/integrator.sync"))
        self.assertFalse(is_x_api_rate_limit("https://pbs.twimg.com/media/abc.jpg"))

    def test_skip_already_registered_candidate_accounts(self):
        # マスターGist内に既に candidate アカウントが存在する場合のスキップ抽出ロジック検証
        current_user_gists = {
            "regular_user": {"gist_id": "g1", "is_candidate": False},
            "Candidate_User_1": {"gist_id": "g2", "is_candidate": True},
            "legacy_user": "gist_legacy",
        }
        candidate_users_lower = {
            k.lower() for k, v in current_user_gists.items()
            if isinstance(v, dict) and v.get("is_candidate") is True
        }

        # Candidate_User_1 が小文字で含まれていること
        self.assertIn("candidate_user_1", candidate_users_lower)
        self.assertNotIn("regular_user", candidate_users_lower)
        self.assertNotIn("legacy_user", candidate_users_lower)

        # タイムラインで拾ったアカウントのスキップ判定
        batch = ["Candidate_User_1", "regular_user", "brand_new_user"]
        skipped = []
        to_fetch = []
        for u in batch:
            if u.lower() in candidate_users_lower:
                skipped.append(u)
            else:
                to_fetch.append(u)

        self.assertEqual(skipped, ["Candidate_User_1"])
        self.assertEqual(to_fetch, ["regular_user", "brand_new_user"])


    def test_extract_accounts_js_ad_filtering(self):
        """EXTRACT_ACCOUNTS_JS がタイムライン広告のプロモーションテキストを除外し、placementTracking を含む動画ポストのアカウントは正常に抽出すること"""
        import asyncio
        from playwright.async_api import async_playwright
        from expand_timeline_candidates import EXTRACT_ACCOUNTS_JS

        async def _run():
            async with async_playwright() as p:
                browser = await p.chromium.launch(headless=True)
                page = await browser.new_page()

                await page.set_content('''
                    <article>
                        <time><a href="/valid_user1/status/100">now</a></time>
                        <div>Normal user post</div>
                    </article>
                    <article>
                        <time><a href="/promo_user/status/200">now</a></time>
                        <div>プロモーション</div>
                    </article>
                    <article>
                        <time><a href="/promoted_user/status/300">now</a></time>
                        <span>Promoted</span>
                    </article>
                    <article>
                        <time><a href="/video_user/status/400">now</a></time>
                        <div data-testid="placementTracking">
                            <div data-testid="videoPlayer"></div>
                        </div>
                    </article>
                ''')

                accounts = await page.evaluate(EXTRACT_ACCOUNTS_JS)
                await browser.close()
                return accounts

        accounts = asyncio.run(_run())
        self.assertIn("valid_user1", accounts)
        self.assertNotIn("promo_user", accounts)
        self.assertNotIn("promoted_user", accounts)
        self.assertIn("video_user", accounts)
        self.assertEqual(len(accounts), 2)

    def test_existing_unpinned_candidate_preserves_unpinned_state(self):
        """ピン留め解除されたCandidateアカウント（priority_updated_at=0）は、再アペンド時も0を維持すること（大文字小文字違い含む）"""
        master_data = {
            "user_gists": {
                "Unpinned_Candidate": {
                    "gist_id": "gist_unpinned",
                    "priority_updated_at": 0,
                    "is_candidate": True
                }
            },
            "tweets": []
        }
        # 小文字でアペンドされたケース
        new_tweets = [
            {
                "username": "unpinned_candidate",
                "id_str": "99999",
                "media_urls": ["http://example.com/unpinned.jpg"]
            }
        ]

        with patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {"unpinned_candidate": {"tweets": []}}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_unpinned", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=True
            )

        # 元の正準キーで保持され、二重登録されないこと
        self.assertIn("Unpinned_Candidate", res["user_gists"])
        self.assertNotIn("unpinned_candidate", [k for k in res["user_gists"].keys() if k != "Unpinned_Candidate"])

        entry = res["user_gists"]["Unpinned_Candidate"]
        self.assertTrue(entry.get("is_candidate"))
        # ピン留め解除状態（0）が維持されていること！
        self.assertEqual(entry.get("priority_updated_at"), 0)

    def test_collect_batch_accounts_dismisses_modals_only_initially_and_on_stall(self):
        """通常スクロール中は dismiss_modals を毎スクロール呼ばず、初回と停止時のみ呼ぶこと"""
        import asyncio
        from unittest.mock import AsyncMock
        import expand_timeline_candidates

        class FakePage:
            def __init__(self, scroll_ys, extracted_seq):
                self._scroll_ys = list(scroll_ys)
                self._extracted_seq = list(extracted_seq)
                self.mouse = MagicMock()
                self.mouse.wheel = AsyncMock()

            async def evaluate(self, expr):
                if expr == "window.scrollY":
                    return self._scroll_ys.pop(0) if self._scroll_ys else 0
                return self._extracted_seq.pop(0) if self._extracted_seq else []

        # 正常に3スクロール進行するケース: dismiss_modals は初回のみ (1回)
        page_ok = FakePage(
            scroll_ys=[0, 1000, 1000, 2000, 2000, 3000],
            extracted_seq=[["u0"], ["u1"], ["u2"], ["u3"]],
        )
        with patch.object(expand_timeline_candidates, "dismiss_modals", new_callable=AsyncMock) as mock_dismiss:
            accounts = asyncio.run(
                expand_timeline_candidates.collect_batch_accounts(
                    page_ok, scroll_batch_size=3, scroll_delay=0
                )
            )
            self.assertEqual(accounts, ["u0", "u1", "u2", "u3"])
            self.assertEqual(mock_dismiss.call_count, 1)

        # スクロール停止したケース: 初回 + 停止時の計2回呼んで break すること
        page_stall = FakePage(
            scroll_ys=[0, 0, 0],
            extracted_seq=[["u0"], []],
        )
        with patch.object(expand_timeline_candidates, "dismiss_modals", new_callable=AsyncMock) as mock_dismiss:
            accounts = asyncio.run(
                expand_timeline_candidates.collect_batch_accounts(
                    page_stall, scroll_batch_size=3, scroll_delay=0
                )
            )
            self.assertEqual(accounts, ["u0"])
            self.assertEqual(mock_dismiss.call_count, 2)

if __name__ == "__main__":
    unittest.main()
