defmodule PosServer.Addons.SalesReportEvofit do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

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
      field :discount, :decimal
      field :quantity, :float
    end
  end

  defmodule Product do
    use Ecto.Schema
    @primary_key {:id, :integer, autogenerate: false}
    schema "product" do
      field :name, :string
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

  def manifest do
    %{
      identifier: "sales_report_evofit",
      name: "Sales Report Evofit",
      route: "/pos/addons/sales_report_evofit",
      icon: "📈",
      description: "Analyze sales by representative, product, customer, and store.",
      handler: __MODULE__
    }
  end

  def render(%{tenant: tenant, repo: repo, params: params} = context) when is_binary(tenant) and tenant != "" do
    filters = %{login: Map.get(params, "login", ""), date_from: Map.get(params, "date_from", ""), date_to: Map.get(params, "date_to", "")}

    case report_params(filters) do
      :blank -> content(page_data(filters, false, nil, [], context))
      {:error, message} -> content(page_data(filters, false, message, [], context))
      {:ok, login, from, to} -> content(page_data(filters, true, nil, report(repo, tenant, login, from, to), context))
    end
  end

  def render(context), do: content(page_data(%{login: "", date_from: "", date_to: ""}, false, "No tenant is connected.", [], context))

  defp report(repo, tenant, login, from, to) do
    repo.all(
      from(sale in Sale,
        join: line in SaleLine, on: line.sale_id == sale.id,
        join: product in Product, on: product.id == line.product_id,
        join: client in Client, on: client.id == sale.client_id,
        join: store in Store, on: store.id == sale.store_id,
        where: sale.status != "RETURN" and sale.login == ^login,
        where: not like(product.code, "4500%"),
        where: sale.date_create >= ^from and sale.date_create <= ^to,
        order_by: [asc: sale.date_create],
        select: %{
          local: store.name,
          representante: sale.login,
          producto: product.name,
          cliente: client.name,
          fecha: sale.date_create,
          precio_original: line.total_amount + line.discount,
          descuento: line.discount,
          facturado_al_cliente: line.total_amount * line.quantity
        }
      ),
      prefix: tenant
    )
  end

  defp report_params(%{login: "", date_from: "", date_to: ""}), do: :blank

  defp report_params(%{login: login, date_from: from, date_to: to}) when login != "" do
    with {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         true <- Date.compare(from_date, to_date) != :gt do
      {:ok, login, NaiveDateTime.new!(from_date, ~T[00:00:00]), NaiveDateTime.new!(to_date, ~T[23:59:59])}
    else
      false -> {:error, "The start date must be on or before the end date."}
      _ -> {:error, "Enter a representative login and valid start and end dates."}
    end
  end

  defp report_params(_), do: {:error, "Enter a representative login and valid start and end dates."}

  defp page_data(filters, searched?, filter_error, report, context) do
    %{
      filters: filters,
      filter_error: filter_error,
      searched?: searched?,
      report: report,
      content_class: content_class(context)
    }
  end

  defp content(assigns) do
    ~H"""
    <div class={@content_class}>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="sales-report-title">Sales Report Evofit</h1></div></header>
      <section class="card dashboard-panel" aria-labelledby="report-filters-title">
        <div class="card-header"><h2 class="card-title" id="report-filters-title">Sales report filters</h2></div>
        <form class="card-content form-grid" method="get">
          <div class="form-field"><label class="label" for="report-login">Representative login</label><input class="input" id="report-login" name="login" type="text" value={@filters.login} required /></div>
          <div class="form-field"><label class="label" for="report-date-from">From date</label><input class="input" id="report-date-from" name="date_from" type="date" value={@filters.date_from} required /></div>
          <div class="form-field"><label class="label" for="report-date-to">To date</label><input class="input" id="report-date-to" name="date_to" type="date" value={@filters.date_to} required /></div>
          <div class="form-actions"><button class="btn" data-variant="default" type="submit">Run report</button></div>
        </form>
        <p :if={@filter_error} class="card-content field-error"><%= @filter_error %></p>
      </section>
      <section :if={@searched?} class="card dashboard-panel" aria-labelledby="report-results-title">
        <div class="card-header"><h2 class="card-title" id="report-results-title">Sales report <span class="card-description">· Billed to client: <%= format_number(report_total(@report)) %></span></h2></div>
        <div class="card-content">
          <p :if={@report == []} class="card-description">No matching sales found.</p>
          <div :if={@report != []} class="table-container"><table class="table"><thead><tr class="table-row"><th class="table-head">Local</th><th class="table-head">Representative</th><th class="table-head">Product</th><th class="table-head">Client</th><th class="table-head">Date</th><th class="table-head">Original price</th><th class="table-head">Discount</th><th class="table-head">Billed to client</th></tr></thead><tbody><tr :for={row <- @report} class="table-row"><td class="table-cell"><%= row.local %></td><td class="table-cell"><%= row.representante %></td><td class="table-cell"><%= row.producto %></td><td class="table-cell"><%= row.cliente %></td><td class="table-cell"><%= row.fecha %></td><td class="table-cell"><%= format_number(row.precio_original) %></td><td class="table-cell"><%= format_number(row.descuento) %></td><td class="table-cell"><%= format_number(row.facturado_al_cliente) %></td></tr></tbody></table></div>
        </div>
      </section>
    </div>
    """
  end

  defp report_total(report) do
    Enum.reduce(report, 0.0, fn row, total -> total + numeric_value(row.facturado_al_cliente) end)
  end

  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_), do: 0.0

  defp format_number(nil), do: "—"
  defp format_number(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: to_string(value)

  defp content_class(%{host: %{content_class: class}}) when is_binary(class) and class != "",
    do: class

  defp content_class(_context), do: "dashboard-content"
end
