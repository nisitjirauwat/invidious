
def update_decrypt_function
  loop do
    begin
      decrypt_function = fetch_decrypt_function
      yield decrypt_function
    rescue ex
      # TODO: Log error
      next
    ensure
      sleep 1.minute
      Fiber.yield
    end
  end
end

def find_working_proxies(regions)
  loop do
    regions.each do |region|
      proxies = get_proxies(region).first(20)
      proxies = proxies.map { |proxy| {ip: proxy[:ip], port: proxy[:port]} }
      # proxies = filter_proxies(proxies)

      yield region, proxies
    end

    sleep 1.minute
    Fiber.yield
  end
end
