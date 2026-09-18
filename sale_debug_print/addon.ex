defmodule PosServer.Addons.SaleDebugPrint do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

  @event_table "addon_sale_debug_events"

  defmodule SaleDebugEvent do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "addon_sale_debug_events" do
      field :event_name, :string
      field :sale_id, :integer
      field :store_id, :integer
      field :actor_type, :string
      field :actor_login, :string
      field :sale_payload, :string
      field :context_payload, :string

      timestamps(type: :utc_datetime)
    end
  end

  def manifest do
    %{
      identifier: "sale_debug_print",
      name: "Sale Debug Print",
      route: "/pos/addons/sale_debug_print",
      icon: "🧾",
      description: "Prints completed sale event data and stores it in a tenant debug table.",
      handler: __MODULE__,
      events: [:sale_completed]
    }
  end

  def render(%{tenant: tenant, repo: repo} = context) when is_binary(tenant) and tenant != "" do
    ensure_table!(repo, tenant)
    events = recent_events(repo, tenant)

    assigns = %{
      module_name: inspect(__MODULE__),
      events: events,
      content_class: content_class(context)
    }

    content(assigns)
  end

  def render(context) do
    assigns = %{
      module_name: inspect(__MODULE__),
      events: [],
      content_class: content_class(context)
    }

    content(assigns)
  end

  def on_sale_completed(sale, %{tenant: tenant, repo: repo} = context)
      when is_binary(tenant) and tenant != "" do
    safe_context = Map.drop(context, [:repo])

    IO.inspect(
      %{
        sale: sale,
        context: safe_context
      },
      label: "sale_debug_print.on_sale_completed"
    )

    ensure_table!(repo, tenant)

    repo.insert_all(
      SaleDebugEvent,
      [
        %{
          id: Ecto.UUID.generate(),
          event_name: context.event.name |> to_string(),
          sale_id: integer_value(value(sale, :id)),
          store_id: integer_value(value(sale, :store_id) || get_in(context, [:store, :id])),
          actor_type: context.actor.type |> to_string(),
          actor_login: context.actor.login,
          sale_payload: inspect(sale, limit: :infinity, printable_limit: :infinity),
          context_payload: inspect(safe_context, limit: :infinity, printable_limit: :infinity),
          inserted_at: now(),
          updated_at: now()
        }
      ],
      prefix: tenant
    )

    :ok
  end

  def on_sale_completed(sale, context) do
    IO.inspect(
      %{
        sale: sale,
        context: Map.drop(context, [:repo])
      },
      label: "sale_debug_print.on_sale_completed"
    )

    :ok
  end

  defp content(assigns) do
    ~H"""
    <div class={@content_class}>
      <header class="dashboard-header">
        <div>
          <p class="dashboard-kicker">Addon</p>
          <h1 id="sale-debug-print-title">Sale Debug Print</h1>
        </div>
      </header>

      <section class="card dashboard-panel" aria-labelledby="sale-debug-print-status-title">
        <div class="card-header">
          <h2 class="card-title" id="sale-debug-print-status-title">Event listener</h2>
        </div>
        <div class="card-content">
          <p class="card-description">
            This add-on listens for completed sales, prints the payload in the server console, and stores a debug copy in the tenant database.
          </p>
        </div>
      </section>

      <section class="card dashboard-panel" aria-labelledby="events-title">
        <div class="card-header">
          <h2 class="card-title" id="events-title">Recent captured events</h2>
        </div>
        <div class="card-content">
          <p :if={@events == []} class="card-description">No sale events captured yet.</p>
          <div :if={@events != []} class="table-container">
            <table class="table">
              <thead>
                <tr class="table-row">
                  <th class="table-head">Sale</th>
                  <th class="table-head">Store</th>
                  <th class="table-head">Actor</th>
                  <th class="table-head">Captured</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @events} class="table-row">
                  <td class="table-cell"><%= event.sale_id %></td>
                  <td class="table-cell"><%= event.store_id %></td>
                  <td class="table-cell"><%= event.actor_login || event.actor_type %></td>
                  <td class="table-cell"><%= event.inserted_at %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section class="card dashboard-panel" aria-labelledby="module-title">
        <div class="card-header">
          <h2 class="card-title" id="module-title">Loaded module</h2>
        </div>
        <div class="card-content">
          <code><%= @module_name %></code>
        </div>
      </section>
    </div>
    """
  end

  defp ensure_table!(repo, tenant) do
    repo.query!(
      """
      CREATE TABLE IF NOT EXISTS #{quote_identifier(tenant)}.#{quote_identifier(@event_table)} (
        id uuid PRIMARY KEY,
        event_name varchar NOT NULL,
        sale_id integer,
        store_id integer,
        actor_type varchar,
        actor_login varchar,
        sale_payload text NOT NULL,
        context_payload text NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """,
      []
    )
  end

  defp recent_events(repo, tenant) do
    repo.all(
      from(event in SaleDebugEvent,
        order_by: [desc: event.inserted_at],
        limit: 10,
        select: %{
          sale_id: event.sale_id,
          store_id: event.store_id,
          actor_type: event.actor_type,
          actor_login: event.actor_login,
          inserted_at: event.inserted_at
        }
      ),
      prefix: tenant
    )
  end

  defp content_class(%{host: %{content_class: class}}) when is_binary(class) and class != "",
    do: class

  defp content_class(_context), do: "dashboard-content"

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_value, _key), do: nil

  defp quote_identifier(identifier) do
    escaped = identifier |> to_string() |> String.replace("\"", "\"\"")
    "\"" <> escaped <> "\""
  end
end
