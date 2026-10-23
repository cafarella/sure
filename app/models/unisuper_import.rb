# Imports a UniSuper account from the transactions CSV you can download from
# Member Online (Date, Transaction type, Description, Amount).
#
# UniSuper accounts don't have units, so we make some up: each contribution
# buys units of your options, split by your contribution strategy, at that
# day's Provider::Unisuper price. Tax and fees sell units in proportion to
# what's held. Sure then values the account daily from the prices.
#
# What UniSuper actually credits (each 30 June and 31 December) is a bit off
# its daily index, so the export wins: the ledger balance goes in as a
# valuation on each crediting date, and on the export date it includes
# UniSuper's estimate of returns not credited yet. The returns rows aren't
# booked themselves, since the prices already include them.
#
# An export is the whole history, so a newer one replaces the last one. The
# earlier import has to be reverted first.
class UnisuperImport < Import
  after_create :set_mappings
  before_save :strip_byte_order_mark

  DEFAULT_COLUMN_MAPPINGS = {
    date_col_label: "Date",
    date_format: "%d/%m/%Y",
    entity_type_col_label: "Transaction type",
    name_col_label: "Description",
    amount_col_label: "Amount",
    number_format: "1,234.56",
    signage_convention: "inflows_positive"
  }.freeze

  CURRENCY = "AUD".freeze
  RETURNS = "InvestmentEarnings".freeze
  # Transaction types that are costs (or rebates of them) rather than money in
  # or out. "ContributionTaxes" is a cost, "Contribution" isn't.
  COST_TYPES = /tax|fee|premium|insurance/i
  PRICE_LOOKBACK = 10.days
  QTY_SCALE = 10
  PERIOD_HEADER = %r{(\d{2}/\d{2}/\d{4})\s*-\s*(\d{2}/\d{2}/\d{4})}

  validate :account_is_an_aud_investment_account, if: :account
  validate :allocation_adds_up, if: -> { unisuper_allocation.present? }

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  # The contribution strategy, e.g. { "High Growth" => BigDecimal("35") }.
  # Stored in column_mappings, like QifImport does with its settings.
  def unisuper_allocation
    (column_mappings || {}).fetch("unisuper_allocation", {}).transform_values { |pct| BigDecimal(pct.to_s) }
  end

  # Takes option names or form keys ("high_growth"). Blank, zero and junk
  # values are dropped, so a typo shows up as a total that isn't 100.
  def unisuper_allocation=(value)
    by_key = Provider::Unisuper.option_names.index_by { |name| allocation_key(name) }
    allocation = value.to_h.each_with_object({}) do |(key, pct), result|
      percent = BigDecimal(pct.to_s.strip, exception: false)
      next if percent.nil? || percent.zero?

      result[by_key[allocation_key(key)] || key.to_s.strip] = percent.to_s("F")
    end

    self.column_mappings = (column_mappings || {}).merge("unisuper_allocation" => allocation)
  end

  def allocation_key(name)
    name.to_s.parameterize(separator: "_")
  end

  # The options to ask about: the ones the export has returns for, or all of
  # them if it has none yet. Read from the file because the form is shown
  # before there are any rows.
  def allocation_choices
    held = csv_rows.filter_map do |row|
      next unless csv_value(row, entity_type_col_label, "transaction_type") == RETURNS

      option_from(csv_value(row, name_col_label, "description"))
    end
    choices = held.uniq.select { |name| Provider::Unisuper.option_names.include?(name) }
    (choices.presence || Provider::Unisuper.option_names) | unisuper_allocation.keys
  end

  def extra_configuration_params
    [ :account_id, { unisuper_allocation: {} } ]
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      {
        source_row_number: index,
        date: csv_value(row, date_col_label, "date").to_s,
        entity_type: csv_value(row, entity_type_col_label, "transaction_type").to_s,
        name: csv_value(row, name_col_label, "description").to_s,
        amount: sanitize_number(csv_value(row, amount_col_label, "amount")).to_s,
        currency: CURRENCY
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  def column_keys
    %i[date entity_type name amount]
  end

  def required_column_keys
    %i[date entity_type amount]
  end

  def publishable?
    super && account.present? && unisuper_allocation.present? && valid?
  end

  def dry_run
    ledger = ledger_rows
    money = ledger.count { |row| money_row?(row) }
    cost_days = ledger.select { |row| cost_row?(row) }.map(&:date).uniq.size
    crediting_days = ledger.select { |row| credited_row?(row) }.map(&:date).uniq
    valuation_days = crediting_days | (estimate_rows.any? ? [ export_date ] : [])

    {
      transactions: money + cost_days,
      trades: (money + cost_days) * [ unisuper_allocation.size, 1 ].max,
      valuations: valuation_days.size
    }
  end

  def csv_template
    CSV.parse(<<~CSV, headers: true)
      Date,Transaction type,Description,Amount
      15/10/2026,Contribution,Employer Contribution From Example Pty Ltd,375.14
      15/10/2026,ContributionTaxes,Contribution Tax,-56.27
      30/09/2026,FeeDeductions,Administration Fee,-8.00
      30/06/2026,InvestmentEarnings,Investment Returns - High Growth,262.66
    CSV
  end

  # The export's date range, from UniSuper's header ("01/01/2023 - 22/10/2026").
  def export_period
    match = Array(csv_headers).lazy.filter_map { |header| PERIOD_HEADER.match(header.to_s) }.first
    return if match.nil?

    Date.strptime(match[1], "%d/%m/%Y")..Date.strptime(match[2], "%d/%m/%Y")
  rescue Date::Error
    nil
  end

  private
    Line = Data.define(:date, :type, :description, :amount)

    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end

    def strip_byte_order_mark
      return unless will_save_change_to_raw_file_str? && raw_file_str&.start_with?("﻿")

      self.raw_file_str = raw_file_str.delete_prefix("﻿")
    end

    def import!
      unless Setting.enabled_securities_providers.include?("unisuper")
        raise MappingError, I18n.t("imports.errors.unisuper_provider_disabled")
      end
      if earlier_import_in_place?
        raise MappingError, I18n.t("imports.errors.unisuper_earlier_import", account: account.name)
      end

      transaction do
        @units = Hash.new { |units, option| units[option] = BigDecimal("0") }
        load_prices_and_securities!

        ledger = ledger_rows
        valuations = {}
        running_total = BigDecimal("0")

        ledger.group_by(&:date).sort.each do |date, lines|
          lines.select { |line| money_row?(line) }.each { |line| book_money!(line) }
          book_costs!(date, lines.select { |line| cost_row?(line) })

          running_total += lines.sum(&:amount)
          valuations[date] = running_total if lines.any? { |line| credited_row?(line) }
        end

        if estimate_rows.any?
          valuations[export_date] = ledger.select { |line| line.date <= export_date }.sum(&:amount) + estimate_rows.sum(&:amount)
        end

        valuations.each { |date, amount| book_valuation!(date, amount) }
      end
    end

    # The rows as typed lines, minus UniSuper's estimates of uncredited returns.
    def ledger_rows
      @ledger_rows ||= all_lines.reject { |line| estimate?(line) }
    end

    def estimate_rows
      @estimate_rows ||= all_lines.select { |line| estimate?(line) }
    end

    def all_lines
      @all_lines ||= rows.ordered.map do |row|
        Line.new(
          date: Date.strptime(row.date, date_format),
          type: row.entity_type.to_s,
          description: row.name.to_s,
          amount: BigDecimal(row.amount.presence || "0")
        )
      end
    end

    def export_date
      export_period&.end || all_lines.map(&:date).max
    end

    def estimate?(line)
      line.type == RETURNS && line.description.downcase.start_with?("estimated")
    end

    def credited_row?(line)
      line.type == RETURNS && !estimate?(line)
    end

    def cost_row?(line)
      line.type != RETURNS && line.type.match?(COST_TYPES)
    end

    def money_row?(line)
      line.type != RETURNS && !cost_row?(line) && !line.amount.zero?
    end

    def option_from(description)
      description.to_s.split(" - ").last.to_s.strip
    end

    def pension?
      account.subtype == "pension"
    end

    def earlier_import_in_place?
      family.imports.where(type: self.class.name, account_id: account_id, status: %w[complete importing revert_failed]).where.not(id: id).exists?
    end

    # ---- Booking ----

    # Contributions, roll-ins and withdrawals: the cash, then the units it buys
    # or sells.
    def book_money!(line)
      label = line.type.casecmp?("Contribution") ? "Contribution" : (line.amount.positive? ? "Transfer" : "Withdrawal")
      book_cash!(line.date, line.amount, line.description, label)
      line.amount.positive? ? buy!(line.date, line.amount) : sell!(line.date, -line.amount)
    end

    # A day's tax, fees and rebates, netted into one.
    def book_costs!(date, lines)
      net = lines.sum(&:amount)
      return if lines.empty? || net.zero?

      description = lines.map(&:description).uniq.join(" + ")
      book_cash!(date, net, description, net.negative? ? "Fee" : "Other")
      net.negative? ? sell!(date, -net) : buy!(date, net)
    end

    # amount is the way UniSuper shows it: positive means money in.
    def book_cash!(date, amount, name, label)
      account.entries.create!(
        date: date,
        amount: -amount,
        currency: CURRENCY,
        name: name,
        import: self,
        import_locked: true,
        entryable: Transaction.new(investment_activity_label: label)
      )
    end

    def buy!(date, amount)
      split(amount, allocation_weights).each do |option, part|
        next if part.zero?

        price = price_on(option, date)
        qty = (part / price).round(QTY_SCALE)
        book_trade!(option, date, qty, price, part, "Buy")
        @units[option] += qty
      end
    end

    # Sells across options in proportion to what each is worth that day.
    def sell!(date, amount)
      values = @units.filter_map { |option, units| [ option, units * price_on(option, date) ] if units.positive? }.to_h
      total = values.values.sum
      return if total.zero?

      split(amount, values.transform_values { |value| value / total }).each do |option, part|
        next if part.zero?

        price = price_on(option, date)
        qty = [ (part / price).round(QTY_SCALE), @units[option] ].min
        book_trade!(option, date, -qty, price, -part, "Sell")
        @units[option] -= qty
      end
    end

    def book_trade!(option, date, qty, price, amount, label)
      account.entries.create!(
        date: date,
        amount: amount,
        currency: CURRENCY,
        name: "#{label} #{qty.abs.round(4).to_s('F')} units of UniSuper #{option}",
        import: self,
        import_locked: true,
        entryable: Trade.new(
          security: @securities.fetch(option),
          qty: qty,
          price: price,
          currency: CURRENCY,
          investment_activity_label: label
        )
      )
    end

    # Doesn't touch a valuation that's already on that date.
    def book_valuation!(date, amount)
      return if account.entries.valuations.where(date: date).exists?

      account.entries.create!(
        date: date,
        amount: amount,
        currency: CURRENCY,
        name: Valuation.build_reconciliation_name(account.accountable_type),
        import: self,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end

    # Splits an amount into cents by weight. The rounding leftover goes on the
    # biggest share so the parts add up exactly.
    def split(amount, weights)
      parts = weights.transform_values { |weight| (amount * weight).round(2) }
      largest = weights.max_by { |_, weight| weight }&.first
      parts[largest] += amount - parts.values.sum if largest
      parts
    end

    def allocation_weights
      total = unisuper_allocation.values.sum
      unisuper_allocation.transform_values { |pct| pct / total }
    end

    # ---- Prices and securities ----

    def load_prices_and_securities!
      provider = Provider::Registry.for_concept(:securities).get_provider(:unisuper)
      first, last = ledger_rows.map(&:date).minmax
      @prices = {}
      @securities = {}

      unisuper_allocation.each_key do |option|
        ticker = Provider::Unisuper.ticker_for(option, pension: pension?)
        raise MappingError, I18n.t("imports.errors.unisuper_unknown_option", option: option) if ticker.nil?

        response = provider.fetch_security_prices(
          symbol: ticker,
          exchange_operating_mic: Provider::Unisuper::MIC,
          start_date: first - PRICE_LOOKBACK,
          end_date: last
        )
        raise MappingError, response.error.message unless response.success?

        @prices[option] = response.data.map { |price| [ price.date, price.price.to_d ] }.sort_by(&:first)
        @securities[option] = resolve_security!(ticker)
      end
    end

    def resolve_security!(ticker)
      security = Security::Resolver.new(ticker, exchange_operating_mic: Provider::Unisuper::MIC, price_provider: "unisuper").resolve
      if security.nil? || security.offline?
        raise MappingError, I18n.t("imports.errors.unisuper_provider_disabled")
      end

      security
    end

    def price_on(option, date)
      day, price = @prices.fetch(option).reverse_each.find { |candidate, _| candidate <= date }
      if day.nil? || day < date - PRICE_LOOKBACK
        raise MappingError, I18n.t("imports.errors.unisuper_no_price", option: option, date: date)
      end

      price
    end

    # ---- Validation ----

    def account_is_an_aud_investment_account
      errors.add(:base, I18n.t("imports.errors.unisuper_account_type")) unless account.investment?
      errors.add(:base, I18n.t("imports.errors.unisuper_account_currency")) unless account.currency == CURRENCY
    end

    def allocation_adds_up
      unknown = unisuper_allocation.keys - Provider::Unisuper.option_names
      errors.add(:base, I18n.t("imports.errors.unisuper_unknown_option", option: unknown.join(", "))) if unknown.any?

      total = unisuper_allocation.values.sum
      if unisuper_allocation.values.any?(&:negative?) || (total - 100).abs > BigDecimal("0.5")
        errors.add(:base, I18n.t("imports.errors.unisuper_allocation_total", total: total.round(2).to_s("F")))
      end
    end
end
