#!/usr/local/bin/ruby
# coding: utf-8
require 'net/http'
require 'uri'
require 'openssl'
require 'digest/md5'
require 'json'
require 'nokogiri'
require 'mechanize'
require 'thwait'

config = open('config.json') { |io| JSON.load(io) }
puts 'config loaded'

# yahooはログインしないと、アダルトフィルタに引っかかるのでログインする
def init_agent(config)
  case config['provider']
  when 'yahoo'
    Mechanize.new do |agent|
      cookie_name = 'cookie.yaml'
      agent.user_agent = 'Mozilla/5.0 (Windows NT 5.2; rv:28.0) Gecko/20100101 Firefox/28.0'

      if File.exist?(cookie_name)
        agent.cookie_jar.load(cookie_name)
      else
        agent.get 'http://login.yahoo.co.jp/config/login?.lg=jp&.intl=jp&logout=1&.src=www&.done=http://www.yahoo.co.jp'

        sleep 2
        agent.get 'https://login.yahoo.co.jp/config/login?.src=www&.done=http://www.yahoo.co.jp'
        agent.page.form_with(name: 'login_form') do |form|
          form.field_with(name: 'login').value = config['yahoo_id']
          form.field_with(name: 'passwd').value = config['yahoo_password']
          agent.page.body =~ /\("\.albatross"\)\[0\]\.value = "(.*)"/
          form.field_with(name: '.albatross').value = Regexp.last_match(1)
          form.click_button
        end
        agent.cookie_jar.save_as(cookie_name)
      end

      sleep 2
    end

  else
    nil
  end
end

agent = init_agent(config)
puts 'initialized agent'

# generate Query for google Image Search
def gen_crawl_uri(kw, config)
  case config['provider']
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

    # 顔検索フラグ
    query_hash['tbs'] = 'itp:face' if config['detect_face']

  when 'yahoo'
    host = 'http://image.search.yahoo.co.jp/search?'
    query_hash = {
      p: URI.escape(kw), oq: '', ei: 'UTF-8',
      # 顔写真用のフラグ
      # ctype: 'face',
      rkf: 1, imw: 0, imh: 0, imt: '', dim: '', imcolor: ''
    }

    # 顔検索フラグ
    query_hash['ctype'] = 'face' if config['detect_face']
  end

  host + query_hash.map { |k, v| "#{k}=#{v}" }.join('&')
end

def http_request(uri, provider, agent)
  case provider
  when 'yahoo'
    agent.get uri
    agent.page.body

  when 'google'
    uri_parsed = URI.parse(uri)
    http = Net::HTTP.new(uri_parsed.host, uri_parsed.port)

    if uri_parsed.port == 443
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    # http.set_debug_output $stderr
    http.get(uri).body
    # File.write('debug.html', body)
  end
end

# e.g. save_dir/md5(url).jpg
def download_file(uri, save_dir, filename)
  # TODO: 画像の種類判別して拡張しつける
  filename = save_dir + filename + '.jpg'

  # すでにファイルがあるならスキップ
  if File.exist?(filename)
    puts '[duplicate]' + uri
    return true
  end

  begin
    uri_parsed = URI.parse(uri)
    http = Net::HTTP.new(uri_parsed.host, uri_parsed.port)

    http.read_timeout = 10
    http.open_timeout = 10

    if uri_parsed.port == 443
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    # res = Net::HTTP.get_response(uri_parsed)
    res = http.get(uri)
  rescue => e
    puts '[Error]' + e.message
    puts '  => ' + uri
    return false
  end

  if res.code.to_i == 200
    open(filename, 'wb') do |file|
      file.puts res.body
    end
    printf('[save]"%s" as %s' + "\n", uri, filename)
    return true
  else
    printf('[status:%s]skip "%s"' + "\n", res.code, uri)
    return false
  end
end

def get_image_urls(kw, config, agent)
  puts '[reserve]' + kw

  doc = Nokogiri::HTML.parse(http_request(gen_crawl_uri(kw, config), config['provider'], agent))
  case config['provider']
  when 'google'
    target_parent = 'a img'
    target_attr = 'src'
  when 'yahoo'
    target_parent = '.tb a'
    target_attr = 'href'
  end

  list = []
  doc.css(target_parent).each do |node|
    uri = node.attribute(target_attr).value

    if config['provider'] == 'yahoo'
      fake_uri = uri.split('**')
      uri = URI.decode(fake_uri[1])
    end

    list.push(uri) if uri != ''
  end

  list
end

Dir.mkdir(config['save_dir']) unless File.directory?(config['save_dir'])

until File.exist?(config['target_file'])
  puts 'plz set search_keyword.txt'
  exit
end

# 検索用キーワードから画像リストを生成し、バッファしとく
seeq_file = Enumerator.new do |uri|
  File.foreach(config['target_file']) do |search_kw|
    get_image_urls(search_kw.chomp!, config, agent).each { | img_uri | uri << img_uri }
  end
end

# download que
job_que = Queue.new
seeq_thread = []
threads = []

# ファイルのロードを行い、画像のURLを生成する
is_file_loaded = false
seeq_thread << Thread.start do
  seeq_file.each { | uri | job_que.push(uri: uri) }
  puts '[file_seeq] load ended'
  is_file_loaded = true
end

# スレッド[seeq_thread]が終わった時の処理を入れないと

puts '[file_seeq] buffering 5 sec'
sleep 5

# seeqのスレッドが生きてるか確認

# マルチスレッドでダウンロード
# XXX: thread生存分だけ多くDLしてくる 足がでた画像を消してもいいが特に必要性はないのでこのままで
# countをatomicに管理する必要があるかもしれないが、やはりクリティカルじゃないのでそのままで
count = 0

# ファイルのロード中ならスレッド生成機構を止めない
loop do
  puts '[loop-start]is_file_loaded:' + is_file_loaded.to_s

  config['thread_max'].times do
    threads << Thread.start do
      until job_que.empty?
        info = job_que.pop

        count += 1 if download_file(info[:uri], config['save_dir'], Digest::MD5.hexdigest(info[:uri]))
        sleep 2

        puts '[counter]' + count.to_s

        # つくったけど必要ないのでコメントアウト
        # exit if count > config['download_limit'] - config['thread_max']
      end
    end
  end
  threads.each { |t| t.join }

  puts '[loop-end]is_file_loaded:' + is_file_loaded.to_s
  break if is_file_loaded
end

puts 'completed'
