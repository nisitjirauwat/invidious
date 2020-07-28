struct SearchVideo
  include DB::Serializable

  property title : String
  property id : String
  property author : String
  property ucid : String
  property published : Time
  property views : Int64
  property description_html : String
  property length_seconds : Int32
  property live_now : Bool
  property paid : Bool
  property premium : Bool
  property premiere_timestamp : Time?

  def to_xml(auto_generated, query_params, xml : XML::Builder)
    query_params["v"] = self.id

    xml.element("entry") do
      xml.element("id") { xml.text "yt:video:#{self.id}" }
      xml.element("yt:videoId") { xml.text self.id }
      xml.element("yt:channelId") { xml.text self.ucid }
      xml.element("title") { xml.text self.title }
      xml.element("link", rel: "alternate", href: "#{HOST_URL}/watch?#{query_params}")

      xml.element("author") do
        if auto_generated
          xml.element("name") { xml.text self.author }
          xml.element("uri") { xml.text "#{HOST_URL}/channel/#{self.ucid}" }
        else
          xml.element("name") { xml.text author }
          xml.element("uri") { xml.text "#{HOST_URL}/channel/#{ucid}" }
        end
      end

      xml.element("content", type: "xhtml") do
        xml.element("div", xmlns: "http://www.w3.org/1999/xhtml") do
          xml.element("a", href: "#{HOST_URL}/watch?#{query_params}") do
            xml.element("img", src: "#{HOST_URL}/vi/#{self.id}/mqdefault.jpg")
          end

          xml.element("p", style: "word-break:break-word;white-space:pre-wrap") { xml.text html_to_content(self.description_html) }
        end
      end

      xml.element("published") { xml.text self.published.to_s("%Y-%m-%dT%H:%M:%S%:z") }

      xml.element("media:group") do
        xml.element("media:title") { xml.text self.title }
        xml.element("media:thumbnail", url: "#{HOST_URL}/vi/#{self.id}/mqdefault.jpg",
          width: "320", height: "180")
        xml.element("media:description") { xml.text html_to_content(self.description_html) }
      end

      xml.element("media:community") do
        xml.element("media:statistics", views: self.views)
      end
    end
  end

  def to_xml(auto_generated, query_params, xml : XML::Builder | Nil = nil)
    if xml
      to_xml(HOST_URL, auto_generated, query_params, xml)
    else
      XML.build do |json|
        to_xml(HOST_URL, auto_generated, query_params, xml)
      end
    end
  end

  def to_json(locale, json : JSON::Builder)
    json.object do
      json.field "type", "video"
      json.field "title", self.title
      json.field "videoId", self.id

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", "/channel/#{self.ucid}"

      json.field "videoThumbnails" do
        generate_thumbnails(json, self.id)
      end

      json.field "description", html_to_content(self.description_html)
      json.field "descriptionHtml", self.description_html

      json.field "viewCount", self.views
      json.field "published", self.published.to_unix
      json.field "publishedText", translate(locale, "`x` ago", recode_date(self.published, locale))
      json.field "lengthSeconds", self.length_seconds
      json.field "liveNow", self.live_now
      json.field "paid", self.paid
      json.field "premium", self.premium
      json.field "isUpcoming", self.is_upcoming

      if self.premiere_timestamp
        json.field "premiereTimestamp", self.premiere_timestamp.try &.to_unix
      end
    end
  end

  def to_json(locale, json : JSON::Builder | Nil = nil)
    if json
      to_json(locale, json)
    else
      JSON.build do |json|
        to_json(locale, json)
      end
    end
  end

  def is_upcoming
    premiere_timestamp ? true : false
  end
end


alias SearchItem = SearchVideo

def search(query, page = 1, search_params = produce_search_params(content_type: "all"), region = nil)
  return 0, [] of SearchItem if query.empty?

  body = YT_POOL.client(region, &.get("/results?q=#{URI.encode_www_form(query)}&page=#{page}&sp=#{search_params}&hl=en").body)
  return 0, [] of SearchItem if body.empty?

  initial_data = extract_initial_data(body)
  items = extract_items(initial_data)

  # initial_data["estimatedResults"]?.try &.as_s.to_i64

  return items.size, items
end

def produce_search_params(sort : String = "relevance", date : String = "", content_type : String = "",
                          duration : String = "", features : Array(String) = [] of String)
  object = {
    "1:varint"   => 0_i64,
    "2:embedded" => {} of String => Int64,
  }

  case sort
  when "relevance"
    object["1:varint"] = 0_i64
  when "rating"
    object["1:varint"] = 1_i64
  when "upload_date", "date"
    object["1:varint"] = 2_i64
  when "view_count", "views"
    object["1:varint"] = 3_i64
  else
    raise "No sort #{sort}"
  end

  case date
  when "hour"
    object["2:embedded"].as(Hash)["1:varint"] = 1_i64
  when "today"
    object["2:embedded"].as(Hash)["1:varint"] = 2_i64
  when "week"
    object["2:embedded"].as(Hash)["1:varint"] = 3_i64
  when "month"
    object["2:embedded"].as(Hash)["1:varint"] = 4_i64
  when "year"
    object["2:embedded"].as(Hash)["1:varint"] = 5_i64
  else nil # Ignore
  end

  case content_type
  when "video"
    object["2:embedded"].as(Hash)["2:varint"] = 1_i64
  when "channel"
    object["2:embedded"].as(Hash)["2:varint"] = 2_i64
  when "playlist"
    object["2:embedded"].as(Hash)["2:varint"] = 3_i64
  when "movie"
    object["2:embedded"].as(Hash)["2:varint"] = 4_i64
  when "show"
    object["2:embedded"].as(Hash)["2:varint"] = 5_i64
  when "all"
    #
  else
    object["2:embedded"].as(Hash)["2:varint"] = 1_i64
  end

  case duration
  when "short"
    object["2:embedded"].as(Hash)["3:varint"] = 1_i64
  when "long"
    object["2:embedded"].as(Hash)["3:varint"] = 2_i64
  else nil # Ignore
  end

  features.each do |feature|
    case feature
    when "hd"
      object["2:embedded"].as(Hash)["4:varint"] = 1_i64
    when "subtitles"
      object["2:embedded"].as(Hash)["5:varint"] = 1_i64
    when "creative_commons", "cc"
      object["2:embedded"].as(Hash)["6:varint"] = 1_i64
    when "3d"
      object["2:embedded"].as(Hash)["7:varint"] = 1_i64
    when "live", "livestream"
      object["2:embedded"].as(Hash)["8:varint"] = 1_i64
    when "purchased"
      object["2:embedded"].as(Hash)["9:varint"] = 1_i64
    when "4k"
      object["2:embedded"].as(Hash)["14:varint"] = 1_i64
    when "360"
      object["2:embedded"].as(Hash)["15:varint"] = 1_i64
    when "location"
      object["2:embedded"].as(Hash)["23:varint"] = 1_i64
    when "hdr"
      object["2:embedded"].as(Hash)["25:varint"] = 1_i64
    else nil # Ignore
    end
  end

  if object["2:embedded"].as(Hash).empty?
    object.delete("2:embedded")
  end

  params = object.try { |i| Protodec::Any.cast_json(object) }
    .try { |i| Protodec::Any.from_json(i) }
    .try { |i| Base64.urlsafe_encode(i) }
    .try { |i| URI.encode_www_form(i) }

  return params
end
