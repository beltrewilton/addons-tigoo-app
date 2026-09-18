defmodule PosServer.Addons.SalesSummaryReport do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

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
      name: "Sales Summary Report",
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
    assigns = %{filters: filters, searched?: searched?, filter_error: filter_error, summaries: summaries, content_class: content_class(context)}

    ~H"""
    <div class={@content_class}>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="sales-summary-title">Sales Summary Report</h1></div></header>
      <section class="card dashboard-panel" aria-labelledby="summary-filters-title">
        <div class="card-header"><h2 class="card-title" id="summary-filters-title">Report period</h2></div>
        <form class="card-content form-grid" method="get">
          <div class="form-field"><label class="label" for="summary-date-from">From date</label><input class="input" id="summary-date-from" name="date_from" type="date" value={@filters.date_from} required /></div>
          <div class="form-field"><label class="label" for="summary-date-to">To date</label><input class="input" id="summary-date-to" name="date_to" type="date" value={@filters.date_to} required /></div>
          <div class="form-actions"><button class="btn" data-variant="default" type="submit">Run summary</button></div>
        </form>
        <p :if={@filter_error} class="card-content field-error"><%= @filter_error %></p>
      </section>
      <section :if={@searched?} class="dashboard-summary-grid" aria-label="Sales summary by representative">
        <article :for={summary <- @summaries} class="card dashboard-summary-card">
          <div class="card-header"><p class="card-description">Representative</p><h2 class="card-title"><%= summary.login %></h2></div>
          <div class="card-content"><p class="dashboard-summary-detail">Subtotal: <strong><%= format_currency(summary.subtotal) %></strong></p><p class="dashboard-summary-detail">% tarjeta (3.85%): <strong><%= format_currency(summary.tarjeta) %></strong></p><p class="dashboard-summary-detail">Total: <strong><%= format_currency(summary.total) %></strong></p></div>
        </article>
      </section>
    </div>
    """
  end

  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(value) when is_number(value), do: value
  defp numeric_value(_), do: 0.0

  defp format_currency(value) do
    {sign, amount} = value |> numeric_value() |> :erlang.float_to_binary(decimals: 2) |> split_sign()
    [whole, cents] = String.split(amount, ".", parts: 2)
    "RD$ #{sign}#{group_digits(whole)}.#{cents}"
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
