require "test_helper"

class UnisuperImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  # A fake Provider::Unisuper with fixed daily prices.
  class FakeProvider
    attr_reader :requested

    def initialize(prices)
      @prices = prices
      @requested = []
    end

    def fetch_security_prices(symbol:, exchange_operating_mic:, start_date:, end_date:)
      @requested << symbol
      data = @prices.fetch(symbol).filter_map do |date, price|
        next unless date.between?(start_date, end_date)

        Provider::SecurityConcept::Price.new(symbol: symbol, date: date, price: price, currency: "AUD", exchange_operating_mic: exchange_operating_mic)
      end

      Provider::Response.new(success?: true, data: data, error: nil)
    end
  end

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "UniSuper", balance: 0, currency: "AUD", accountable: Investment.new(subtype: "super"))
    @import = @subject = @family.imports.create!(type: "UnisuperImport")
    @import.update!(
      raw_file_str: file_fixture("imports/unisuper.csv").read,
      account: @account,
      unisuper_allocation: { "High Growth" => "60", "International Shares" => "40" }
    )
    @import.generate_rows_from_csv
    @import.reload

    Setting.securities_providers = "unisuper"
    @provider = use_prices(
      "UNISUPER-HIGH-GROWTH" => ->(date) { date < Date.new(2026, 6, 1) ? 200 : 210 },
      "UNISUPER-INTERNATIONAL-SHARES" => ->(_date) { 100 }
    )
  end

  test "reads the Member Online export with its preset columns" do
    assert_equal "%d/%m/%Y", @import.date_format
    assert_equal 11, @import.rows_count
    assert_not @import.raw_file_str.start_with?("﻿"), "the byte order mark is stripped"
    assert @import.rows.all?(&:valid?)
    assert_equal Date.new(2026, 1, 1)..Date.new(2026, 7, 31), @import.export_period
    assert_equal [ "High Growth", "International Shares" ], @import.allocation_choices
    assert @import.publishable?
  end

  test "dry run counts what publishing will book" do
    assert_equal({ transactions: 6, trades: 12, valuations: 2 }, @import.dry_run)
  end

  test "contributions buy units, costs sell them, and the ledger anchors the balance" do
    @import.publish

    assert @import.reload.complete?, @import.error
    entries = @account.entries.where(import: @import)

    transactions = entries.where(entryable_type: "Transaction").order(:date, :amount)
    assert_equal 6, transactions.count
    first = transactions.first
    assert_equal [ Date.new(2026, 1, 1), BigDecimal("-1000"), "Contribution" ],
                 [ first.date, first.amount, first.entryable.investment_activity_label ]
    fee = transactions.find_by(date: Date.new(2026, 6, 30))
    assert_equal [ BigDecimal("6.80"), "Fee", "Administration Fee + Contribution Tax Adjustment" ],
                 [ fee.amount, fee.entryable.investment_activity_label, fee.name ]

    trades = entries.where(entryable_type: "Trade").includes(entryable: :security)
    assert_equal 12, trades.count
    opening = trades.select { |entry| entry.date == Date.new(2026, 1, 1) }.to_h { |entry| [ entry.entryable.security.ticker, entry.entryable ] }
    assert_equal [ BigDecimal("3"), BigDecimal("200"), "Buy" ], opening["UNISUPER-HIGH-GROWTH"].then { |t| [ t.qty, t.price, t.investment_activity_label ] }
    assert_equal BigDecimal("4"), opening["UNISUPER-INTERNATIONAL-SHARES"].qty

    # The 30 June fee is sold in proportion to value: 724.50 of High Growth, 460.00 of International Shares.
    june_sells = trades.select { |entry| entry.date == Date.new(2026, 6, 30) }.to_h { |entry| [ entry.entryable.security.ticker, entry.amount ] }
    assert_equal({ "UNISUPER-HIGH-GROWTH" => BigDecimal("-4.16"), "UNISUPER-INTERNATIONAL-SHARES" => BigDecimal("-2.64") }, june_sells)

    valuations = entries.where(entryable_type: "Valuation").order(:date).pluck(:date, :amount)
    assert_equal [ [ Date.new(2026, 6, 30), BigDecimal("1193.20") ], [ Date.new(2026, 7, 31), BigDecimal("1288.20") ] ], valuations

    assert_empty entries.where("name LIKE ?", "%Investment Returns%"), "credited returns come from prices, not entries"
  end

  test "every cash movement is matched by trades, so cash stays at zero" do
    @import.publish

    cash_and_trades = @account.entries.where(import: @import).where.not(entryable_type: "Valuation")
    assert_equal BigDecimal("0"), cash_and_trades.sum(:amount)
  end

  test "units are bought at the day's price, split by the contribution strategy" do
    @import.publish

    units = Trade.joins(:entry).where(entries: { import_id: @import.id }).joins(:security).group("securities.ticker").sum(:qty)
    # 3 + 0.45 - 4.16/210 + 60/210 - 9.16/210 for High Growth; 4 + 0.6 - 0.0264 + 0.4 - 0.0584 for International Shares.
    assert_in_delta 3.6722857143, units["UNISUPER-HIGH-GROWTH"].to_f, 1e-9
    assert_in_delta 4.9152, units["UNISUPER-INTERNATIONAL-SHARES"].to_f, 1e-9
  end

  test "refuses to publish without the UniSuper price provider" do
    Setting.securities_providers = "yahoo_finance"

    @import.publish

    assert @import.reload.failed?
    assert_match "UniSuper securities provider", @import.error
    assert_empty @account.entries
  end

  test "refuses to publish while an earlier UniSuper import is in place" do
    @family.imports.create!(type: "UnisuperImport", account: @account, status: :complete)

    @import.publish

    assert @import.reload.failed?
    assert_match "revert that import", @import.error
  end

  test "pension accounts use UniSuper's pension series" do
    @account.accountable.update!(subtype: "pension")
    provider = use_prices(
      "UNISUPER-PENSION-HIGH-GROWTH" => ->(_date) { 200 },
      "UNISUPER-PENSION-INTERNATIONAL-SHARES" => ->(_date) { 100 }
    )

    @import.publish

    assert @import.reload.complete?, @import.error
    assert_equal %w[UNISUPER-PENSION-HIGH-GROWTH UNISUPER-PENSION-INTERNATIONAL-SHARES], provider.requested
  end

  test "revert removes everything the import booked" do
    @import.publish
    assert @account.entries.any?

    @import.revert

    assert @import.reload.pending?
    assert_empty @account.entries.reload
  end

  test "allocation accepts form keys and drops blank or unparseable entries" do
    @import.unisuper_allocation = { "high_growth" => "70", "international_shares" => "30", "balanced" => "", "cash" => "abc" }

    assert_equal({ "High Growth" => BigDecimal("70"), "International Shares" => BigDecimal("30") }, @import.unisuper_allocation)
  end

  test "allocation has to add up to 100% of known options" do
    @import.unisuper_allocation = { "High Growth" => "50", "International Shares" => "40" }
    assert_not @import.valid?
    assert_includes @import.errors.full_messages, "Your contribution strategy adds up to 90.0%, but it needs to total 100%."

    @import.unisuper_allocation = { "Moon Shots" => "100" }
    assert_not @import.valid?
    assert_includes @import.errors.full_messages, "Moon Shots isn't a UniSuper investment option."
  end

  test "only AUD investment accounts can be the target" do
    @import.account = accounts(:depository)

    assert_not @import.valid?
    assert_includes @import.errors.full_messages, "UniSuper imports go into an investment account."
    assert_includes @import.errors.full_messages, "UniSuper imports go into an account in AUD."
  end

  private

    def use_prices(series)
      prices = series.to_h do |ticker, price_for|
        Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: "XXXX") { |security| security.price_provider = "unisuper" }
        [ ticker, (Date.new(2025, 12, 1)..Date.new(2026, 7, 31)).to_h { |date| [ date, BigDecimal(price_for.call(date).to_s) ] } ]
      end

      FakeProvider.new(prices).tap do |provider|
        Provider::Registry.any_instance.stubs(:get_provider).with(:unisuper).returns(provider)
      end
    end
end
