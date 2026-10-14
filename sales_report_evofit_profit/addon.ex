defmodule PosServer.Addons.SalesReportEvofitProfit do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

  defmodule Sale do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "sale" do
      field(:login, :string)
      field(:status, :string)
      field(:date_create, :naive_datetime)
      field(:client_id, :integer)
      field(:store_id, :integer)
    end
  end

  defmodule SaleLine do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "sale_line" do
      field(:sale_id, :integer)
      field(:product_id, :integer)
      field(:total_amount, :decimal)
      field(:quantity, :float)
    end
  end

  defmodule Product do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "product" do
      field(:name, :string)
      field(:cost, :decimal)
    end
  end

  defmodule Client do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "client" do
      field(:name, :string)
    end
  end

  def manifest do
    %{
      identifier: "sales_report_evofit_profit",
      name: "Reporte de Utilidad Evofit",
      route: "/pos/addons/sales_report_evofit_profit",
      icon: "📈",
      description: "Analyze Evofit sales, product cost, and profit by day.",
      handler: __MODULE__
    }
  end

  def render(%{tenant: tenant, repo: repo, params: params} = context)
      when is_binary(tenant) and tenant != "" do
    filters = %{
      date_from: Map.get(params, "date_from", ""),
      date_to: Map.get(params, "date_to", "")
    }

    case report_params(filters) do
      :blank ->
        content(page_data(filters, false, nil, [], context))

      {:error, message} ->
        content(page_data(filters, false, message, [], context))

      {:ok, from, to} ->
        content(
          page_data(
            filters,
            true,
            nil,
            report(repo, tenant, from, to),
            context
          )
        )
    end
  end

  def render(context),
    do:
      content(
        page_data(
          %{date_from: "", date_to: ""},
          false,
          "No tenant is connected.",
          [],
          context
        )
      )

  defp report(repo, tenant, from, to) do
    repo.all(
      from(sale in Sale,
        join: line in SaleLine,
        on: line.sale_id == sale.id,
        join: product in Product,
        on: product.id == line.product_id,
        join: client in Client,
        on: client.id == sale.client_id,
        where: sale.status != "RETURN",
        where: sale.date_create >= ^from and sale.date_create <= ^to,
        order_by: [asc: sale.date_create, asc: client.name],
        select: %{
          login: sale.login,
          producto: product.name,
          cliente: client.name,
          fecha: sale.date_create,
          costo_unitario: product.cost,
          cantidad: line.quantity,
          costo_producto:
            fragment("coalesce(?, 0) * coalesce(?, 0)", product.cost, line.quantity),
          facturado_al_cliente: line.total_amount,
          utilidad:
            fragment(
              "coalesce(?, 0) - (coalesce(?, 0) * coalesce(?, 0))",
              line.total_amount,
              product.cost,
              line.quantity
            )
        }
      ),
      prefix: tenant
    )
  end

  defp report_params(%{date_from: "", date_to: ""}), do: :blank

  defp report_params(%{date_from: from, date_to: to}) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.compare(from_date, to_date) != :gt do
      {:ok, NaiveDateTime.new!(from_date, ~T[00:00:00]),
       NaiveDateTime.new!(to_date, ~T[23:59:59])}
    else
      false -> {:error, "The start date must be on or before the end date."}
      _ -> {:error, "Seleccione un rango de fechas válido."}
    end
  end

  defp report_params(_),
    do: {:error, "Seleccione un rango de fechas válido."}

  defp page_data(filters, searched?, filter_error, report, context) do
    %{
      filters: filters,
      filter_error: filter_error,
      searched?: searched?,
      report: report,
      daily_totals: daily_totals(report, filters),
      calendar_month: calendar_month(filters),
      pending_range: %{from: filters.date_from, to: filters.date_to},
      content_class: content_class(context)
    }
  end

  defp content(assigns) do
    ~H"""
    <div class={@content_class}>
      <style>
        .sales-report-tabs input[type="radio"] { position: absolute; opacity: 0; pointer-events: none; }
        .sales-report-tabs nav { display: flex; flex-wrap: wrap; gap: 0; margin-bottom: 1rem; border-bottom: 1px solid var(--border); }
        .sales-report-tabs label { cursor: pointer; order: 1; border: 1px solid transparent; border-bottom: 2px solid transparent; border-radius: var(--radius) var(--radius) 0 0; background: transparent; color: var(--muted-foreground); }
        .sales-report-tab-panel { display: none; flex-basis: 100%; order: 2; }
        .sales-report-tabs input[type="radio"]:checked + label { background: var(--background); color: var(--foreground); border-color: var(--border); border-bottom-color: var(--primary); box-shadow: inset 0 -2px 0 var(--primary); font-weight: 800; }
        .sales-report-tabs input[type="radio"]:checked + label + .sales-report-tab-panel { display: block; }
        .sales-report-table-container { max-height: 65vh; overflow: auto; }
        .sales-report-table-container thead th { position: sticky; top: 0; z-index: 1; background: var(--background); }
        .sales-report-table-container tfoot td { position: sticky; bottom: 0; z-index: 1; background: var(--background); box-shadow: 0 -1px 0 var(--border); }
        .sales-report-total-label { display: block; color: var(--muted-foreground); font-size: .72rem; font-weight: 700; line-height: 1.1; text-transform: uppercase; }
        .sales-report-total-value { display: block; margin-top: .2rem; white-space: nowrap; font-weight: 800; }
        .sales-report-discount { color: #ea580c; }
        .sales-report-billed { color: #0f172a; }
        .sales-report-profit { color: #047857; }
        .sales-report-filter-card { overflow: visible; }
        .sales-report-filter-card .card-content { overflow: visible; }
        .sales-report-filters { display: grid; grid-template-columns: minmax(240px, 360px) auto; align-items: end; gap: .75rem; position: relative; z-index: 10; }
        .sales-report-picker { position: relative; }
        .sales-report-picker > .label { display: block; margin-bottom: .35rem; }
        .sales-report-picker summary { list-style: none; }
        .sales-report-picker summary::-webkit-details-marker { display: none; }
        .sales-report-trigger { width: 100%; min-width: 260px; justify-content: flex-start; }
        .sales-report-menu { position: absolute !important; left: 0 !important; right: auto !important; top: calc(100% + .5rem) !important; z-index: 30; width: min(23rem, calc(100vw - 2rem)); padding: .75rem; border: 1px solid var(--border); border-radius: var(--radius); background: var(--background); box-shadow: var(--shadow-lg, 0 12px 32px rgb(0 0 0 / .14)); }
        .sales-report-calendar { max-height: min(70vh, 34rem); overflow: auto; }
        .sales-report-calendar .dialog-content { gap: .65rem; padding: 0; }
        .sales-report-calendar .dialog-header { gap: .2rem; }
        .sales-report-calendar .dialog-title { font-size: 1rem; line-height: 1.2; }
        .sales-report-calendar .dialog-description { font-size: .82rem; line-height: 1.3; }
        .sales-report-calendar .calendar-header { margin-top: .25rem; }
        .sales-report-calendar .calendar-header .h4 { font-size: 1rem; line-height: 1.2; }
        .sales-report-calendar .calendar-weekdays,
        .sales-report-calendar .calendar-grid { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); gap: .2rem; }
        .sales-report-calendar .calendar-weekdays span { font-size: .72rem; line-height: 1.4; text-align: center; }
        .sales-report-calendar .calendar-day { width: 2rem; height: 2rem; min-height: 2rem; padding: 0; justify-self: center; font-size: .85rem; }
        .sales-report-calendar .dialog-footer { gap: .5rem; padding-top: .35rem; }
        .sales-report-calendar-fields { display: none; }
        .sales-report-chart { padding: 1rem 0 .25rem; overflow-x: auto; }
        .sales-report-chart-legend { display: flex; flex-wrap: wrap; gap: .75rem 1.25rem; margin-bottom: 1rem; color: var(--muted-foreground); font-size: .82rem; font-weight: 700; }
        .sales-report-chart-key { display: inline-flex; align-items: center; gap: .4rem; white-space: nowrap; }
        .sales-report-chart-swatch { width: .8rem; height: .2rem; border-radius: 999px; }
        .sales-report-chart-swatch[data-series="profit"] { background: #047857; }
        .sales-report-chart-swatch[data-series="billed"] { background: #2563eb; }
        .sales-report-chart svg { display: block; min-width: 52rem; width: 100%; height: auto; }
        .sales-report-chart-grid { stroke: color-mix(in oklch, var(--border) 72%, transparent); stroke-width: 1; }
        .sales-report-chart-axis { stroke: color-mix(in oklch, var(--border) 88%, transparent); stroke-width: 1.5; }
        .sales-report-chart-line { fill: none; stroke-linecap: round; stroke-linejoin: round; stroke-width: 3.5; }
        .sales-report-chart-line[data-series="profit"] { stroke: #047857; }
        .sales-report-chart-line[data-series="billed"] { stroke: #2563eb; }
        .sales-report-chart-dot { stroke: var(--background); stroke-width: 3; }
        .sales-report-chart-dot[data-series="profit"] { fill: #047857; }
        .sales-report-chart-dot[data-series="billed"] { fill: #2563eb; }
        .sales-report-chart-label { fill: var(--muted-foreground); font-size: 12px; font-weight: 700; text-anchor: end; }
        .sales-report-chart-y-label { fill: var(--muted-foreground); font-size: 13px; font-weight: 700; text-anchor: end; }
        .sales-report-chart-profit-label { fill: #047857; font-size: 11px; font-weight: 800; text-anchor: middle; paint-order: stroke; stroke: var(--background); stroke-width: 4; stroke-linejoin: round; }
        @media (max-width: 760px) { .sales-report-filters { grid-template-columns: 1fr; } .sales-report-trigger { min-width: 0; } .sales-report-menu { position: static !important; width: 100%; margin-top: .5rem; } }
      </style>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="sales-report-title">REPORTE DE UTILIDAD EVOFIT</h1></div></header>
      <section class="card dashboard-panel sales-report-filter-card" aria-label="Filtros del reporte de ventas">
        <form id="sales-report-filters" class="card-content sales-report-filters" method="get">
          <div class="form-field invoice-date-picker sales-report-picker">
            <span class="label">Seleccionar rango de fechas</span>
            <input id="report-date-from" name="date_from" type="hidden" value={@filters.date_from} />
            <input id="report-date-to" name="date_to" type="hidden" value={@filters.date_to} />
            <details id="sales-report-date-picker" class="sales-report-picker" data-month={Date.to_iso8601(@calendar_month)}>
              <summary id="invoice-date-range-trigger" class="btn invoice-date-range sales-report-trigger" data-variant="outline" data-size="sm"><%= range_label(@filters.date_from, @filters.date_to) %></summary>
              <.calendar_popover month={@calendar_month} range={@pending_range} />
            </details>
          </div>
          <div class="form-actions"><button class="btn" data-variant="default" type="submit">Generar reporte</button></div>
        </form>
        <p :if={@filter_error} class="card-content field-error"><%= @filter_error %></p>
      </section>
      <section :if={@searched?} class="card dashboard-panel" aria-label="Resultados del reporte de ventas">
        <div class="card-content">
          <p :if={@report == []} class="card-description">No se encontraron ventas.</p>
          <div :if={@report != []} class="sales-report-tabs">
            <nav aria-label="Reporte de utilidad" role="tablist">
                <input type="radio" id="sales-report-tab-detail" name="sales-report-tab" checked />
                <label class="btn" data-variant="ghost" role="tab" for="sales-report-tab-detail">DETALLE</label>
                <div class="sales-report-tab-panel">
                  <div class="table-container sales-report-table-container"><table class="table"><thead><tr class="table-row"><th class="table-head">PRODUCTO</th><th class="table-head">CLIENTE</th><th class="table-head">FECHA</th><th class="table-head">COSTO/UND</th><th class="table-head">CANTIDAD</th><th class="table-head"><span class="sales-report-total-label">COSTO PRODUCTO</span><span class="sales-report-total-value"><%= format_money(report_field_total(@report, :costo_producto)) %></span></th><th class="table-head sales-report-billed"><span class="sales-report-total-label">FACTURADO AL CLIENTE</span><span class="sales-report-total-value"><%= format_money(report_field_total(@report, :facturado_al_cliente)) %></span></th><th class="table-head sales-report-profit"><span class="sales-report-total-label">UTILIDAD</span><span class="sales-report-total-value"><%= format_money(report_field_total(@report, :utilidad)) %></span></th></tr></thead><tbody><tr :for={row <- @report} class="table-row"><td class="table-cell"><%= row.producto %></td><td class="table-cell"><%= row.cliente %></td><td class="table-cell"><span><%= format_date(row.fecha) %></span><br /><small><%= format_time(row.fecha) %></small></td><td class="table-cell"><%= format_number(row.costo_unitario) %></td><td class="table-cell"><%= format_number(row.cantidad) %></td><td class="table-cell"><%= format_number(row.costo_producto) %></td><td class="table-cell sales-report-billed"><%= format_number(row.facturado_al_cliente) %></td><td class="table-cell sales-report-profit"><%= format_number(row.utilidad) %></td></tr></tbody><tfoot><tr class="table-row"><td class="table-cell" colspan="5"><strong>TOTAL</strong></td><td class="table-cell"><strong><%= format_money(report_field_total(@report, :costo_producto)) %></strong></td><td class="table-cell sales-report-billed"><strong><%= format_money(report_field_total(@report, :facturado_al_cliente)) %></strong></td><td class="table-cell sales-report-profit"><strong><%= format_money(report_field_total(@report, :utilidad)) %></strong></td></tr></tfoot></table></div>
                </div>
                <input type="radio" id="sales-report-tab-profit" name="sales-report-tab" />
                <label class="btn" data-variant="ghost" role="tab" for="sales-report-tab-profit">DIARIO</label>
                <div class="sales-report-tab-panel">
                  <div class="sales-report-chart" aria-label="Utilidad y facturado al cliente por día">
                    <div class="sales-report-chart-legend">
                      <span class="sales-report-chart-key"><span class="sales-report-chart-swatch" data-series="profit"></span>Utilidad: <%= format_money(report_field_total(@report, :utilidad)) %></span>
                      <span class="sales-report-chart-key"><span class="sales-report-chart-swatch" data-series="billed"></span>Facturado al cliente: <%= format_money(report_field_total(@report, :facturado_al_cliente)) %></span>
                    </div>
                    <svg viewBox="0 0 1000 380" role="img" aria-labelledby="sales-report-daily-chart-title">
                      <title id="sales-report-daily-chart-title">Utilidad y facturado al cliente por día</title>
                      <line :for={tick <- chart_ticks(@daily_totals)} class="sales-report-chart-grid" x1="70" y1={tick.y} x2="970" y2={tick.y} />
                      <text :for={tick <- chart_ticks(@daily_totals)} class="sales-report-chart-y-label" x="62" y={tick.y + 4}><%= tick.label %></text>
                      <line class="sales-report-chart-axis" x1="70" y1="42" x2="70" y2="300" />
                      <line class="sales-report-chart-axis" x1="70" y1="300" x2="970" y2="300" />
                      <path class="sales-report-chart-line" data-series="billed" d={chart_path(@daily_totals, :billed)} />
                      <path class="sales-report-chart-line" data-series="profit" d={chart_path(@daily_totals, :profit)} />
                      <circle :for={point <- chart_points(@daily_totals, :billed)} class="sales-report-chart-dot" data-series="billed" cx={point.x} cy={point.y} r="4.5"><title><%= point.label %> - Facturado: <%= format_money(point.value) %></title></circle>
                      <circle :for={point <- chart_points(@daily_totals, :profit)} class="sales-report-chart-dot" data-series="profit" cx={point.x} cy={point.y} r="4.5"><title><%= point.label %> - Utilidad: <%= format_money(point.value) %></title></circle>
                      <text :for={point <- chart_points(@daily_totals, :profit)} class="sales-report-chart-profit-label" x={point.x} y={point.y - 12}><%= format_compact_money(point.value) %></text>
                      <text :for={point <- chart_label_points(@daily_totals)} class="sales-report-chart-label" x={point.x} y="338" transform={"rotate(-35 #{point.x} 338)"}><%= point.label %></text>
                    </svg>
                  </div>
                </div>
            </nav>
          </div>
        </div>
      </section>
      <script>
        (() => {
          const root = document.currentScript.closest(".dashboard-content") || document;
          const datePicker = root.querySelector("#sales-report-date-picker");
          if (!datePicker || datePicker.dataset.ready) return;
          datePicker.dataset.ready = "true";

          const fromInput = root.querySelector("#report-date-from");
          const toInput = root.querySelector("#report-date-to");
          const trigger = datePicker.querySelector("#invoice-date-range-trigger");
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
            event.stopPropagation();
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
              datePicker.open = true;
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
    <div id="invoice-date-range-dialog" class="invoice-date-popover sales-report-menu sales-report-calendar" role="dialog" aria-modal="false" aria-labelledby="invoice-date-range-title">
      <div class="dialog-content">
        <div class="dialog-header">
          <h2 id="invoice-date-range-title" class="dialog-title">Seleccionar rango de fechas</h2>
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

  defp daily_totals(report, filters) do
    rows_by_date =
      Enum.group_by(report, fn row ->
        case row.fecha do
          %NaiveDateTime{} = value -> NaiveDateTime.to_date(value)
          value -> value
        end
      end)

    filters
    |> chart_dates(rows_by_date)
    |> Enum.map(fn date ->
      rows = Map.get(rows_by_date, date, [])

      %{
        date: date,
        label: format_chart_date(date),
        billed: report_field_total(rows, :facturado_al_cliente),
        profit: report_field_total(rows, :utilidad)
      }
    end)
  end

  defp chart_dates(%{date_from: from, date_to: to}, _rows_by_date) do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.compare(from_date, to_date) != :gt do
      Date.range(from_date, to_date) |> Enum.to_list()
    else
      _ -> []
    end
  end

  defp chart_path([], _field), do: ""

  defp chart_path([_day], _field), do: ""

  defp chart_path(days, field) do
    points = chart_points(days, field)

    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn
      {%{x: x, y: y}, 0} ->
        "M #{x} #{y}"

      {%{x: x, y: y}, index} ->
        previous = Enum.at(points, index - 1)
        control_x = Float.round((numeric_value(previous.x) + numeric_value(x)) / 2, 2)
        "C #{control_x} #{previous.y}, #{control_x} #{y}, #{x} #{y}"
    end)
  end

  defp chart_points(days, field) do
    days
    |> Enum.with_index()
    |> Enum.map(fn {day, index} ->
      %{
        x: chart_x(index, length(days)),
        y: chart_y(Map.get(day, field), days),
        label: day.label,
        value: Map.get(day, field)
      }
    end)
  end

  defp chart_label_points(days) do
    days
    |> Enum.with_index()
    |> Enum.map(fn {day, index} ->
      %{x: chart_x(index, length(days)), label: day.label}
    end)
  end

  defp chart_x(_index, 1), do: 520

  defp chart_x(index, count) do
    Float.round(70 + index * (900 / (count - 1)), 2)
  end

  defp chart_y(value, days) do
    {min_value, max_value} = chart_bounds(days)

    if max_value == min_value do
      171
    else
      Float.round(300 - (numeric_value(value) - min_value) * (258 / (max_value - min_value)), 2)
    end
  end

  defp chart_bounds(days) do
    values =
      days
      |> Enum.flat_map(&[numeric_value(&1.billed), numeric_value(&1.profit), 0.0])

    {Enum.min(values, fn -> 0.0 end), Enum.max(values, fn -> 0.0 end)}
  end

  defp chart_ticks(days) do
    {min_value, max_value} = chart_bounds(days)

    if min_value == max_value do
      [%{y: 300, label: format_compact_money(min_value)}]
    else
      for index <- 0..4 do
        value = min_value + (max_value - min_value) * (index / 4)
        %{y: chart_y(value, days), label: format_compact_money(value)}
      end
      |> Enum.reverse()
    end
  end

  defp report_field_total(report, field) do
    Enum.reduce(report, 0.0, fn row, total -> total + numeric_value(Map.get(row, field)) end)
  end

  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_), do: 0.0

  defp format_number(nil), do: "—"
  defp format_number(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: to_string(value)

  defp format_money(value) do
    amount = numeric_value(value)
    sign = if amount < 0, do: "-", else: ""

    [whole, cents] =
      amount
      |> abs()
      |> :erlang.float_to_binary(decimals: 2)
      |> String.split(".", parts: 2)

    "$ #{sign}#{group_digits(whole)}.#{cents}"
  end

  defp format_compact_money(value) do
    amount = numeric_value(value)
    sign = if amount < 0, do: "-", else: ""
    amount = abs(amount)

    cond do
      amount >= 1_000_000 -> "$ #{sign}#{format_compact_number(amount / 1_000_000)}M"
      amount >= 1_000 -> "$ #{sign}#{format_compact_number(amount / 1_000)}K"
      true -> "$ #{sign}#{format_compact_number(amount)}"
    end
  end

  defp format_compact_number(value) when value >= 100,
    do: :erlang.float_to_binary(value, decimals: 0)

  defp format_compact_number(value) when value >= 10,
    do: :erlang.float_to_binary(value, decimals: 1)

  defp format_compact_number(value),
    do: :erlang.float_to_binary(value, decimals: 0)

  defp group_digits(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_date(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%d/%m/%Y")
  defp format_date(%Date{} = value), do: Calendar.strftime(value, "%d/%m/%Y")
  defp format_date(value), do: to_string(value)

  defp format_chart_date(%Date{} = value), do: Calendar.strftime(value, "%d/%m")
  defp format_chart_date(value), do: to_string(value)

  defp format_time(%NaiveDateTime{} = value) do
    value
    |> Calendar.strftime("%I:%M %p")
    |> String.replace_prefix("0", "")
  end

  defp format_time(_value), do: ""

  defp content_class(%{host: %{content_class: class}}) when is_binary(class) and class != "",
    do: class

  defp content_class(_context), do: "dashboard-content"
end
