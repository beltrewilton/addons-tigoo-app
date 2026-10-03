defmodule PosServer.Addons.SalesSummaryReport do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

  alias Elixlsx.{Workbook, Sheet}

  @logins ["luis", "walex", "danny"]
  @card_fee_rate 0.0385

  defmodule Sale do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "sale" do
      field :login, :string
      field :status, :string
      field :date_create, :naive_datetime
      field :client_id, :integer
      field :store_id, :integer
    end
  end

  defmodule SaleLine do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "sale_line" do
      field :sale_id, :integer
      field :product_id, :integer
      field :total_amount, :decimal
      field :quantity, :float
    end
  end

  defmodule Product do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "product" do
      field :code, :string
    end
  end

  defmodule Client do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "client" do
      field :name, :string
    end
  end

  defmodule Store do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "app_store" do
      field :name, :string
    end
  end

  defmodule SalePaid do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "sale_paid" do
      field :sale_id, :integer
      field :amount, :decimal
      field :type, :string
    end
  end

  def manifest do
    %{
      identifier: "sales_summary_report",
      name: "Resumen de Ventas",
      route: "/pos/addons/sales_summary_report",
      icon: "📊",
      description: "Review sales totals and payment-card fees by representative.",
      handler: __MODULE__
    }
  end

  def render(%{tenant: tenant, repo: repo, params: params} = context) when is_binary(tenant) and tenant != "" do
    filters = %{date_from: Map.get(params, "date_from", ""), date_to: Map.get(params, "date_to", "")}

    case date_range(filters) do
      :blank -> content(filters, false, nil, [], context)
      {:error, message} -> content(filters, false, message, [], context)
      {:ok, from, to} -> content(filters, true, nil, summaries(repo, tenant, from, to), context)
    end
  end

  def render(context),
    do: content(%{date_from: "", date_to: ""}, false, "No tenant is connected.", [], context)

  def export(%{tenant: tenant, repo: repo, params: params}) when is_binary(tenant) and tenant != "" do
    filters = %{date_from: Map.get(params, "date_from", ""), date_to: Map.get(params, "date_to", "")}

    with {:ok, from, to} <- date_range(filters),
         summaries <- summaries(repo, tenant, from, to),
         workbook <- summary_workbook(filters, summaries),
         filename <- export_filename(filters),
         {:ok, {_name, binary}} <- Elixlsx.write_to_memory(workbook, filename) do
      {:download, filename, binary, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
    else
      _ -> {:error, :invalid_export_filters}
    end
  end

  def export(_context), do: {:error, :invalid_export_filters}

  # PostgreSQL equivalent of the supplied card-fee query, grouped by login:
  # SELECT s.login, COALESCE(SUM(sp.amount), 0) * 0.0385 AS tarjeta
  # FROM sale s JOIN sale_paid sp ON sp.sale_id = s.id
  # WHERE s.login IN ('luis', 'walex', 'danny') AND sp.type = 'CC'
  #   AND s.date_create BETWEEN $1 AND $2 GROUP BY s.login;
  defp summaries(repo, tenant, from, to) do
    subtotals =
      repo.all(
        from(sale in Sale,
          join: line in SaleLine, on: line.sale_id == sale.id,
          join: product in Product, on: product.id == line.product_id,
          join: client in Client, on: client.id == sale.client_id,
          join: store in Store, on: store.id == sale.store_id,
          where: sale.status != "RETURN" and sale.login in ^@logins,
          where: not like(product.code, "4500%"),
          where: sale.date_create >= ^from and sale.date_create <= ^to,
          group_by: sale.login,
          select: %{login: sale.login, subtotal: sum(line.total_amount * line.quantity)}
        ),
        prefix: tenant
      )
      |> Map.new(&{&1.login, numeric_value(&1.subtotal)})

    card_fees =
      repo.all(
        from(sale in Sale,
          join: payment in SalePaid, on: payment.sale_id == sale.id,
          where: sale.login in ^@logins and payment.type == "CC",
          where: sale.date_create >= ^from and sale.date_create <= ^to,
          group_by: sale.login,
          select: %{login: sale.login, tarjeta: sum(payment.amount) * ^@card_fee_rate}
        ),
        prefix: tenant
      )
      |> Map.new(&{&1.login, numeric_value(&1.tarjeta)})

    Enum.map(@logins, fn login ->
      subtotal = Map.get(subtotals, login, 0.0)
      tarjeta = Map.get(card_fees, login, 0.0)
      %{login: login, subtotal: subtotal, tarjeta: tarjeta, total: subtotal - tarjeta}
    end)
  end

  defp date_range(%{date_from: "", date_to: ""}), do: :blank

  defp date_range(%{date_from: from, date_to: to}) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.compare(from_date, to_date) != :gt do
      {:ok, NaiveDateTime.new!(from_date, ~T[00:00:00]), NaiveDateTime.new!(to_date, ~T[23:59:59])}
    else
      false -> {:error, "The start date must be on or before the end date."}
      _ -> {:error, "Choose valid start and end dates."}
    end
  end

  defp content(filters, searched?, filter_error, summaries, context) do
    assigns = %{
      filters: filters,
      searched?: searched?,
      filter_error: filter_error,
      summaries: summaries,
      totals: summary_totals(summaries),
      calendar_month: calendar_month(filters),
      pending_range: %{from: filters.date_from, to: filters.date_to},
      content_class: content_class(context)
    }

    ~H"""
    <div class={@content_class}>
      <style>
        .sales-summary-filter-card { overflow: visible; }
        .sales-summary-filter-card .card-content { overflow: visible; }
        .sales-summary-filters { display: grid; grid-template-columns: minmax(240px, 360px) auto; align-items: end; gap: .75rem; position: relative; z-index: 10; }
        .sales-summary-picker { position: relative; }
        .sales-summary-picker summary { list-style: none; }
        .sales-summary-picker summary::-webkit-details-marker { display: none; }
        .sales-summary-trigger { width: 100%; min-width: 260px; justify-content: flex-start; }
        .sales-summary-menu { position: absolute; left: 0; top: calc(100% + .5rem); z-index: 5; padding: .75rem; border: 1px solid var(--border); border-radius: var(--radius); background: var(--background); box-shadow: var(--shadow-lg, 0 12px 32px rgb(0 0 0 / .14)); }
        .sales-summary-calendar { width: min(704px, calc(100vw - 2rem)); max-height: min(78vh, 720px); overflow: auto; }
        .sales-summary-summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 1rem; }
        .sales-summary-card { overflow: hidden; }
        .sales-summary-card .card-header { border-bottom: 1px solid var(--border); background: color-mix(in oklch, var(--muted) 62%, transparent); }
        .sales-summary-name { margin: 0; text-transform: uppercase; }
        .sales-summary-metric { display: flex; align-items: baseline; justify-content: space-between; gap: 1rem; padding: .55rem 0; border-bottom: 1px solid var(--border); }
        .sales-summary-metric:last-child { border-bottom: 0; }
        .sales-summary-metric span { color: var(--muted-foreground); font-size: .78rem; font-weight: 700; text-transform: uppercase; }
        .sales-summary-metric strong { font-size: 1rem; }
        .sales-summary-total { color: var(--primary); }
        .sales-summary-overview { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: .75rem; margin-bottom: 1rem; }
        .sales-summary-kpi { padding: 1rem; border: 1px solid var(--border); border-radius: var(--radius); background: var(--background); }
        .sales-summary-kpi span { display: block; color: var(--muted-foreground); font-size: .75rem; font-weight: 700; text-transform: uppercase; }
        .sales-summary-kpi strong { display: block; margin-top: .35rem; font-size: 1.4rem; }
        @media (max-width: 760px) { .sales-summary-filters { grid-template-columns: 1fr; } .sales-summary-trigger { min-width: 0; } .sales-summary-menu { position: static; width: 100%; margin-top: .5rem; } }
      </style>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="sales-summary-title">RESUMEN DE VENTAS</h1></div></header>
      <section class="card dashboard-panel sales-summary-filter-card" aria-label="Filtros del resumen de ventas">
        <form id="sales-summary-filters" class="card-content sales-summary-filters" method="get">
          <div class="form-field invoice-date-picker sales-summary-picker">
            <span class="label">Seleccionar rango de fechas</span>
            <input id="summary-date-from" name="date_from" type="hidden" value={@filters.date_from} />
            <input id="summary-date-to" name="date_to" type="hidden" value={@filters.date_to} />
            <details id="sales-summary-date-picker" class="sales-summary-picker" data-month={Date.to_iso8601(@calendar_month)}>
              <summary id="summary-date-range-trigger" class="btn invoice-date-range sales-summary-trigger" data-variant="outline" data-size="sm"><%= range_label(@filters.date_from, @filters.date_to) %></summary>
              <.calendar_popover month={@calendar_month} range={@pending_range} />
            </details>
          </div>
          <div class="form-actions"><button class="btn" data-variant="default" type="submit">Generar resumen</button></div>
        </form>
        <div :if={@searched? && @summaries != []} class="card-footer">
          <a class="btn" data-variant="outline" href={export_href(@filters)}>Exportar XLSX</a>
        </div>
        <p :if={@filter_error} class="card-content field-error"><%= @filter_error %></p>
      </section>
      <section :if={@searched?} class="dashboard-panel" aria-label="Resumen de ventas por representante">
        <div class="sales-summary-overview">
          <div class="sales-summary-kpi"><span>Subtotal</span><strong><%= format_currency(@totals.subtotal) %></strong></div>
          <div class="sales-summary-kpi"><span>% tarjeta</span><strong><%= format_currency(@totals.tarjeta) %></strong></div>
          <div class="sales-summary-kpi"><span>Total</span><strong><%= format_currency(@totals.total) %></strong></div>
        </div>
        <div class="sales-summary-summary-grid">
          <article :for={summary <- @summaries} class="card sales-summary-card">
            <div class="card-header"><p class="card-description">Representante</p><h2 class="card-title sales-summary-name"><%= summary.login %></h2></div>
            <div class="card-content">
              <div class="sales-summary-metric"><span>Subtotal</span><strong><%= format_currency(summary.subtotal) %></strong></div>
              <div class="sales-summary-metric"><span>% tarjeta (3.85%)</span><strong><%= format_currency(summary.tarjeta) %></strong></div>
              <div class="sales-summary-metric"><span>Total</span><strong class="sales-summary-total"><%= format_currency(summary.total) %></strong></div>
            </div>
          </article>
        </div>
      </section>
      <script>
        (() => {
          const root = document.currentScript.closest(".dashboard-content") || document;
          const datePicker = root.querySelector("#sales-summary-date-picker");
          if (!datePicker || datePicker.dataset.ready) return;
          datePicker.dataset.ready = "true";

          const fromInput = root.querySelector("#summary-date-from");
          const toInput = root.querySelector("#summary-date-to");
          const trigger = datePicker.querySelector("#summary-date-range-trigger");
          const title = datePicker.querySelector("[data-calendar-title]");
          const grid = datePicker.querySelector("[data-calendar-grid]");
          const help = datePicker.querySelector("[data-calendar-help]");
          const monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
          let month = new Date(`${datePicker.dataset.month}T00:00:00`);
          let range = {from: fromInput.value, to: toInput.value};

          const label = (from, to) => {
            const format = value => {
              const date = new Date(`${value}T00:00:00`);
              return date.toLocaleDateString("en-US", {month: "short", day: "numeric", year: "numeric"});
            };
            if (!from) return "Cualquier fecha";
            if (!to || from === to) return format(from);
            return `${format(from)} - ${format(to)}`;
          };
          const iso = date => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
          const render = () => {
            title.textContent = `${monthNames[month.getMonth()]} ${month.getFullYear()}`;
            help.textContent = range.from && !range.to ? "Elige una fecha final." : "Elige una fecha inicial y luego una final.";
            grid.innerHTML = "";
            const blanks = new Date(month.getFullYear(), month.getMonth(), 1).getDay();
            for (let i = 0; i < blanks; i++) grid.appendChild(document.createElement("span"));
            const lastDay = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
            for (let day = 1; day <= lastDay; day++) {
              const value = iso(new Date(month.getFullYear(), month.getMonth(), day));
              const button = document.createElement("button");
              button.className = "btn calendar-day";
              button.type = "button";
              button.dataset.variant = "ghost";
              button.dataset.size = "icon-sm";
              button.dataset.date = value;
              button.textContent = day;
              button.setAttribute("aria-selected", String(value === range.from || value === range.to));
              if (range.from && range.to && value > range.from && value < range.to) button.dataset.range = "middle";
              grid.appendChild(button);
            }
          };
          datePicker.addEventListener("click", event => {
            const direction = event.target.closest("[data-calendar-direction]")?.dataset.calendarDirection;
            if (direction) {
              month.setMonth(month.getMonth() + (direction === "next" ? 1 : -1));
              render();
              return;
            }
            const selected = event.target.closest("[data-date]")?.dataset.date;
            if (selected) {
              if (!range.from || range.to) range = {from: selected, to: ""};
              else if (selected < range.from) range = {from: selected, to: range.from};
              else range = {from: range.from, to: selected};
              render();
            }
            if (event.target.closest("[data-calendar-clear]")) {
              range = {from: "", to: ""};
              fromInput.value = "";
              toInput.value = "";
              trigger.textContent = label("", "");
              datePicker.open = false;
              render();
            }
            if (event.target.closest("[data-calendar-cancel]")) datePicker.open = false;
            if (event.target.closest("[data-calendar-apply]")) {
              fromInput.value = range.from;
              toInput.value = range.to;
              trigger.textContent = label(range.from, range.to);
              datePicker.open = false;
            }
          });
          document.addEventListener("click", event => {
            if (!datePicker.contains(event.target)) datePicker.open = false;
          });
          render();
        })();
      </script>
    </div>
    """
  end

  attr(:month, :any, required: true)
  attr(:range, :map, required: true)

  defp calendar_popover(assigns) do
    ~H"""
    <div id="summary-date-range-dialog" class="invoice-date-popover sales-summary-menu sales-summary-calendar" role="dialog" aria-modal="false" aria-labelledby="summary-date-range-title">
      <div class="dialog-content">
        <div class="dialog-header">
          <h2 id="summary-date-range-title" class="dialog-title">Seleccionar rango de fechas</h2>
          <p class="dialog-description" data-calendar-help><%= if @range.from != "" && @range.to == "", do: "Elige una fecha final.", else: "Elige una fecha inicial y luego una final." %></p>
        </div>
        <hr class="separator" />
        <div class="calendar-header">
          <button class="btn" type="button" data-variant="ghost" data-size="icon-sm" data-calendar-direction="previous" aria-label="Mes anterior">‹</button>
          <h3 class="h4" data-calendar-title><%= Calendar.strftime(@month, "%B %Y") %></h3>
          <button class="btn" type="button" data-variant="ghost" data-size="icon-sm" data-calendar-direction="next" aria-label="Mes siguiente">›</button>
        </div>
        <div class="calendar-weekdays" aria-hidden="true">
          <span>Su</span><span>Mo</span><span>Tu</span><span>We</span><span>Th</span><span>Fr</span><span>Sa</span>
        </div>
        <div class="calendar-grid" role="grid" data-calendar-grid>
          <span :for={_ <- calendar_blanks(@month)}></span><button :for={date <- Date.range(@month, month_end(@month))} class="btn calendar-day" data-range={calendar_day_class(date, @range)} type="button" data-variant="ghost" data-size="icon-sm" data-date={Date.to_iso8601(date)} aria-selected={to_string(Date.to_iso8601(date) in [@range.from, @range.to])}><%= date.day %></button>
        </div>
        <div class="dialog-footer">
          <button class="btn" type="button" data-variant="ghost" data-calendar-clear>Limpiar</button>
          <button class="btn" type="button" data-variant="outline" data-calendar-cancel>Cancelar</button>
          <button class="btn" type="button" data-variant="default" data-calendar-apply>Aplicar rango</button>
        </div>
      </div>
    </div>
    """
  end

  defp calendar_month(%{date_from: date}) when is_binary(date) and date != "" do
    date
    |> Date.from_iso8601!()
    |> month_start()
  rescue
    _ -> month_start(server_today())
  end

  defp calendar_month(_), do: month_start(server_today())

  defp month_start(%Date{} = date), do: Date.new!(date.year, date.month, 1)

  defp month_end(%Date{} = date),
    do: Date.new!(date.year, date.month, Calendar.ISO.days_in_month(date.year, date.month))

  defp server_today do
    {{year, month, day}, _time} = :calendar.local_time()
    Date.new!(year, month, day)
  end

  defp calendar_blanks(month), do: List.duplicate(:blank, Date.day_of_week(month, :sunday) - 1)

  defp calendar_day_class(date, %{from: from, to: to}) do
    value = Date.to_iso8601(date)
    if from != "" and to != "" and value > from and value < to, do: "middle", else: nil
  end

  defp range_label("", _), do: "Cualquier fecha"
  defp range_label(from, from), do: format_range_date(from)
  defp range_label(from, ""), do: format_range_date(from)
  defp range_label(from, to), do: "#{format_range_date(from)} - #{format_range_date(to)}"

  defp format_range_date(value),
    do: value |> Date.from_iso8601!() |> Calendar.strftime("%b %-d, %Y")

  defp summary_totals(summaries) do
    Enum.reduce(summaries, %{subtotal: 0.0, tarjeta: 0.0, total: 0.0}, fn summary, totals ->
      %{
        subtotal: totals.subtotal + numeric_value(summary.subtotal),
        tarjeta: totals.tarjeta + numeric_value(summary.tarjeta),
        total: totals.total + numeric_value(summary.total)
      }
    end)
  end

  defp summary_workbook(filters, summaries) do
    %Workbook{}
    |> Workbook.append_sheet(summary_sheet(filters, summaries))
  end

  defp summary_sheet(filters, summaries) do
    totals = summary_totals(summaries)

    rows =
      [
        [report_title_cell()],
        [report_subtitle_cell(range_label(filters.date_from, filters.date_to))],
        [],
        summary_header_row()
      ] ++ Enum.map(summaries, &summary_xlsx_row/1) ++ [[], summary_total_row(totals)]

    %Sheet{name: "Resumen", rows: rows}
    |> merge_report_header()
    |> Sheet.set_pane_freeze(4, 0)
    |> Sheet.set_row_height(1, 28)
    |> Sheet.set_row_height(2, 21)
    |> Sheet.set_row_height(4, 22)
    |> Sheet.set_col_width("A", 22)
    |> Sheet.set_col_width("B", 18)
    |> Sheet.set_col_width("C", 18)
    |> Sheet.set_col_width("D", 18)
  end

  defp merge_report_header(sheet) do
    %{sheet | merge_cells: [{"A1", "D1"}, {"A2", "D2"}]}
  end

  defp summary_header_row do
    [
      header_cell("REPRESENTANTE"),
      header_cell("SUBTOTAL"),
      header_cell("% TARJETA"),
      header_cell("TOTAL")
    ]
  end

  defp summary_xlsx_row(summary) do
    [
      String.upcase(summary.login),
      money_cell(summary.subtotal),
      money_cell(summary.tarjeta),
      money_cell(summary.total)
    ]
  end

  defp summary_total_row(totals) do
    [
      ["TOTAL", bold: true, color: "#111827", bg_color: "#D1FAE5"],
      total_money_cell(totals.subtotal),
      total_money_cell(totals.tarjeta),
      total_money_cell(totals.total)
    ]
  end

  defp money_cell(value), do: [numeric_value(value), num_format: "$#,##0.00", align_horizontal: :right]
  defp total_money_cell(value), do: [numeric_value(value), bold: true, num_format: "$#,##0.00", bg_color: "#D1FAE5", align_horizontal: :right]

  defp report_title_cell,
    do: ["RESUMEN DE VENTAS", bold: true, size: 18, color: "#FFFFFF", bg_color: "#111827", align_horizontal: :center, align_vertical: :center]

  defp report_subtitle_cell(value),
    do: [value, italic: true, color: "#6B7280", bg_color: "#F9FAFB", align_horizontal: :center, align_vertical: :center]

  defp header_cell(value),
    do: [value, bold: true, color: "#FFFFFF", bg_color: "#047857", align_horizontal: :center, align_vertical: :center]

  defp export_href(filters) do
    query = [{"date_from", filters.date_from}, {"date_to", filters.date_to}, {"export", "xlsx"}]
    "/pos/addons/sales_summary_report?#{URI.encode_query(query)}"
  end

  defp export_filename(filters) do
    from = String.replace(filters.date_from || "desde", "-", "")
    to = String.replace(filters.date_to || "hasta", "-", "")
    "resumen_ventas_#{from}_#{to}.xlsx"
  end

  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_), do: 0.0

  defp format_currency(value) do
    {sign, amount} = value |> numeric_value() |> :erlang.float_to_binary(decimals: 2) |> split_sign()
    [whole, cents] = String.split(amount, ".", parts: 2)
    "$ #{sign}#{group_digits(whole)}.#{cents}"
  end

  defp split_sign("-" <> amount), do: {"-", amount}
  defp split_sign(amount), do: {"", amount}

  defp group_digits(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp content_class(%{host: %{content_class: class}}) when is_binary(class) and class != "",
    do: class

  defp content_class(_context), do: "dashboard-content"
end
