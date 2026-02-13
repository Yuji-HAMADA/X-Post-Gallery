import json
import re
import os

def convert():
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

    new_data = []
    for item in data:
        tweet = item.get('tweet', {})
        media_list = tweet.get('extended_entities', {}).get('media', [])
        
        if media_list:
            # ★ 修正：すべての画像URLを抽出してリストにする
            media_urls = [m.get('media_url_https', '') for m in media_list if m.get('media_url_https')]
            
            new_data.append({
                'full_text': tweet.get('full_text', ''),
                'created_at': tweet.get('created_at', ''),
                # 'media_url' ではなく 'media_urls' (リスト) として保存
                'media_urls': media_urls, 
                'id_str': tweet.get('id_str', '')
            })

    # assets/data ディレクトリがなければ作成
    os.makedirs(os.path.dirname(output_file), exist_ok=True)

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(new_data, f, ensure_ascii=False, indent=2)
    
    print(f"変換完了！ {len(new_data)} 件のデータを {output_file} に保存しました。")

if __name__ == "__main__":
    convert()