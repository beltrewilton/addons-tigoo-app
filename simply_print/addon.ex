defmodule PosServer.Addons.SimplyPrint do
  @moduledoc false

  import Ecto.Query
  use Phoenix.Component

  defmodule CompanyRecord do
    use Ecto.Schema

    @primary_key false
    schema "company" do
      field :rnc, :string
      field :company_name, :string
      field :inserted_at, :utc_datetime
    end
  end

  def manifest do
    %{
      identifier: "simply_print",
      name: "Simply Print",
      route: "/pos/addons/simply_print",
      icon: "🖨",
      description: "Print and review the company record connected to this workspace.",
      handler: __MODULE__
    }
  end

  def render(%{tenant: tenant, repo: repo} = context) when is_binary(tenant) and tenant != "" do
    company =
      repo.one(
        from(company in CompanyRecord,
          order_by: [asc: company.inserted_at],
          limit: 1,
          select: %{rnc: company.rnc, company_name: company.company_name}
        ),
        prefix: tenant
      )

    content(%{
      company: company,
      module_name: inspect(__MODULE__),
      content_class: content_class(context)
    })
  end

  def render(context),
    do:
      content(%{
        company: nil,
        module_name: inspect(__MODULE__),
        content_class: content_class(context)
      })

  defp content(assigns) do
    ~H"""
    <div class={@content_class}>
      <header class="dashboard-header"><div><p class="dashboard-kicker">Addon</p><h1 id="simply-print-title">Simply Print</h1></div></header>
      <section class="card dashboard-panel"><div class="card-content"><p>Simply Print is connected to the current tenant.</p></div></section>
      <section class="card dashboard-panel" aria-labelledby="module-title">
        <div class="card-header"><h2 class="card-title" id="module-title">Loaded module</h2></div>
        <div class="card-content"><code><%= @module_name %></code></div>
      </section>
      <section class="card dashboard-panel" aria-labelledby="company-title">
        <div class="card-header"><h2 class="card-title" id="company-title">Connected company</h2></div>
        <div class="card-content">
          <p :if={is_nil(@company)} class="card-description">No company found for this tenant.</p>
          <div :if={@company} class="table-container"><table class="table"><thead><tr class="table-row"><th class="table-head">RNC</th><th class="table-head">Company name</th></tr></thead><tbody><tr class="table-row"><td class="table-cell"><%= @company.rnc || "—" %></td><td class="table-cell"><%= @company.company_name || "—" %></td></tr></tbody></table></div>
        </div>
      </section>
    </div>
    """
  end

  defp content_class(%{host: %{content_class: class}}) when is_binary(class) and class != "",
    do: class

  defp content_class(_context), do: "dashboard-content"
end
