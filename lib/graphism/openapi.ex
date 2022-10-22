defmodule Graphism.Openapi do
  @moduledoc "Generates a OpenApi Spec"

  alias Graphism.{Entity, Route}

  def module_name(caller_module, suffix \\ OpenApi) do
    Module.concat([caller_module, suffix])
  end

  def spec_module(schema, caller_module) do
    module_name = module_name(caller_module)
    openapi = openapi(schema)

    quote do
      defmodule unquote(module_name) do
        @behaviour Plug
        @json "application/json"
        @openapi unquote(openapi)
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          conn
          |> put_resp_content_type(@json)
          |> send_resp(200, @openapi)
        end
      end
    end
  end

  def redocui_module(caller_module) do
    module_name = module_name(caller_module, RedocUI)

    quote do
      defmodule unquote(module_name) do
        @behaviour Plug
        import Plug.Conn

        @index_html """
        <!doctype html>
        <html>
          <head>
            <title>ReDoc</title
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <link href="https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700" rel="stylesheet">
          </head>
          <body>
            <redoc spec-url="<%= spec_url %>"></redoc>
            <script src="https://cdn.jsdelivr.net/npm/redoc@latest/bundles/redoc.standalone.js"></script>
          </body>
        </html>
        """

        @impl true
        def init(opts) do
          [html: EEx.eval_string(@index_html, opts)]
        end

        @impl true
        def call(conn, html: html) do
          send_resp(conn, 200, html)
        end
      end
    end
  end

  defp operation_id(e, action), do: Inflex.camelize("#{e[:name]}_#{action}", :lower)
  defp aggregate_operation_id(e, action), do: Inflex.camelize("aggregate_#{e[:name]}_by_#{action}", :lower)

  def join_fields(key), do: Enum.join(key[:fields], "_and_")

  defp openapi(schema) do
    %{
      openapi: "3.0.0",
      info: %{
        version: "1.0.0",
        title: "",
        license: %{name: "MIT"}
      },
      servers: [
        %{url: "http://localhost:4001/api", description: "Local"}
      ],
      paths: %{},
      components: %{},
      security: []
    }
    |> with_schemas(schema)
    |> with_paths(schema)
    |> with_security(schema)
    |> Jason.encode!()
  end

  defp with_schemas(spec, schema) do
    schemas =
      Enum.reduce(schema, %{}, fn e, schemas ->
        schemas
        |> with_id_schema(e, schema)
        |> with_view_schema(e, schema)
        |> with_create_schema(e, schema)
        |> with_update_schema(e, schema)
        |> with_list_schema(e, schema)
        |> with_custom_schemas(e, schema)
      end)
      |> with_aggregation_schema()
      |> with_unit_schema()
      |> with_error_schema()
      |> with_errors_schema()
      |> with_free_form_object_schema()

    put_in(spec, [:components, :schemas], schemas)
  end

  defp with_id_schema(schemas, e, _schema) do
    Map.put(schemas, id_schema(e), %{
      type: :object,
      required: [:id],
      properties: %{
        id: type(:id, nil, nil)
      }
    })
  end

  defp with_view_schema(schemas, e, schema) do
    Map.put(schemas, view_schema(e), %{
      type: :object,
      required: e |> Entity.required_attributes() |> Entity.names(),
      properties:
        e
        |> Entity.all_fields()
        |> Enum.reject(fn f -> f[:kind] == :has_many end)
        |> Enum.reduce(%{}, fn f, props ->
          Map.put(props, f[:name], field_type(f, schema))
        end)
    })
  end

  defp with_create_schema(schemas, e, schema) do
    Map.put(schemas, create_schema(e), %{
      type: :object,
      required: e |> Entity.required_fields() |> Enum.reject(fn f -> f[:name] == :id end) |> Entity.names(),
      properties:
        e
        |> Entity.required_fields()
        |> Enum.reject(fn f -> f[:kind] == :has_many end)
        |> Enum.reject(fn f -> f[:name] == :id end)
        |> Enum.map(fn f ->
          case f[:kind] do
            :belongs_to -> Keyword.put(f, :kind, :id)
            _ -> f
          end
        end)
        |> Enum.reduce(%{}, fn f, props ->
          Map.put(props, f[:name], field_type(f, schema))
        end)
    })
  end

  defp with_update_schema(schemas, e, schema) do
    Map.put(schemas, update_schema(e), %{
      type: :object,
      properties:
        e
        |> Entity.required_fields()
        |> Enum.reject(fn f -> f[:kind] == :has_many end)
        |> Enum.reject(fn f -> f[:name] == :id end)
        |> Enum.map(fn f ->
          case f[:kind] do
            :belongs_to -> Keyword.put(f, :kind, :id)
            _ -> f
          end
        end)
        |> Enum.reduce(%{}, fn f, props ->
          Map.put(props, f[:name], field_type(f, schema))
        end)
    })
  end

  defp with_list_schema(schemas, e, _schema) do
    Map.put(schemas, e[:plural_camel_name], %{
      type: :array,
      items: %{
        "$ref": "#/components/schemas/#{e[:camel_name]}"
      }
    })
  end

  defp with_custom_schemas(schemas, e, _schema) do
    e
    |> Entity.custom_mutations()
    |> Enum.reduce(schemas, fn {action, opts}, schemas ->
      action_name = identifier(action)
      args = custom_action_args(opts)

      Map.put(schemas, custom_schema(e, action_name), %{
        type: :object,
        required: args |> Enum.map(fn {name, _} -> name end) |> Enum.map(&identifier/1),
        properties:
          Enum.reduce(args, %{}, fn {name, kind}, props ->
            Map.put(props, identifier(name), type(kind, nil, nil))
          end)
      })
    end)
  end

  defp with_aggregation_schema(schemas) do
    Map.put(schemas, :aggregation, %{
      type: :object,
      required: [:count],
      properties: %{
        count: %{type: :integer}
      }
    })
  end

  defp with_unit_schema(schemas) do
    Map.put(schemas, :unit, %{
      type: :object,
      required: [],
      properties: %{}
    })
  end

  defp with_errors_schema(schemas) do
    Map.put(schemas, :errors, %{
      type: :object,
      required: [:reason],
      properties: %{
        reason: %{
          type: :array,
          items: %{
            "$ref": "#/components/schemas/error"
          }
        }
      }
    })
  end

  defp with_free_form_object_schema(schemas) do
    Map.put(schemas, :freeFormObject, %{
      type: :object,
      additionalProperties: true
    })
  end

  defp with_error_schema(schemas) do
    Map.put(schemas, :error, %{
      type: :object,
      required: [:detail],
      properties: %{
        detail: %{type: :string},
        field: %{type: :string}
      }
    })
  end

  defp with_paths(spec, schema) do
    paths =
      Enum.reduce(schema, %{}, fn e, paths ->
        paths
        |> Map.put(Route.for_item(e), item_paths(e))
        |> Map.put(Route.for_collection(e), collection_paths(e))
        |> Map.put(Route.for_aggregation(e), aggregation_path(e))
        |> with_children_paths(e, schema)
        |> with_non_unique_keys_paths(e, schema)
        |> with_unique_keys_paths(e, schema)
        |> with_custom_queries_paths(e, schema)
        |> with_custom_actions_paths(e, schema)
      end)

    put_in(spec, [:paths], paths)
  end

  defp with_security(spec, _schema) do
    bearer = %{
      bearerAuth: %{
        type: :http,
        scheme: :bearer,
        bearerFormat: :JWT
      }
    }

    spec
    |> put_in([:components, :securitySchemes], bearer)
    |> put_in([:security], [%{bearerAuth: []}])
  end

  defp item_paths(e) do
    %{}
    |> maybe_with_read_path(e)
    |> maybe_with_update_path(e)
    |> maybe_with_delete_path(e)
  end

  defp collection_paths(e) do
    %{}
    |> maybe_with_list_path(e)
    |> maybe_with_create_path(e)
  end

  defp aggregation_path(e) do
    %{
      get: %{
        summary: "Aggregate a collection of #{e[:plural_camel_name]}",
        operationId: "aggregate#{e[:plural]}",
        tags: [e[:plural_camel_name]],
        parameters: [],
        responses: aggregation_responses(e)
      }
    }
  end

  defp with_children_paths(paths, e, schema) do
    e
    |> Entity.relations()
    |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
    |> Enum.reduce(paths, fn rel, acc ->
      route = Route.for_children(e, rel)
      aggregation_route = Route.for_children_aggregation(e, rel)
      target = Entity.find_entity!(schema, rel[:target])

      acc
      |> Map.put(route, %{
        get: %{
          summary: "List multiple #{target[:plural_camel_name]} by #{e[:camel_name]}",
          operationId: "list#{target[:plural]}By#{e[:display_name]}",
          tags: [target[:plural_camel_name]],
          parameters:
            []
            |> with_id_parameter(e)
            |> with_pagination_parameters(),
          responses: responses(target, plural: true)
        }
      })
      |> Map.put(aggregation_route, %{
        get: %{
          summary: "Aggregate multiple #{target[:plural_camel_name]} for a given #{e[:camel_name]}",
          operationId: "aggregate#{target[:plural]}By#{e[:display_name]}",
          tags: [target[:plural_camel_name]],
          parameters: with_id_parameter([], e),
          responses: aggregation_responses(e)
        }
      })
    end)
  end

  defp with_non_unique_keys_paths(paths, e, _schema) do
    e
    |> Entity.non_unique_keys()
    |> Enum.reduce(paths, fn key, paths ->
      fields = Enum.join(key[:fields], " and ")
      route = Route.for_key(e, key)
      params = key_params(e, key)
      aggregation_route = Route.for_key_aggregation(e, key)

      paths
      |> Map.put(route, %{
        get: %{
          summary: "List multiple #{e[:plural_camel_name]} by #{fields}",
          operationId: "list#{e[:plural]}By#{Inflex.camelize(fields)}",
          tags: [e[:plural_camel_name]],
          parameters: with_pagination_parameters(params),
          responses: responses(e, plural: true)
        }
      })
      |> Map.put(aggregation_route, %{
        get: %{
          summary: "Aggregate multiple #{e[:plural_camel_name]} by #{fields}",
          operationId: "aggregate#{e[:plural]}By#{Inflex.camelize(fields)}",
          tags: [e[:plural_camel_name]],
          parameters: params,
          responses: aggregation_responses(e)
        }
      })
    end)
  end

  defp with_unique_keys_paths(paths, e, _schema) do
    e
    |> Entity.unique_keys_and_attributes()
    |> Enum.reduce(paths, fn key, paths ->
      fields = Enum.join(key[:fields], " and ")
      route = Route.for_key(e, key)
      params = key_params(e, key)

      Map.put(paths, route, %{
        get: %{
          summary: "Read a single #{e[:camel_name]} by #{fields}",
          operationId: "read#{e[:camel_name]}By#{Inflex.camelize(fields)}",
          tags: [e[:camel_name]],
          parameters: params,
          responses: responses(e)
        }
      })
    end)
  end

  defp key_params(e, key) do
    key[:fields]
    |> Enum.reduce([], fn field, params ->
      name = key_parameter_name(field, e)
      kind = key_parameter_type(field, e)
      description = key_parameter_description(field, e)

      with_path_parameter(params, name, kind, true, description)
    end)
    |> Enum.reverse()
  end

  defp with_custom_queries_paths(paths, e, _schema) do
    e
    |> Entity.custom_queries()
    |> Enum.filter(&Entity.produces_multiple_results?/1)
    |> Enum.reduce(paths, fn {action, opts}, paths ->
      args = custom_action_args(opts)
      arg_names = Enum.map(args, fn {name, _} -> name end)

      path = Route.for_action(e, action, arg_names)
      aggregation_path = Route.for_action_aggregation(e, action, arg_names)
      description = Keyword.fetch!(opts, :desc)

      params =
        args
        |> Enum.reduce([], fn {name, kind}, params ->
          description = "A value of type #{kind}"
          with_path_parameter(params, name, kind, true, description)
        end)
        |> Enum.reverse()

      paths
      |> Map.put(path, %{
        get: %{
          summary: description,
          operationId: operation_id(e, action),
          tags: [e[:plural_camel_name]],
          parameters:
            params
            |> with_pagination_parameters(),
          responses: responses(e, plural: true)
        }
      })
      |> Map.put(aggregation_path, %{
        get: %{
          summary: "Aggregate #{description}",
          operationId: aggregate_operation_id(e, action),
          tags: [e[:plural_camel_name]],
          parameters: params,
          responses: aggregation_responses(e)
        }
      })
    end)
  end

  defp with_custom_actions_paths(paths, e, schema) do
    e
    |> Entity.custom_mutations()
    |> Enum.reduce(paths, fn {action, opts}, paths ->
      path = Route.for_action(e, action)
      description = Keyword.fetch!(opts, :desc)
      produces = Keyword.fetch!(opts, :produces)

      {tag, responses} =
        case produces do
          :unit ->
            {e[:plural_camel_name], responses()}

          {:list, entity} ->
            produces = Entity.find_entity!(schema, entity)
            {produces[:plural_camel_name], responses(produces, plural: true)}

          entity ->
            produces = Entity.find_entity!(schema, entity)
            {produces[:camel_name], responses(produces)}
        end

      Map.put(paths, path, %{
        post: %{
          summary: description,
          operationId: operation_id(e, action),
          tags: [tag],
          parameters: [],
          requestBody: %{
            description: "Info required execute action #{description}",
            required: true,
            content: %{
              application_json: %{
                schema: %{
                  "$ref": "#/components/schemas/#{custom_schema(e, action)}"
                }
              }
            }
          },
          responses: responses
        }
      })
    end)
  end

  defp custom_action_args(opts) do
    Enum.map(opts[:args] || [], fn
      {name, kind} -> {name, kind}
      name -> {name, :kind}
    end)
  end

  defp key_parameter_name(field, _e), do: identifier(field)

  defp key_parameter_type(field, e) do
    case Entity.attribute_or_relation(e, field) do
      {:attribute, opts} -> opts[:kind]
      {:relation, _} -> :id
    end
  end

  defp key_parameter_description(field, e) do
    case Entity.attribute_or_relation(e, field) do
      {:attribute, _} -> "The #{identifier(field)} of a #{e[:camel_name]}"
      {:relation, opts} -> "The id of a #{identifier(opts[:target])}"
    end
  end

  defp maybe_with_read_path(paths, e) do
    case Entity.find_action(e, :read) do
      nil ->
        paths

      _action ->
        Map.put(paths, :get, %{
          summary: "Read a single #{e[:camel_name]}",
          operationId: "read#{e[:display_name]}",
          tags: [e[:camel_name]],
          parameters: with_id_parameter([], e),
          responses: responses(e)
        })
    end
  end

  defp maybe_with_update_path(paths, e) do
    case Entity.find_action(e, :update) do
      nil ->
        paths

      _action ->
        Map.put(paths, :put, %{
          summary: "Update an existing #{e[:camel_name]}",
          operationId: "update#{e[:display_name]}",
          tags: [e[:camel_name]],
          parameters: with_id_parameter([], e),
          requestBody: %{
            description: "Info required to update an existing #{e[:camel_name]}",
            required: true,
            content: %{
              application_json: %{
                schema: %{
                  "$ref": "#/components/schemas/#{update_schema(e)}"
                }
              }
            }
          },
          responses: responses(e)
        })
    end
  end

  defp update_schema(e), do: "#{e[:camel_name]}Update"

  defp maybe_with_delete_path(paths, e) do
    case Entity.find_action(e, :delete) do
      nil ->
        paths

      _action ->
        Map.put(paths, :delete, %{
          summary: "Delete an existing #{e[:camel_name]}",
          operationId: "delete#{e[:display_name]}",
          tags: [e[:camel_name]],
          parameters: with_id_parameter([], e),
          responses: responses()
        })
    end
  end

  defp maybe_with_list_path(paths, e) do
    case Entity.find_action(e, :list) do
      nil ->
        paths

      _action ->
        Map.put(paths, :get, %{
          summary: "List multiple #{e[:plural_camel_name]}",
          operationId: "list#{e[:display_name]}",
          tags: [e[:plural_camel_name]],
          parameters: with_pagination_parameters([]),
          responses: responses(e, plural: true)
        })
    end
  end

  defp maybe_with_create_path(paths, e) do
    case Entity.find_action(e, :create) do
      nil ->
        paths

      _action ->
        Map.put(paths, :post, %{
          summary: "Create a new #{e[:camel_name]}",
          operationId: "create#{e[:display_name]}",
          tags: [e[:camel_name]],
          parameters: [],
          requestBody: %{
            description: "Info required to create a new #{e[:camel_name]}",
            required: true,
            content: %{
              application_json: %{
                schema: %{
                  "$ref": "#/components/schemas/#{create_schema(e)}"
                }
              }
            }
          },
          responses: responses(e, success_status: 201, plural: true)
        })
    end
  end

  defp create_schema(e), do: custom_schema(e, "Create")
  defp custom_schema(e, action), do: "#{e[:camel_name]}#{Inflex.camelize(action)}"

  defp with_pagination_parameters(params) do
    params
    |> with_query_parameter(:limit, :integer, false, "The number of items to return")
    |> with_query_parameter(:offset, :integer, false, "The position where to start fetching items from")
    |> with_query_parameter(:sort, :string, false, "The field to sort items by")
    |> with_query_parameter(
      :sort_direction,
      :sort_direction,
      false,
      "Whether to sort items in ascending or descending order"
    )
  end

  defp with_id_parameter(params, e) do
    with_path_parameter(params, :id, :id, true, "The id of the #{e[:camel_name]}")
  end

  defp with_path_parameter(params, name, kind, required, desc) do
    with_parameter(params, name: name, in: :path, kind: kind, required: required, description: desc)
  end

  defp with_query_parameter(params, name, kind, required, desc) do
    with_parameter(params, name: name, in: :query, kind: kind, required: required, description: desc)
  end

  defp with_parameter(params, opts) do
    name = opts |> Keyword.fetch!(:name) |> Inflex.camelize(:lower)
    kind = Keyword.fetch!(opts, :kind)
    where = Keyword.fetch!(opts, :in)
    desc = Keyword.fetch!(opts, :description)
    required = Keyword.get(opts, :required, true)

    [
      %{
        name: name,
        in: where,
        required: required,
        description: desc,
        schema: type(kind, nil, nil)
      }
      | params
    ]
  end

  defp responses do
    error_responses()
    |> Map.put(:"200", unit_response())
  end

  defp responses(e, opts \\ []) do
    error_responses()
    |> Map.put(opts[:success_status] || :"200", success_response(e, opts))
  end

  defp error_responses do
    %{
      "400": invalid_response(),
      "401": unauthorized_response(),
      "404": not_found_response(),
      "409": conflict_response(),
      "429": too_many_requests_response(),
      "500": server_error_response()
    }
  end

  defp success_response(e, opts) do
    schema =
      case opts[:plural] do
        nil -> e[:camel_name]
        true -> e[:plural_camel_name]
      end

    %{
      description: "Successful operation",
      content: %{
        "application/json": %{
          schema: %{
            "$ref": "#/components/schemas/#{schema}"
          }
        }
      }
    }
  end

  defp unit_response do
    %{
      description: "Successful operation",
      content: %{
        "application/json": %{
          schema: %{
            "$ref": "#/components/schemas/unit"
          }
        }
      }
    }
  end

  defp aggregation_responses(e) do
    %{
      "200": aggregation_successful_response(e),
      "429": too_many_requests_response(),
      "500": server_error_response()
    }
  end

  defp aggregation_successful_response(_e) do
    %{
      description: "Successful operation",
      content: %{
        "application/json": %{
          schema: %{
            "$ref": "#/components/schemas/aggregation"
          }
        }
      }
    }
  end

  defp not_found_response, do: error_response("Not found")
  defp invalid_response, do: error_response("Invalid request")
  defp unauthorized_response, do: error_response("Unauthorized")
  defp conflict_response, do: error_response("Conflict")
  defp too_many_requests_response, do: error_response("Too many requests")
  defp server_error_response, do: error_response("Internal server error")

  defp error_response(desc) do
    %{
      description: desc,
      content: %{
        "application/json": %{
          schema: %{
            "$ref": "#/components/schemas/errors"
          }
        }
      }
    }
  end

  defp field_type(field, schema), do: type(field[:kind], field, schema)

  defp type(:integer, _field, _schema), do: %{type: :integer}
  defp type(:float, _field, _schema), do: %{type: :number}
  defp type(:boolean, _field, _schema), do: %{type: :boolean}
  defp type(:id, _field, _schema), do: %{type: :string, format: :uuid}
  defp type(:sort_direction, _field, _schema), do: %{type: :string, enum: [:asc, :desc]}

  defp type(:belongs_to, field, schema) do
    target = Entity.find_entity!(schema, field[:target])

    %{
      nullable: false,
      oneOf: [
        %{"$ref": "#/components/schemas/#{view_schema(target)}"},
        %{"$ref": "#/components/schemas/#{id_schema(target)}"}
      ]
    }
  end

  defp type(:json, _, _), do: %{type: :object, "$ref": "#/components/schemas/freeFormObject"}

  defp type(_, _field, _schema), do: %{type: :string}

  defp identifier(name), do: Inflex.camelize(name, :lower)

  defp id_schema(e), do: e |> view_schema() |> schema("Id")
  defp view_schema(e), do: e |> Keyword.fetch!(:camel_name) |> to_string()
  defp schema(name, suffix), do: "#{name}#{suffix}"
end
