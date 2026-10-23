require "test_helper"

class Provider::UnisuperTest < ActiveSupport::TestCase
  PERFORMANCE_URL = "https://www.unisuper.com.au/api/sitecore/investment/GetInvestmentPerformance".freeze

  setup do
    travel_to Time.zone.local(2026, 10, 23, 12)
    @provider = Provider::Unisuper.new
    @provider.stubs(:throttle_request)
  end

  # ================================
  #            Search
  # ================================

  test "search_securities finds every series of an option by name without a request" do
    response = @provider.search_securities("high growth")

    assert response.success?
    assert_equal %w[
      UNISUPER-SUSTAINABLE-HIGH-GROWTH
      UNISUPER-HIGH-GROWTH
      UNISUPER-PENSION-SUSTAINABLE-HIGH-GROWTH
      UNISUPER-PENSION-HIGH-GROWTH
    ], response.data.map(&:symbol)

    security = response.data.find { |s| s.symbol == "UNISUPER-PENSION-HIGH-GROWTH" }
    assert_equal "UniSuper High Growth (Pension)", security.name
    assert_equal "XXXX", security.exchange_operating_mic
    assert_equal "AU", security.country_code
    assert_equal "AUD", security.currency
    assert_not_requested :get, /unisuper\.com\.au/
  end

  test "search_securities resolves an exact ticker to that option" do
    response = @provider.search_securities("unisuper-pension-balanced")

    assert_equal [ "UNISUPER-PENSION-BALANCED" ], response.data.map(&:symbol)
  end

  test "search_securities ignores short queries and other exchanges" do
    assert_empty @provider.search_securities("ba").data
    assert_empty @provider.search_securities("balanced", exchange_operating_mic: "XASX").data
    # Conservative Balanced, Balanced and Sustainable Balanced, in both series.
    assert_equal 6, @provider.search_securities("balanced", exchange_operating_mic: "xxxx").data.size
  end

  # ================================
  #            Prices
  # ================================

  test "fetch_security_prices rebases the index to 100 at the option's launch" do
    stub = stub_series(pre_tax: false, rows: [
      series_row(8, "High Growth", "2003-12-01" => 1.0, "2026-10-19" => 8.0, "2026-10-20" => 8.08, "2026-10-21" => 8.0766)
    ])

    response = @provider.fetch_security_prices(
      symbol: "UNISUPER-HIGH-GROWTH",
      exchange_operating_mic: "XXXX",
      start_date: Date.new(2026, 10, 20),
      end_date: Date.new(2026, 10, 21)
    )

    assert response.success?
    assert_equal [ Date.new(2026, 10, 20), Date.new(2026, 10, 21) ], response.data.map(&:date)
    assert_equal [ BigDecimal("808"), BigDecimal("807.66") ], response.data.map(&:price)
    assert_equal [ "AUD" ], response.data.map(&:currency).uniq
    assert_equal [ "XXXX" ], response.data.map(&:exchange_operating_mic).uniq
    assert_requested stub
  end

  test "prices don't depend on the index's starting value" do
    stub_series(pre_tax: false, rows: [
      series_row(12, "International Shares", "2008-06-30" => 2.0, "2026-10-21" => 11.0668)
    ])

    response = @provider.fetch_security_prices(
      symbol: "UNISUPER-INTERNATIONAL-SHARES", start_date: Date.new(2008, 6, 30), end_date: Date.new(2026, 10, 21)
    )

    assert_equal [ BigDecimal("100"), BigDecimal("553.34") ], response.data.map(&:price)
  end

  test "pension tickers read UniSuper's pre-tax series" do
    stub_series(pre_tax: true, rows: [
      series_row(4, "Balanced", "2003-12-01" => 1.0, "2026-10-21" => 7.1479)
    ])

    response = @provider.fetch_security_price(symbol: "UNISUPER-PENSION-BALANCED", exchange_operating_mic: "XXXX", date: Date.new(2026, 10, 21))

    assert response.success?
    assert_equal BigDecimal("714.79"), response.data.price
  end

  test "fetch_security_price returns the latest price on or before the date" do
    stub_series(pre_tax: false, rows: [
      series_row(4, "Balanced", "2003-12-01" => 1.0, "2026-10-16" => 5.9, "2026-10-21" => 5.95)
    ])

    weekend = @provider.fetch_security_price(symbol: "UNISUPER-BALANCED", exchange_operating_mic: "XXXX", date: Date.new(2026, 10, 25))
    assert_equal Date.new(2026, 10, 21), weekend.data.date
    assert_equal BigDecimal("595"), weekend.data.price

    between = @provider.fetch_security_price(symbol: "UNISUPER-BALANCED", exchange_operating_mic: "XXXX", date: Date.new(2026, 10, 18))
    assert_equal Date.new(2026, 10, 16), between.data.date
  end

  test "fetch_security_price fails beyond the lookback or before launch" do
    stub_series(pre_tax: false, rows: [
      series_row(4, "Balanced", "2003-12-01" => 1.0, "2026-10-21" => 5.95)
    ])

    stale = @provider.fetch_security_price(symbol: "UNISUPER-BALANCED", exchange_operating_mic: "XXXX", date: Date.new(2026, 11, 10))
    assert_not stale.success?
    assert_equal "No UniSuper Balanced price on or within 10 days before 2026-11-10", stale.error.message

    before_launch = @provider.fetch_security_price(symbol: "UNISUPER-BALANCED", exchange_operating_mic: "XXXX", date: Date.new(2003, 1, 1))
    assert_not before_launch.success?
  end

  test "one download serves every option in a series" do
    stub = stub_series(pre_tax: false, rows: [
      series_row(8, "High Growth", "2003-12-01" => 1.0, "2026-10-21" => 8.0766),
      series_row(12, "International Shares", "2008-06-30" => 1.0, "2026-10-21" => 5.5334)
    ])
    range = { start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 21) }

    assert @provider.fetch_security_prices(symbol: "UNISUPER-HIGH-GROWTH", **range).success?
    assert @provider.fetch_security_prices(symbol: "UNISUPER-INTERNATIONAL-SHARES", **range).success?
    assert @provider.fetch_security_price(symbol: "UNISUPER-HIGH-GROWTH", exchange_operating_mic: "XXXX", date: Date.new(2026, 10, 21)).success?

    assert_requested stub, times: 1
  end

  test "a bot-protection page instead of JSON is a clear error" do
    stub_request(:get, PERFORMANCE_URL)
      .with(query: hash_including("isPreTax" => "false"))
      .to_return(status: 200, headers: { "Content-Type" => "text/html" }, body: "<html>Pardon Our Interruption</html>")

    response = @provider.fetch_security_prices(symbol: "UNISUPER-BALANCED", start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 21))

    assert_not response.success?
    assert_match "text/html instead of JSON", response.error.message
  end

  test "an option missing from the response is an error" do
    stub_series(pre_tax: false, rows: [ series_row(8, "High Growth", "2003-12-01" => 1.0) ])

    response = @provider.fetch_security_prices(symbol: "UNISUPER-CASH", start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 21))

    assert_not response.success?
    assert_equal "No returns published for UniSuper Cash", response.error.message
  end

  test "tickers from other providers are rejected without a request" do
    response = @provider.fetch_security_prices(symbol: "VAS", start_date: Date.new(2026, 10, 1), end_date: Date.new(2026, 10, 21))

    assert_not response.success?
    assert_match "is not a UniSuper investment option", response.error.message
    assert_not_requested :get, /unisuper\.com\.au/
  end

  # ================================
  #        Info, health, registry
  # ================================

  test "fetch_security_info describes the option" do
    info = @provider.fetch_security_info(symbol: "UNISUPER-PENSION-GROWTH", exchange_operating_mic: "XXXX").data

    assert_equal "UniSuper Growth (Pension)", info.name
    assert_equal Provider::Unisuper::INFO_URL, info.links
    assert_match "pre-tax", info.description
  end

  test "healthy? asks for a few days of returns" do
    stub_request(:get, PERFORMANCE_URL)
      .with(query: { "dateId" => "3", "isPreTax" => "false" })
      .to_return(status: 200, headers: json_headers, body: { "Series" => [ series_row(4, "Balanced", "2026-10-21" => 1.0) ] }.to_json)

    assert @provider.healthy?.data
  end

  test "is registered as a keyless securities provider" do
    assert_includes Provider::Registry.for_concept(:securities).provider_keys, :unisuper
    assert_kind_of Provider::Unisuper, Provider::Registry.for_concept(:securities).get_provider(:unisuper)
    assert_includes Security.valid_price_providers, "unisuper"
  end

  private

    def stub_series(pre_tax:, rows:)
      days = (Date.current - Provider::Unisuper::HISTORY_START).to_i

      stub_request(:get, PERFORMANCE_URL)
        .with(query: { "dateId" => days.to_s, "isPreTax" => pre_tax.to_s })
        .to_return(status: 200, headers: json_headers, body: { "Series" => rows }.to_json)
    end

    def series_row(id, title, points)
      {
        "InvestmentOptionId" => id,
        "InvestmentOptionTitle" => title,
        "Data" => points.map { |date, value| { "Category" => date, "Value" => value } }
      }
    end

    def json_headers
      { "Content-Type" => "application/json; charset=utf-8" }
    end
end
