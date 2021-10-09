defmodule Graphism.Plug do
  @moduledoc """
  A convenience plug for Graphism with highly opinionated defaults

  Usage:

  ```
  defmodule MySchema do
    use Graphism.Schema, repo: MyRepo, otp_app: :my_app,

    ...
  end

  defmodule MyEndpoint do
    use Graphism.Plug, schema: MySchema, metrics: "/metrics"

    match _ do
      send_resp(conn, 404, "")
    end
  end
  ```

  This will include a /metrics endpoint with Absinthe prometheus metrics
  based on PromEx
  """

  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)

    quote do
      plug(Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json, Absinthe.Plug.Parser],
        pass: ["*/*"],
        json_decoder: Jason
      )

      plug(:match)
      plug(:dispatch)

      forward("/api", to: Absinthe.Plug, init_opts: [schema: unquote(schema)])

      forward("/graphiql",
        to: Absinthe.Plug.GraphiQL,
        init_opts: [schema: unquote(schema)]
      )
    end
  end
end
