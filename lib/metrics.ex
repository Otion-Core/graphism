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

        @absinthe_metrics_prefix [:graphism, :absinthe]
        @ecto_metrics_prefix [:graphism, :ecto]
        @beam_metrics_prefix [:graphism, :beam]
        @application_metrics_prefix [:graphism, :application]
        @prom_ex_metrics_prefix [:graphism, :prom_ex]

        @impl true
        def plugins do
          [
            {Plugins.Absinthe,
             absinthe_entrypoint_tag_value_fun: &entrypoint_tag_value/1,
             metric_prefix: @absinthe_metrics_prefix,
             ignored_entrypoints: [:__schema]},
            {Plugins.Ecto, metric_prefix: @ecto_metrics_prefix},
            {Plugins.Beam, metric_prefix: @beam_metrics_prefix},
            {Plugins.Application, metric_prefix: @application_metrics_prefix},
            {Plugins.PromEx, metric_prefix: @prom_ex_metrics_prefix}
          ]
        end

        @impl true
        def dashboard_assigns do
          [
            datasource_id: unquote(datasource_id),
            plug_absinthe_metric_prefix: Enum.join(@absinthe_metrics_prefix, "_"),
            ecto_metric_prefix: Enum.join(@ecto_metrics_prefix, "_"),
            beam_metric_prefix: Enum.join(@beam_metrics_prefix, "_"),
            application_metric_prefix: Enum.join(@application_metrics_prefix, "_"),
            prom_ex_metric_prefix: Enum.join(@prom_ex_metrics_prefix, "_"),
            otp_app: "#{unquote(otp_app)}"
          ]
        end

        @impl true
        def dashboards do
          [
            {:prom_ex, "absinthe.json", title: "Absinthe"},
            {:prom_ex, "ecto.json", title: "Ecto"},
            {:prom_ex, "beam.json", title: "Beam"},
            {:prom_ex, "application.json", title: "Application"}
          ]
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
