import json
import re
import os

def convert():
    # 実行場所がプロジェクトルートの場合、パスを調整してください
    input_file = 'data/tweets.js'
    output_file = 'assets/data/data.json'
    
    if not os.path.exists(input_file):
        print(f"エラー: {input_file} が見つかりません。")
        return

    with open(input_file, 'r', encoding='utf-8') as f:
        content = f.read()
        # window.YTD.tweets.part0 = の部分を削除
        json_str = re.sub(r'^window\.YTD\.tweets\.part0\s*=\s*', '', content)
        data = json.loads(json_str)

    new_tweets = []
    detected_user = ""

    for item in data:
        # extract_media.py の出力構造 [ {"tweet": {...}}, ... ] に対応
        tweet = item.get('tweet', {})
        full_text = tweet.get('full_text', '')

        # 本人のポスト（RTでない）からユーザー名を特定
        if not detected_user and not full_text.startswith("RT @"):
            match = re.match(r'@([^:]+):', full_text)
            if match:
                detected_user = match.group(1)

        # extended_entities もしくは entities からメディアを取得
        media_list = tweet.get('extended_entities', {}).get('media', [])
        if not media_list:
            media_list = tweet.get('entities', {}).get('media', [])

        if media_list:
            media_urls = [m.get('media_url_https', '') for m in media_list if m.get('media_url_https')]
            if media_urls:
                # expanded_url からポストURLを構築 (例: https://x.com/user/status/123/photo/1 → https://x.com/user/status/123)
                post_url = ''
                for m in media_list:
                    eu = m.get('expanded_url', '')
                    if '/status/' in eu:
                        post_url = re.sub(r'/photo/\d+$', '', eu)
                        break

                entry = {
                    'full_text': full_text,
                    'created_at': tweet.get('created_at', ''),
                    'media_urls': media_urls,
                    'id_str': tweet.get('id_str', '')
                }
                if post_url:
                    entry['post_url'] = post_url
                new_tweets.append(entry)

    # メタデータ付きの構造で保存
    final_output = {
        "user_screen_name": detected_user or "Unknown",
        "tweets": new_tweets
    }

    os.makedirs(os.path.dirname(output_file), exist_ok=True)

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(final_output, f, ensure_ascii=False, indent=2)
    
    print(f"✅ 変換完了！ User: @{detected_user}, {len(new_tweets)} 件のデータを保存しました。")

if __name__ == "__main__":
    convert()