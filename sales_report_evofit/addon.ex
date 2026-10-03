defmodule PosServer.Addons.SalesReportEvofit do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

  alias Elixlsx.{Workbook, Sheet}

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
      field(:discount, :decimal)
      field(:quantity, :float)
    end
  end

  defmodule Product do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "product" do
      field(:name, :string)
      field(:code, :string)
    end
  end

  defmodule Client do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "client" do
      field(:name, :string)
    end
  end

  defmodule Store do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "app_store" do
      field(:name, :string)
    end
  end

  defmodule User do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "app_users" do
      field(:username, :string)
      field(:first_name, :string)
      field(:last_name, :string)
      field(:is_active, :integer)
    end
  end

  def manifest do
    %{
      identifier: "sales_report_evofit",
      name: "Reporte de Ventas",
      route: "/pos/addons/sales_report_evofit",
      icon: "📈",
      description: "Analyze sales by representative, product, customer, and store.",
      handler: __MODULE__
    }
  end

  def render(%{tenant: tenant, repo: repo, params: params} = context)
      when is_binary(tenant) and tenant != "" do
    filters = %{
      login: selected_logins(Map.get(params, "login", [])),
      date_from: Map.get(params, "date_from", ""),
      date_to: Map.get(params, "date_to", "")
    }

    users = active_users(repo, tenant)

    case report_params(filters) do
      :blank ->
        content(page_data(filters, false, nil, [], users, context))

      {:error, message} ->
        content(page_data(filters, false, message, [], users, context))

      {:ok, logins, from, to} ->
        content(
          page_data(
            filters,
            true,
            nil,
            report(repo, tenant, logins, from, to, users),
            users,
            context
          )
        )
    end
  end

  def render(context),
    do:
      content(
        page_data(
          %{login: [], date_from: "", date_to: ""},
          false,
          "No tenant is connected.",
          [],
          [],
          context
        )
      )

  def export(%{tenant: tenant, repo: repo, params: params}) when is_binary(tenant) and tenant != "" do
    filters = %{
      login: selected_logins(Map.get(params, "login", [])),
      date_from: Map.get(params, "date_from", ""),
      date_to: Map.get(params, "date_to", "")
    }

    users = active_users(repo, tenant)

    with {:ok, logins, from, to} <- report_params(filters),
         report <- report(repo, tenant, logins, from, to, users),
         workbook <- sales_report_workbook(report, filters),
         filename <- export_filename(filters),
         {:ok, {_name, binary}} <- Elixlsx.write_to_memory(workbook, filename) do
      {:download, filename, binary, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
    else
      _ -> {:error, :invalid_export_filters}
    end
  end

  def export(_context), do: {:error, :invalid_export_filters}

  defp report(repo, tenant, logins, from, to, users) do
    names_by_login = Map.new(users, &{&1.login, &1.name})

    repo.all(
      from(sale in Sale,
        join: line in SaleLine,
        on: line.sale_id == sale.id,
        join: product in Product,
        on: product.id == line.product_id,
        join: client in Client,
        on: client.id == sale.client_id,
        join: store in Store,
        on: store.id == sale.store_id,
        where: sale.status != "RETURN" and sale.login in ^logins,
        where: not like(product.code, "4500%"),
        where: sale.date_create >= ^from and sale.date_create <= ^to,
        order_by: [asc: sale.date_create, asc: client.name],
        select: %{
          local: store.name,
          login: sale.login,
          representante: sale.login,
          producto: product.name,
          cliente: client.name,
          fecha: sale.date_create,
          precio_original: line.total_amount + line.discount,
          descuento: line.discount,
          facturado_al_cliente: line.total_amount
        }
      ),
      prefix: tenant
    )
    |> Enum.map(fn row ->
      %{row | representante: Map.get(names_by_login, row.login, row.login)}
    end)
  end

  defp active_users(repo, tenant) do
    repo.all(
      from(user in User,
        where: user.is_active == 1,
        order_by: [asc: user.first_name, asc: user.last_name, asc: user.username],
        select: %{
          login: user.username,
          name:
            fragment(
              "trim(concat(coalesce(?, ''), ' ', coalesce(?, '')))",
              user.first_name,
              user.last_name
            )
        }
      ),
      prefix: tenant
    )
    |> Enum.map(fn user ->
      %{user | name: if(user.name == "", do: user.login, else: user.name)}
    end)
  end

  defp report_params(%{login: [], date_from: "", date_to: ""}), do: :blank

  defp report_params(%{login: logins, date_from: from, date_to: to})
       when is_list(logins) and logins != [] do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.compare(from_date, to_date) != :gt do
      {:ok, logins, NaiveDateTime.new!(from_date, ~T[00:00:00]),
       NaiveDateTime.new!(to_date, ~T[23:59:59])}
    else
      false -> {:error, "The start date must be on or before the end date."}
      _ -> {:error, "Seleccione al menos un representante y un rango de fechas válido."}
    end
  end

  defp report_params(_),
    do: {:error, "Seleccione al menos un representante y un rango de fechas válido."}

  defp page_data(filters, searched?, filter_error, report, users, context) do
    %{
      filters: filters,
      filter_error: filter_error,
      searched?: searched?,
      report: report,
      users: users,
      reports_by_user: reports_by_user(report),
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
        .sales-report-filter-card { overflow: visible; }
        .sales-report-filter-card .card-content { overflow: visible; }
        .sales-report-filters { display: grid; grid-template-columns: minmax(240px, 1fr) auto auto; align-items: end; gap: .75rem; position: relative; z-index: 10; }
        .sales-report-picker { position: relative; }
        .sales-report-picker > .label { display: block; margin-bottom: .35rem; }
        .sales-report-picker summary { list-style: none; }
        .sales-report-picker summary::-webkit-details-marker { display: none; }
        .sales-report-trigger { width: 100%; min-width: 260px; justify-content: flex-start; }
        .sales-report-menu { position: absolute; left: 0; top: calc(100% + .5rem); z-index: 5; width: min(420px, 90vw); padding: .75rem; border: 1px solid var(--border); border-radius: var(--radius); background: var(--background); box-shadow: var(--shadow-lg, 0 12px 32px rgb(0 0 0 / .14)); }
        .sales-report-user-list { display: grid; gap: .35rem; max-height: 18rem; overflow: auto; }
        .sales-report-user-option { display: flex; align-items: center; gap: .5rem; padding: .45rem .5rem; border-radius: calc(var(--radius) - 2px); cursor: pointer; }
        .sales-report-user-option:hover { background: var(--muted); }
        .sales-report-calendar { left: auto; right: 0; width: min(704px, calc(100vw - 2rem)); max-height: min(78vh, 720px); overflow: auto; }
        .sales-report-calendar .calendar-day { font-size: 1rem; }
        .sales-report-calendar-fields { display: none; }
        @media (max-width: 760px) { .sales-report-filters { grid-template-columns: 1fr; } .sales-report-trigger { min-width: 0; } .sales-report-menu { position: static; width: 100%; margin-top: .5rem; } }
      </style>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="sales-report-title">REPORTE DE VENTAS</h1></div></header>
      <section class="card dashboard-panel sales-report-filter-card" aria-label="Filtros del reporte de ventas">
        <form id="sales-report-filters" class="card-content sales-report-filters" method="get">
          <div class="form-field">
            <label class="label" for="report-user-picker">Representante</label>
            <details class="sales-report-picker" id="report-user-picker">
              <summary class="btn sales-report-trigger" data-variant="outline"><%= selected_user_label(@users, @filters.login) %></summary>
              <div class="sales-report-menu">
                <div class="sales-report-user-list">
                  <label :for={user <- @users} class="sales-report-user-option">
                    <input type="checkbox" name="login[]" value={user.login} checked={user.login in @filters.login} />
                    <span><%= user.name %></span>
                  </label>
                </div>
              </div>
            </details>
          </div>
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
        <div :if={@searched? && @report != []} class="card-footer">
          <a class="btn" data-variant="outline" href={export_href(@filters)}>Exportar XLSX</a>
        </div>
        <p :if={@filter_error} class="card-content field-error"><%= @filter_error %></p>
      </section>
      <section :if={@searched?} class="card dashboard-panel" aria-label="Resultados del reporte de ventas">
        <div class="card-content">
          <p :if={@report == []} class="card-description">No se encontraron ventas.</p>
          <div :if={@report != []} class="sales-report-tabs">
            <nav aria-label="Reportes por representante" role="tablist">
              <%= for {group, index} <- Enum.with_index(@reports_by_user) do %>
                <input type="radio" id={"sales-report-tab-#{index}"} name="sales-report-tab" checked={index == 0} />
                <label class="btn" data-variant="ghost" role="tab" for={"sales-report-tab-#{index}"}><%= String.upcase(group.name) %></label>
                <div class="sales-report-tab-panel">
                  <div class="table-container sales-report-table-container"><table class="table"><thead><tr class="table-row"><th class="table-head">LOCAL</th><th class="table-head">PRODUCTO</th><th class="table-head">CLIENTE</th><th class="table-head">FECHA</th><th class="table-head">PRECIO ORIGINAL</th><th class="table-head"><span class="sales-report-total-label">DESCUENTO</span><span class="sales-report-total-value"><%= format_money(report_field_total(group.rows, :descuento)) %></span></th><th class="table-head"><span class="sales-report-total-label">FACTURADO AL CLIENTE</span><span class="sales-report-total-value"><%= format_money(report_field_total(group.rows, :facturado_al_cliente)) %></span></th></tr></thead><tbody><tr :for={row <- group.rows} class="table-row"><td class="table-cell"><%= row.local %></td><td class="table-cell"><%= row.producto %></td><td class="table-cell"><%= row.cliente %></td><td class="table-cell"><span><%= format_date(row.fecha) %></span><br /><small><%= format_time(row.fecha) %></small></td><td class="table-cell"><%= format_number(row.precio_original) %></td><td class="table-cell"><%= format_number(row.descuento) %></td><td class="table-cell"><%= format_number(row.facturado_al_cliente) %></td></tr></tbody><tfoot><tr class="table-row"><td class="table-cell" colspan="5"><strong>TOTAL</strong></td><td class="table-cell"><strong><%= format_money(report_field_total(group.rows, :descuento)) %></strong></td><td class="table-cell"><strong><%= format_money(report_field_total(group.rows, :facturado_al_cliente)) %></strong></td></tr></tfoot></table></div>
                </div>
              <% end %>
            </nav>
          </div>
        </div>
      </section>
      <script>
        (() => {
          const root = document.currentScript.closest(".dashboard-content") || document;
          const datePicker = root.querySelector("#sales-report-date-picker");
          const userPicker = root.querySelector("#report-user-picker");
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
            if (userPicker && !userPicker.contains(event.target)) userPicker.open = false;
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

  defp selected_logins(logins) when is_list(logins), do: Enum.reject(logins, &(&1 in [nil, ""]))
  defp selected_logins(login) when is_binary(login) and login != "", do: [login]
  defp selected_logins(_), do: []

  defp selected_user_label(users, logins) do
    selected =
      users
      |> Enum.filter(&(&1.login in logins))
      |> Enum.map(& &1.name)

    case selected do
      [] -> "Seleccionar representantes"
      [name] -> name
      names -> "#{length(names)} representantes seleccionados"
    end
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

  defp reports_by_user(report) do
    report
    |> Enum.group_by(& &1.login)
    |> Enum.map(fn {_login, rows} ->
      %{name: rows |> hd() |> Map.fetch!(:representante), rows: rows}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp sales_report_workbook([], filters) do
    %Workbook{}
    |> Workbook.append_sheet(empty_report_sheet(filters))
  end

  defp sales_report_workbook(report, filters) do
    report
    |> reports_by_user()
    |> Enum.with_index(1)
    |> Enum.reduce(%Workbook{}, fn {group, index}, workbook ->
      Workbook.append_sheet(workbook, report_sheet(group, filters, index))
    end)
  end

  defp empty_report_sheet(filters) do
    %Sheet{name: "Sin resultados", rows: [[report_title_cell()], [report_subtitle_cell(range_label(filters.date_from, filters.date_to))], [], [["Sin resultados para los filtros seleccionados.", italic: true, color: "#6B7280"]]]}
    |> merge_report_header()
    |> Sheet.set_row_height(1, 26)
    |> Sheet.set_row_height(2, 22)
    |> Sheet.set_row_height(3, 20)
    |> Sheet.set_col_width("A", 36)
  end

  defp report_sheet(group, filters, index) do
    discount_total = report_field_total(group.rows, :descuento)
    billed_total = report_field_total(group.rows, :facturado_al_cliente)

    rows =
      [
        [report_title_cell()],
        [representative_title_cell(group.name)],
        [report_subtitle_cell(range_label(filters.date_from, filters.date_to))],
        [],
        header_row(),
        totals_row(discount_total, billed_total)
      ] ++ Enum.map(group.rows, &xlsx_row/1) ++ [[], totals_row(discount_total, billed_total)]

    %Sheet{name: sheet_name(group.name, index), rows: rows}
    |> merge_report_header()
    |> Sheet.set_pane_freeze(6, 0)
    |> Sheet.set_row_height(1, 28)
    |> Sheet.set_row_height(2, 23)
    |> Sheet.set_row_height(3, 21)
    |> Sheet.set_row_height(5, 22)
    |> Sheet.set_row_height(6, 22)
    |> Sheet.set_col_width("A", 18)
    |> Sheet.set_col_width("B", 42)
    |> Sheet.set_col_width("C", 34)
    |> Sheet.set_col_width("D", 14)
    |> Sheet.set_col_width("E", 12)
    |> Sheet.set_col_width("F", 18)
    |> Sheet.set_col_width("G", 17)
    |> Sheet.set_col_width("H", 24)
  end

  defp merge_report_header(sheet) do
    %{sheet | merge_cells: [{"A1", "H1"}, {"A2", "H2"}, {"A3", "H3"}]}
  end

  defp header_row do
    [
      header_cell("LOCAL"),
      header_cell("PRODUCTO"),
      header_cell("CLIENTE"),
      header_cell("FECHA"),
      header_cell("HORA"),
      header_cell("PRECIO ORIGINAL"),
      header_cell("DESCUENTO"),
      header_cell("FACTURADO AL CLIENTE")
    ]
  end

  defp totals_row(discount_total, billed_total) do
    [
      ["TOTAL", bold: true, color: "#111827", bg_color: "#D1FAE5"],
      ["", bg_color: "#D1FAE5"],
      ["", bg_color: "#D1FAE5"],
      ["", bg_color: "#D1FAE5"],
      ["", bg_color: "#D1FAE5"],
      ["", bg_color: "#D1FAE5"],
      [numeric_value(discount_total), bold: true, num_format: "$#,##0.00", bg_color: "#D1FAE5", align_horizontal: :right],
      [numeric_value(billed_total), bold: true, num_format: "$#,##0.00", bg_color: "#D1FAE5", align_horizontal: :right]
    ]
  end

  defp xlsx_row(row) do
    [
      row.local,
      row.producto,
      row.cliente,
      format_date(row.fecha),
      format_time(row.fecha),
      money_cell(row.precio_original),
      money_cell(row.descuento),
      money_cell(row.facturado_al_cliente)
    ]
  end

  defp money_cell(value), do: [numeric_value(value), num_format: "$#,##0.00", align_horizontal: :right]

  defp report_title_cell,
    do: ["REPORTE DE VENTAS", bold: true, size: 18, color: "#FFFFFF", bg_color: "#111827", align_horizontal: :center, align_vertical: :center]

  defp representative_title_cell(name),
    do: [String.upcase(name), bold: true, size: 13, color: "#047857", bg_color: "#ECFDF5", align_horizontal: :center, align_vertical: :center]

  defp report_subtitle_cell(value),
    do: [value, italic: true, color: "#6B7280", bg_color: "#F9FAFB", align_horizontal: :center, align_vertical: :center]

  defp header_cell(value),
    do: [value, bold: true, color: "#FFFFFF", bg_color: "#047857", align_horizontal: :center, align_vertical: :center]

  defp export_href(filters) do
    query =
      [{"date_from", filters.date_from}, {"date_to", filters.date_to}, {"export", "xlsx"}] ++
        Enum.map(filters.login, &{"login[]", &1})

    "/pos/addons/sales_report_evofit?#{URI.encode_query(query)}"
  end

  defp export_filename(filters) do
    from = String.replace(filters.date_from || "desde", "-", "")
    to = String.replace(filters.date_to || "hasta", "-", "")
    "reporte_ventas_#{from}_#{to}.xlsx"
  end

  defp sheet_name(name, index) do
    cleaned =
      name
      |> to_string()
      |> String.replace(~r/[\[\]\*\/\\\?\:]/, "")
      |> String.trim()

    base = if cleaned == "", do: "Representante #{index}", else: cleaned
    String.slice(base, 0, 31)
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

  defp group_digits(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_date(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%d/%m/%Y")
  defp format_date(value), do: to_string(value)

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
