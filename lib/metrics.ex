defmodule Graphism.Metrics do
  @moduledoc "Prometheus metrics"

  alias PromEx.Plugins

  def prom_ex_plugin(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    datasource_id = opts[:datasource_id] || "Prometheus"

    quote do
      defmodule Metrics do
        use PromEx, otp_app: unquote(otp_app)
        alias PromEx.Plugins

        @extra_plugins Application.get_env(unquote(otp_app), __MODULE__)[:plugins] || []
        @otp_app_metric_prefix unquote("#{otp_app}_metric_prefix" |> String.to_atom())
        @otp_app unquote(otp_app)
        @extra_dashboard_assigns [
          {@otp_app, "#{@otp_app}"},
          {@otp_app_metric_prefix, "#{@otp_app}"}
        ]

        @extra_dashboards @extra_plugins
                          |> Enum.map(fn {_, opts} ->
                            case opts[:dashboard] do
                              nil ->
                                nil

                              dashboard ->
                                {@otp_app, dashboard,
                                 title:
                                   dashboard
                                   |> String.split("/")
                                   |> List.last()
                                   |> String.split(".")
                                   |> List.first()
                                   |> String.capitalize()}
                            end
                          end)
                          |> Enum.reject(&is_nil/1)

        @absinthe_metric_prefix [:graphism, :absinthe]
        @ecto_metric_prefix [:graphism, :ecto]
        @beam_metric_prefix [:graphism, :beam]
        @application_metric_prefix [:graphism, :application]
        @prom_ex_metric_prefix [:graphism, :prom_ex]

        @impl true
        def plugins do
          [
            {Plugins.Absinthe,
             absinthe_entrypoint_tag_value_fun: &entrypoint_tag_value/1,
             metric_prefix: @absinthe_metric_prefix,
             ignored_entrypoints: [:__schema]},
            {Plugins.Ecto, metric_prefix: @ecto_metric_prefix},
            {Plugins.Beam, metric_prefix: @beam_metric_prefix},
            {Plugins.Application, metric_prefix: @application_metric_prefix},
            {Plugins.PromEx, metric_prefix: @prom_ex_metric_prefix}
          ] ++
            Enum.map(@extra_plugins, fn {module, opts} ->
              {module, metric_prefix: Keyword.fetch!(opts, :metric_prefix)}
            end)
        end

        @impl true
        def dashboard_assigns do
          [
            datasource_id: unquote(datasource_id),
            absinthe_metric_prefix: Enum.join(@absinthe_metric_prefix, "_"),
            ecto_metric_prefix: Enum.join(@ecto_metric_prefix, "_"),
            beam_metric_prefix: Enum.join(@beam_metric_prefix, "_"),
            application_metric_prefix: Enum.join(@application_metric_prefix, "_"),
            prom_ex_metric_prefix: Enum.join(@prom_ex_metric_prefix, "_")
          ] ++ @extra_dashboard_assigns
        end

        @impl true
        def dashboards do
          [
            {:prom_ex, "absinthe.json", title: "Absinthe"},
            {:prom_ex, "ecto.json", title: "Ecto"},
            {:prom_ex, "beam.json", title: "Beam"},
            {:prom_ex, "application.json", title: "Application"}
          ] ++
            @extra_dashboards
        end

        defp entrypoint_tag_value(%{selections: [%{selections: [op | _]} = e | _]}) do
          "#{identifier(e)}/#{identifier(op)}"
        end

        defp entrypoint_tag_value(_), do: "unknown"

        defp identifier(%{name: name}), do: name
        defp identifier(_), do: "unknown"
      end
    end
  end
end
