# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2019  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"
require "kemal"
require "openssl/hmac"
require "option_parser"
require "sqlite3"
require "xml"
require "yaml"
require "compress/zip"
require "protodec/utils"
require "./invidious/helpers/*"
require "./invidious/*"

ENV_CONFIG_NAME = "INVIDIOUS_CONFIG"

CONFIG_STR = ENV.has_key?(ENV_CONFIG_NAME) ? ENV.fetch(ENV_CONFIG_NAME) : File.read("config/config.yml")
CONFIG     = Config.from_yaml(CONFIG_STR)
HMAC_KEY   = CONFIG.hmac_key || Random::Secure.hex(32)

YT_URL          = URI.parse("https://www.youtube.com")
HOST_URL        = make_host_url(CONFIG, Kemal.config)

MAX_ITEMS_PER_PAGE = 1500

RESPONSE_HEADERS_BLACKLIST = {"access-control-allow-origin", "alt-svc", "server"}
HTTP_CHUNK_SIZE            = 10485760 # ~10MB

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git describe --tags --abbrev=0`.strip}" }}

# This is used to determine the `?v=` on the end of file URLs (for cache busting). We
# only need to expire modified assets, so we can use this to find the last commit that changes
# any assets

SOFTWARE = {
  "name"    => "invidious",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

LOCALES = {
  "ar"    => load_locale("ar"),
  "de"    => load_locale("de"),
  "el"    => load_locale("el"),
  "en-US" => load_locale("en-US"),
  "eo"    => load_locale("eo"),
  "es"    => load_locale("es"),
  "eu"    => load_locale("eu"),
  "fr"    => load_locale("fr"),
  "hu"    => load_locale("hu-HU"),
  "is"    => load_locale("is"),
  "it"    => load_locale("it"),
  "ja"    => load_locale("ja"),
  "nb-NO" => load_locale("nb-NO"),
  "nl"    => load_locale("nl"),
  "pl"    => load_locale("pl"),
  "pt-BR" => load_locale("pt-BR"),
  "pt-PT" => load_locale("pt-PT"),
  "ro"    => load_locale("ro"),
  "ru"    => load_locale("ru"),
  "sv"    => load_locale("sv-SE"),
  "tr"    => load_locale("tr"),
  "uk"    => load_locale("uk"),
  "zh-CN" => load_locale("zh-CN"),
  "zh-TW" => load_locale("zh-TW"),
}

YT_POOL = QUICPool.new(YT_URL, capacity: CONFIG.pool_size, timeout: 0.1)

config = CONFIG
logger = Invidious::LogHandler.new

Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-c THREADS", "--channel-threads=THREADS", "Number of threads for refreshing channels (default: #{config.channel_threads})") do |number|
    begin
      config.channel_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-f THREADS", "--feed-threads=THREADS", "Number of threads for refreshing feeds (default: #{config.feed_threads})") do |number|
    begin
      config.feed_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-o OUTPUT", "--output=OUTPUT", "Redirect output (default: STDOUT)") do |output|
    FileUtils.mkdir_p(File.dirname(output))
    logger = Invidious::LogHandler.new(File.open(output, mode: "a"))
  end
  parser.on("-v", "--version", "Print version") do |output|
    puts SOFTWARE.to_pretty_json
    exit
  end
end

Kemal::CLI.new ARGV

# Start jobs

DECRYPT_FUNCTION = [] of {SigProc, Int32}
spawn do
  update_decrypt_function do |function|
    DECRYPT_FUNCTION.clear
    function.each { |i| DECRYPT_FUNCTION << i }
  end
end

before_all do |env|
  begin
    preferences = Preferences.from_json(env.request.cookies["PREFS"]?.try &.value || "{}")
  rescue
    preferences = Preferences.from_json("{}")
  end

  env.response.headers["X-XSS-Protection"] = "1; mode=block"
  env.response.headers["X-Content-Type-Options"] = "nosniff"
  extra_media_csp = ""
  if CONFIG.disabled?("local") || !preferences.local
    extra_media_csp += " https://*.googlevideo.com:443"
  end
  # TODO: Remove style-src's 'unsafe-inline', requires to remove all inline styles (<style> [..] </style>, style=" [..] ")
  env.response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; manifest-src 'self'; media-src 'self' blob:#{extra_media_csp}"
  env.response.headers["Referrer-Policy"] = "same-origin"

  dark_mode = convert_theme(env.params.query["dark_mode"]?) || preferences.dark_mode.to_s
  thin_mode = env.params.query["thin_mode"]? || preferences.thin_mode.to_s
  thin_mode = thin_mode == "true"
  locale = env.params.query["hl"]? || preferences.locale

  preferences.dark_mode = dark_mode
  preferences.thin_mode = thin_mode
  preferences.locale = locale
  env.set "preferences", preferences

  current_page = env.request.path
  if env.request.query
    query = HTTP::Params.parse(env.request.query.not_nil!)

    if query["referer"]?
      query["referer"] = get_referer(env, "/")
    end

    current_page += "?#{query}"
  end

  env.set "current_page", URI.encode_www_form(current_page)
end

get "/" do |env|
  preferences = env.get("preferences").as(Preferences)
  locale = LOCALES[preferences.locale]?
  user = env.get? "user"

  templated "empty"
end

# Videos

get "/api/v1/videos/:id" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  id = env.params.url["id"]
  region = env.params.query["region"]?

  begin
    video = get_video(id, region: region)
  rescue ex : VideoRedirect
    error_message = {"error" => "Video is unavailable", "videoId" => ex.video_id}.to_json
    env.response.status_code = 302
    env.response.headers["Location"] = env.request.resource.gsub(id, ex.video_id)
    next error_message
  rescue ex
    error_message = {"error" => ex.message}.to_json
    env.response.status_code = 500
    next error_message
  end

  video.to_json(locale)
end

get "/api/v1/search" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  region = env.params.query["region"]?

  env.response.content_type = "application/json"

  query = env.params.query["q"]?
  query ||= ""

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  sort_by = env.params.query["sort_by"]?.try &.downcase
  sort_by ||= "relevance"

  date = env.params.query["date"]?.try &.downcase
  date ||= ""

  duration = env.params.query["duration"]?.try &.downcase
  duration ||= ""

  features = env.params.query["features"]?.try &.split(",").map { |feature| feature.downcase }
  features ||= [] of String

  content_type = env.params.query["type"]?.try &.downcase
  content_type ||= "video"

  begin
    search_params = produce_search_params(sort_by, date, content_type, duration, features)
  rescue ex
    env.response.status_code = 400
    error_message = {"error" => ex.message}.to_json
    next error_message
  end

  count, search_results = search(query, page, search_params, region).as(Tuple)
  JSON.build do |json|
    json.array do
      search_results.each do |item|
        item.to_json(locale, json)
      end
    end
  end
end

error 404 do |env|
  if md = env.request.path.match(/^\/(?<id>([a-zA-Z0-9_-]{11})|(\w+))$/)
    item = md["id"]

    # Check if item is branding URL e.g. https://youtube.com/gaming
    response = YT_POOL.client &.get("/#{item}")

    if response.status_code == 301
      response = YT_POOL.client &.get(URI.parse(response.headers["Location"]).full_path)
    end

    if response.body.empty?
      env.response.headers["Location"] = "/"
      halt env, status_code: 302
    end

    html = XML.parse_html(response.body)
    ucid = html.xpath_node(%q(//link[@rel="canonical"])).try &.["href"].split("/")[-1]

    if ucid
      env.response.headers["Location"] = "/channel/#{ucid}"
      halt env, status_code: 302
    end

    params = [] of String
    env.params.query.each do |k, v|
      params << "#{k}=#{v}"
    end
    params = params.join("&")

    url = "/watch?v=#{item}"
    if !params.empty?
      url += "&#{params}"
    end

    # Check if item is video ID
    if item.match(/^[a-zA-Z0-9_-]{11}$/) && YT_POOL.client &.head("/watch?v=#{item}").status_code != 404
      env.response.headers["Location"] = url
      halt env, status_code: 302
    end
  end

  env.response.headers["Location"] = "/"
  halt env, status_code: 302
end

error 500 do |env|
  error_message = <<-END_HTML
  Looks like you've found a bug in Invidious. Feel free to open a new issue
  <a href="https://github.com/omarroth/invidious/issues">here</a>
  or send an email to
  <a href="mailto:#{CONFIG.admin_email}">#{CONFIG.admin_email}</a>.
  END_HTML
  templated "error"
end

Kemal.config.powered_by_header = false
add_handler FilteredCompressHandler.new
add_handler APIHandler.new
add_handler DenyFrame.new
add_context_storage_type(Array(String))
add_context_storage_type(Preferences)

Kemal.config.logger = logger
Kemal.config.host_binding = Kemal.config.host_binding != "0.0.0.0" ? Kemal.config.host_binding : CONFIG.host_binding
Kemal.config.port = Kemal.config.port != 3000 ? Kemal.config.port : CONFIG.port
Kemal.run
