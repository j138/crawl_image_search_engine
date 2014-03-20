#!/usr/local/bin/ruby
# coding: utf-8
require 'net/http'
require 'uri'
require 'openssl'
require 'digest/md5'
require 'nokogiri'

# Config =========================
kw_list = %W(lol Diablo blizzard)
# target_file = 'jawiki-20140225-all-titles.chip'
target_file = 'jawiki-20140225-all-titles'
save_dir = 'img/'

# 検索するエンジン
# yahoo, google
provider = 'yahoo'

thread_max = 4

# thread生存分多くDLしてくる クリティカルじゃないからスルーで
download_limit = 10_000
# ================================

# download que
job_que = Queue.new

# generate Query for google Image Search
def gen_crawl_uri(kw, provider)
  case provider
  when 'google'
    # safe_search_params
    safe_querys = %W(off medium high)
    safe_query = safe_querys[1]

    host = 'https://www.google.co.jp/search?'
    query_hash = {
      q: URI.escape(kw), safe: safe_query,
      tbm: 'isch', source: 'og',
      ie: 'UTF-8', oe: 'UTF-8', hl: 'ja', lr: 'ja', client: 'firefox-a',
      hs: 'zfJ', bav: 'on.2,or.r_cp.', biw: '1440', bih: '694', um: '1', pws: 0
    }

  when 'yahoo'
    host = 'http://image.search.yahoo.co.jp/search?'
    query_hash = {
      p: URI.escape(kw), oq: '', ei: 'UTF-8',
      # 顔写真用のフラフ
      # ctype: 'face',
      rkf: 1, imw: 0, imh: 0, imt: '', dim: '', imcolor: ''
    }
  end

  host + query_hash.map { |k, v| "#{k}=#{v}" }.join('&')
end

def http_request(uri)
  uri_parsed = URI.parse(uri)
  http = Net::HTTP.new(uri_parsed.host, uri_parsed.port)

  if uri_parsed.port == 443
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end

  # http.set_debug_output $stderr
  body = http.get(uri).body
  File.write('debug.html', body)
  body
end

# e.g. save_dir/md5(url).jpg
def download_file(uri, save_dir, filename)
  # all jpg. i hope so.
  filename = save_dir + filename + '.jpg'

  # すでにファイルがあるならスキップ
  if File.exist?(filename)
    puts '[duplicate]' + uri
    return true
  end

  begin
    res = Net::HTTP.get_response(URI.parse(uri))
  # rescue TypeError, SocketError => e
  rescue => e
    puts '[Error]' + e.message
    puts '  => ' + uri
    return false
  end

  if res.code.to_i == 200
    open(filename, 'wb') do |file|
      file.puts Net::HTTP.get_response(URI.parse(uri)).body
    end
    printf('[save]"%s" as %s' + "\n", uri, filename)
    return true
  else
    printf('[status:%s]skip "%s"' + "\n", res.code, uri)
    return false
  end
end

def crawl_image(kw, save_dir, provider, job_que)
  puts '[reserve]' + kw
  uri = ''
  case provider
  when 'google'
    doc = Nokogiri::HTML.parse(http_request(gen_crawl_uri(kw, provider)))
    doc.css('a img').each do |node|
      uri = node.attribute('src').value
      job_que.push(uri: uri, save_dir: save_dir, filename: Digest::MD5.hexdigest(uri)) if uri != ''
    end
  when 'yahoo'
    doc = Nokogiri::HTML.parse(http_request(gen_crawl_uri(kw, provider)))
    doc.css('.tb a').each do |node|
      uri = node.attribute('href').value
      job_que.push(uri: uri, save_dir: save_dir, filename: Digest::MD5.hexdigest(uri)) if uri != ''
    end
  end
end

Dir.mkdir(save_dir) unless File.directory?(save_dir)

# target->hash
kw_list.each { |kw| crawl_image(kw, save_dir, provider, job_que) }

# # target->file(kw_list)
count = 0
if File.exist?(target_file)
  File.foreach(target_file) do |line|
    crawl_image(line.chomp!, save_dir, provider, job_que)
    count += 1
    break if count > 1000
  end
end

# async download
threads = []
# thread生存分多くDLしてくる 足がでた画像を消してもいいが特に必要性はないのでそのままで
# countをatomicに管理する必要があるかもしれないが、やはりクリティカルじゃないのでそのままで
count = 0
thread_max.times do
  threads << Thread.start do
    until job_que.empty?
      info = job_que.pop
      count += 1 if download_file(info[:uri], info[:save_dir], info[:filename])
      puts '[counter]' + count.to_s
      break if count > download_limit - thread_max
    end
  end
end

threads.each { |t| t.join }
puts 'completed'
