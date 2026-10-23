# Prices for UniSuper's investment options.
#
# UniSuper super and pension accounts don't have units. Returns get credited to
# each option daily, and UniSuper publishes them (no login needed) as a growth
# index per option that starts at 1.0. We rebase that to 100 and treat it as a
# daily price, so a balance can be held as balance / price units.
#
# One request brings back every option's full history (~6 MB), so it's cached.
class Provider::Unisuper < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 1.0

  PERFORMANCE_PATH = "/api/sitecore/investment/GetInvestmentPerformance".freeze
  INFO_URL = "https://www.unisuper.com.au/investments/our-investment-options".freeze

  # "No market" in ISO 10383. These options aren't listed anywhere.
  MIC = "XXXX".freeze
  COUNTRY = "AU".freeze
  CURRENCY = "AUD".freeze

  # Prices are stored to 4 decimal places, which loses most of an index that
  # sits around 1.0, so we rebase to 100.
  PRICE_BASE = 100

  # The data starts on 1 Dec 2003. Always asking from before that keeps the
  # first point the same, so the rebased prices don't move between fetches.
  HISTORY_START = Date.new(2003, 11, 1)

  # How far back a single-day lookup can go: weekends, public holidays, and
  # UniSuper usually being a day behind.
  LOOKBACK_DAYS = 10

  CACHE_TTL = 6.hours

  # Keyed by UniSuper's option id, so a ticker survives a rename.
  OPTIONS = {
    1 => { slug: "CASH", name: "Cash" },
    2 => { slug: "CONSERVATIVE", name: "Conservative" },
    3 => { slug: "CONSERVATIVE-BALANCED", name: "Conservative Balanced" },
    4 => { slug: "BALANCED", name: "Balanced" },
    5 => { slug: "SUSTAINABLE-BALANCED", name: "Sustainable Balanced" },
    6 => { slug: "GROWTH", name: "Growth" },
    7 => { slug: "SUSTAINABLE-HIGH-GROWTH", name: "Sustainable High Growth" },
    8 => { slug: "HIGH-GROWTH", name: "High Growth" },
    9 => { slug: "AUSTRALIAN-BOND", name: "Australian Bond" },
    10 => { slug: "LISTED-PROPERTY", name: "Listed Property" },
    11 => { slug: "AUSTRALIAN-SHARES", name: "Australian Shares" },
    12 => { slug: "INTERNATIONAL-SHARES", name: "International Shares" },
    13 => { slug: "GLOBAL-ENVIRONMENTAL-OPPORTUNITIES", name: "Global Environmental Opportunities" },
    14 => { slug: "AUSTRALIAN-DIVIDEND-INCOME", name: "Australian Dividend Income" },
    15 => { slug: "GLOBAL-COMPANIES-IN-ASIA", name: "Global Companies in Asia" },
    16 => { slug: "AUSTRALIAN-INCOME", name: "Australian Income" }
  }.freeze

  # Super returns are after investment tax. Pension returns aren't taxed, so
  # they come as a separate pre-tax series.
  SERIES = {
    super: { pre_tax: false, ticker_prefix: "UNISUPER-", name_suffix: nil },
    pension: { pre_tax: true, ticker_prefix: "UNISUPER-PENSION-", name_suffix: " (Pension)" }
  }.freeze

  class << self
    # Option names the way UniSuper's statements and exports spell them.
    def option_names
      OPTIONS.values.map { |option| option[:name] }
    end

    # The ticker for an option name like "High Growth" (nil if it isn't one).
    def ticker_for(option_name, pension: false)
      option = OPTIONS.values.find { |candidate| candidate[:name].casecmp?(option_name.to_s.strip) }
      return if option.nil?

      "#{SERIES.fetch(pension ? :pension : :super)[:ticker_prefix]}#{option[:slug]}"
    end
  end

  def initialize
    # Public data, no API key.
  end

  def healthy?
    with_provider_response do
      response = client.get(PERFORMANCE_PATH, { dateId: 3, isPreTax: false })
      parse_json!(response)["Series"].present?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  # ================================
  #           Securities
  # ================================

  # Searches the fixed list of options, so it never hits the network.
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = normalize(symbol)
      next [] if query.length < 3
      next [] if exchange_operating_mic.present? && exchange_operating_mic.to_s.upcase != MIC

      catalogue
        .select { |option| normalize(option[:ticker]).include?(query) || normalize(option[:name]).include?(query) }
        .map do |option|
          Security.new(
            symbol: option[:ticker],
            name: option[:name],
            logo_url: nil,
            exchange_operating_mic: MIC,
            country_code: COUNTRY,
            currency: CURRENCY
          )
        end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      option = option_for!(symbol)

      SecurityInfo.new(
        symbol: option[:ticker],
        name: option[:name],
        links: INFO_URL,
        logo_url: nil,
        description: description_for(option),
        kind: "superannuation option",
        exchange_operating_mic: MIC
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      option = option_for!(symbol)
      earliest = date - LOOKBACK_DAYS.days
      point_date, price = price_points(option).reverse_each.find { |day, _| day <= date }

      if point_date.nil? || point_date < earliest
        raise InvalidSecurityPriceError, "No #{option[:name]} price on or within #{LOOKBACK_DAYS} days before #{date}"
      end

      Price.new(symbol: option[:ticker], date: point_date, price: price, currency: CURRENCY, exchange_operating_mic: MIC)
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      option = option_for!(symbol)

      price_points(option).filter_map do |day, price|
        next unless day.between?(start_date, end_date)

        Price.new(symbol: option[:ticker], date: day, price: price, currency: CURRENCY, exchange_operating_mic: MIC)
      end
    end
  end

  private

    def base_url
      ENV["UNISUPER_URL"] || "https://www.unisuper.com.au"
    end

    def client
      @client ||= Faraday.new(url: base_url, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"
      end
    end

    # throttle_request and min_request_interval come from RateLimitable

    def catalogue
      @catalogue ||= SERIES.flat_map do |series, config|
        OPTIONS.map do |id, option|
          {
            id: id,
            series: series,
            ticker: "#{config[:ticker_prefix]}#{option[:slug]}",
            name: "UniSuper #{option[:name]}#{config[:name_suffix]}"
          }
        end
      end
    end

    def option_for!(symbol)
      ticker = symbol.to_s.strip.upcase
      catalogue.find { |option| option[:ticker] == ticker } ||
        raise(InvalidSecurityPriceError, "#{symbol} is not a UniSuper investment option")
    end

    def description_for(option)
      if option[:series] == :pension
        "UniSuper pension investment option. Prices index UniSuper's published daily returns (pre-tax) to 100 at the option's launch; they aren't a unit price."
      else
        "UniSuper accumulation investment option. Prices index UniSuper's published daily returns (after investment tax) to 100 at the option's launch; they aren't a unit price."
      end
    end

    # [[Date, price], ...] oldest first, with the first point at PRICE_BASE.
    def price_points(option)
      @price_points ||= {}
      @price_points[[ option[:series], option[:id] ]] ||= begin
        points = series_data(option[:series])[option[:id]]
        raise InvalidSecurityPriceError, "No returns published for #{option[:name]}" if points.blank?

        base = BigDecimal(points.first.last)
        points.map { |day, value| [ Date.iso8601(day), (BigDecimal(value) / base * PRICE_BASE).round(4) ] }
      end
    end

    # { option id => [[iso date, value], ...] }, cached so every instance shares it.
    def series_data(series)
      @series_data ||= {}
      @series_data[series] ||= Rails.cache.fetch("unisuper:series:#{series}:#{Date.current.iso8601}", expires_in: CACHE_TTL) do
        download_series(series)
      end
    end

    def download_series(series)
      throttle_request
      response = client.get(PERFORMANCE_PATH) do |req|
        req.params["dateId"] = (Date.current - HISTORY_START).to_i
        req.params["isPreTax"] = SERIES.fetch(series)[:pre_tax].to_s
      end

      rows = parse_json!(response)["Series"]
      raise Error, "UniSuper returned no investment options" unless rows.is_a?(Array) && rows.any?

      rows.to_h do |row|
        points = Array(row["Data"]).filter_map do |point|
          next if point["Value"].nil? || point["Category"].blank?

          [ point["Category"].to_s.first(10), point["Value"].to_s ]
        end

        [ row["InvestmentOptionId"].to_i, points.sort_by(&:first) ]
      end
    end

    # UniSuper's behind a bot-protection CDN. When it blocks us it sends back an
    # HTML challenge page with a 200, so check the content type.
    def parse_json!(response)
      content_type = response.headers["content-type"].to_s
      unless content_type.include?("json")
        raise Error, "UniSuper returned #{content_type.presence || 'an unknown content type'} instead of JSON"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "UniSuper returned invalid JSON: #{e.message}"
    end

    def normalize(value)
      value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end
end
