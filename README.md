# 使い方
配列に、直接入力する方法と、ファイルに書く方法を用意

10行目のkw_list書き換えて入力

キーワードリストをファイルで用意し、target_fileに記載

crawl-image.rbの上のほう書き換えて、適当に設定

yahooとgoogle画像検索に対応

```
# テスト用にファイル設置
$ wget http://dumps.wikimedia.org/jawiki/20140225/jawiki-20140225-all-titles.gz
$ tar xzvf jawiki-20140225-all-titles.gz
$ head jawiki-20140225-all-titles > jawiki-20140225-all-titles.chip

# 実行
$ ruby ./crawl-image.rb
```

