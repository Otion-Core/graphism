defmodule Graphism.Graphql do
  @moduledoc "Generates Graphql schemas"

  alias Graphism.Entity

  def enums(enums) do
    enums = [{:asc_desc, [:asc, :desc]} | enums]

    Enum.map(enums, fn {name, values} ->
      quote do
        enum unquote(name) do
          (unquote_splicing(
             Enum.map(values, fn value ->
               quote do
                 value(unquote(value), as: unquote("#{value}"))
               end
             end)
           ))
        end
      end
    end)
  end

  def objects(schema) do
    [
      unit_graphql_object()
      | Enum.map(schema, fn e ->
          graphql_object(e, schema)
        end)
    ]
  end

  defp unit_graphql_object do
    quote do
      object :unit do
        field(:id, non_null(:id))
      end
    end
  end

  defp graphql_object(e, schema) do
    quote do
      object unquote(e[:name]) do
        (unquote_splicing(
           graphql_attribute_fields(e) ++
             graphql_timestamp_fields() ++
             graphql_relation_fields(e, schema) ++
             graphql_virtual_relation_fields(e)
         ))
      end
    end
  end

  def self_resolver do
    quote do
      defmodule Resolver.Self do
        def itself(parent, _, _) do
          {:ok, parent}
        end
      end
    end
  end

  def aggregate_type do
    quote do
      object :aggregate do
        field :count, :integer
      end
    end
  end

  @timestamp_fields [:inserted_at, :updated_at]

  defp graphql_timestamp_fields do
    Enum.map(@timestamp_fields, fn field ->
      quote do
        field(unquote(field), non_null(:datetime))
      end
    end)
  end

  defp graphql_nullable_type?(attr) do
    (Entity.optional?(attr) && !Entity.non_empty?(attr)) ||
      (Entity.has_default?(attr) && !Entity.enum?(attr) &&
         !Entity.boolean?(attr))
  end

  defp graphql_attribute_fields(e, opts \\ []) do
    e[:attributes]
    |> Enum.reject(fn attr ->
      Enum.member?(opts[:skip] || [], attr[:name])
    end)
    |> Enum.reject(&Entity.private?(&1))
    |> Enum.map(fn attr ->
      kind = Entity.attr_graphql_type(attr)

      kind =
        case attr[:opts][:allow] do
          nil ->
            case graphql_nullable_type?(attr) || opts[:mode] == :input || opts[:mode] == :update do
              true ->
                quote do
                  unquote(kind)
                end

              false ->
                quote do
                  non_null(unquote(kind))
                end
            end

          _ ->
            kind
        end

      if Entity.virtual?(attr) && get_in(attr, [:opts, :using]) do
        hook = get_in(attr, [:opts, :using])

        quote do
          field(
            unquote(attr[:name]),
            unquote(kind),
            resolve: fn parent, args, %{context: context} ->
              context = Map.drop(context, [:loader, :__absinthe_plug__, :pubsub])
              unquote(hook).execute(parent, context)
            end
          )
        end
      else
        quote do
          field(unquote(attr[:name]), unquote(kind))
        end
      end
    end)
  end

  defp graphql_relation_kind(rel, optional) do
    case {rel[:kind], optional} do
      {:has_many, _} ->
        quote do
          list_of(non_null(unquote(rel[:target])))
        end

      {_, true} ->
        quote do
          unquote(rel[:target])
        end

      {_, false} ->
        quote do
          non_null(unquote(rel[:target]))
        end
    end
  end

  defp graphql_relation_fields(e, schema, opts \\ []) do
    skip_fun = Keyword.get(opts, :skip_fun, fn _, _ -> false end)

    e[:relations]
    |> Enum.reject(&Entity.virtual?/1)
    |> Enum.reject(fn rel ->
      # inside input types, we don't want to include children
      # relations. Also we might want to skip certain entities depdending
      # on the context
      skip_fun.(e, rel) ||
        ((Entity.computed?(rel) || rel[:kind] == :has_many) &&
           (opts[:mode] == :input || opts[:mode] == :update_input))
    end)
    |> Enum.map(fn rel ->
      optional =
        Entity.optional?(rel) ||
          rel[:opts][:allow] != nil

      kind = graphql_relation_kind(rel, optional)

      case opts[:mode] do
        :update_input ->
          quote do
            field(
              unquote(rel[:name]),
              :id
            )
          end

        :input ->
          case Entity.optional?(rel) do
            false ->
              quote do
                field(
                  unquote(rel[:name]),
                  non_null(:id)
                )
              end

            true ->
              quote do
                field(
                  unquote(rel[:name]),
                  :id
                )
              end
          end

        _ ->
          case Entity.virtual?(e) do
            false ->
              quote do
                field(
                  unquote(rel[:name]),
                  unquote(kind),
                  resolve: unquote(Graphism.Dataloader.resolve_fun(e, rel, schema))
                )
              end

            true ->
              quote do
                field(
                  unquote(rel[:name]),
                  unquote(kind)
                )
              end
          end
      end
    end)
  end

  defp graphql_virtual_relation_fields(e) do
    e[:relations]
    |> Enum.filter(&Entity.virtual?/1)
    |> Enum.map(fn rel ->
      optional = Entity.optional?(rel)
      kind = graphql_relation_kind(rel, optional)
      hook = get_in(rel, [:opts, :using])

      quote do
        field(
          unquote(rel[:name]),
          unquote(kind),
          resolve: fn parent, args, %{context: context} ->
            context = Map.drop(context, [:loader, :__absinthe_plug__, :pubsub])
            unquote(hook).execute(parent, context)
          end
        )
      end
    end)
  end

  def queries(schema) do
    quote do
      query do
        (unquote_splicing(
           schema
           |> Enum.reject(&Entity.internal?(&1))
           |> Enum.flat_map(fn e ->
             [
               Entity.with_action(e, :list, fn _ ->
                 quote do
                   field unquote(String.to_atom("#{e[:plural]}")),
                         non_null(unquote(String.to_atom("#{e[:plural]}_queries"))) do
                     resolve(&Resolver.Self.itself/3)
                   end
                 end
               end),
               Entity.with_action(e, :read, fn _ ->
                 quote do
                   field unquote(String.to_atom("#{e[:name]}")),
                         non_null(unquote(String.to_atom("#{e[:name]}_queries"))) do
                     resolve(&Resolver.Self.itself/3)
                   end
                 end
               end)
             ]
           end)
           |> Enum.reject(&is_nil/1)
           |> raise_if_empty(
             "No GraphQL queries could be extracted from your schema. Please ensure you have :read or :list actions in your entities"
           )
         ))
      end
    end
  end

  def entities_queries(schema) do
    Enum.flat_map(schema, fn e ->
      [
        single_graphql_queries(e, schema),
        multiple_graphql_queries(e, schema)
      ]
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp single_graphql_queries(e, schema) do
    queries =
      if Entity.action?(e, :read) do
        [
          graphql_query_find_by_id(e, schema),
          graphql_query_find_by_unique_fields(e, schema),
          graphql_query_find_by_keys(e, schema)
        ]
      else
        []
      end

    case queries ++ graphql_single_result_custom_queries(e) do
      [] ->
        nil

      queries ->
        quote do
          object unquote(String.to_atom("#{e[:name]}_queries")) do
            (unquote_splicing(List.flatten(queries)))
          end
        end
    end
  end

  defp multiple_graphql_queries(e, schema) do
    queries =
      Entity.with_action(e, :list, fn _ ->
        if Entity.virtual?(e) do
          [
            graphql_query_list_all(e, schema)
          ]
        else
          [
            graphql_query_list_all(e, schema),
            graphql_query_aggregate_all(e, schema),
            graphql_query_find_by_parent_queries(e, schema),
            graphql_query_aggregate_by_parent_queries(e, schema),
            graphql_list_by_non_unique_key_queries(e, schema),
            graphql_aggregate_by_non_unique_key_queries(e, schema)
          ]
        end
      end) || []

    case queries ++ graphql_multiple_results_custom_queries(e) do
      [] ->
        nil

      queries ->
        quote do
          object unquote(String.to_atom("#{e[:plural]}_queries")) do
            (unquote_splicing(List.flatten(queries)))
          end
        end
    end
  end

  def mutations(schema) do
    quote do
      mutation do
        (unquote_splicing(
           schema
           |> Enum.reject(&Entity.internal?(&1))
           |> Enum.map(fn e ->
             case Entity.mutations?(e) do
               true ->
                 quote do
                   field unquote(String.to_atom("#{e[:name]}")),
                         non_null(unquote(String.to_atom("#{e[:name]}_mutations"))) do
                     resolve(&Resolver.Self.itself/3)
                   end
                 end

               false ->
                 nil
             end
           end)
           |> Enum.reject(&is_nil/1)
           |> raise_if_empty(
             "No GraphQL mutations could be extracted from your schema. Please ensure you have actions in your entities other than :read and :list."
           )
         ))
      end
    end
  end

  def entities_mutations(schema) do
    schema
    |> Enum.reject(&Entity.internal?(&1))
    |> Enum.map(fn e ->
      graphql_mutations(e, schema)
    end)
    |> Enum.reject(&is_nil/1)
  end

  def input_types(schema) do
    schema
    |> Enum.reject(&Entity.internal?(&1))
    |> Enum.flat_map(fn e ->
      [
        graphql_input_types(e, schema),
        graphql_update_input_types(e, schema)
      ]
    end)
    |> Enum.reject(&is_nil/1)
  end

  @pagination_args [
    limit: {:integer, :optional},
    offset: {:integer, :optional},
    sort_by: {:string, :optional},
    sort_direction: {:asc_desc, :optional}
  ]

  defp graphql_query_list_all(e, _schema) do
    quote do
      @desc "List all " <> unquote("#{e[:plural_display_name]}")
      field :all, list_of(non_null(unquote(e[:name]))) do
        unquote_splicing(graphql_args(@pagination_args, e))
        resolve(&unquote(e[:resolver_module]).list/3)
      end
    end
  end

  defp graphql_query_aggregate_all(e, _schema) do
    quote do
      @desc "Aggregate all " <> unquote("#{e[:plural_display_name]}")
      field :aggregate_all, non_null(:aggregate) do
        resolve(&unquote(e[:resolver_module]).aggregate_all/3)
      end
    end
  end

  defp graphql_query_find_by_id(e, _schema) do
    quote do
      @desc "Find a single " <> unquote("#{e[:display_name]}") <> " given its unique id"
      field :by_id,
            non_null(unquote(e[:name])) do
        arg(:id, non_null(:id))
        resolve(&unquote(e[:resolver_module]).get_by_id/3)
      end
    end
  end

  defp graphql_query_find_by_unique_fields(e, _schema) do
    e[:attributes]
    |> Enum.filter(&Entity.unique?(&1))
    |> Enum.map(fn attr ->
      kind = Entity.attr_graphql_type(attr)
      description = "Find a single #{e[:display_name]} given its unique #{attr[:name]}"

      {scope_args, description} =
        case e[:opts][:scope] do
          nil ->
            {[], description}

          rels ->
            {Enum.map(rels, fn name ->
               quote do
                 arg(unquote(name), non_null(:id))
               end
             end), "#{description}. This query is scoped by #{rels |> Enum.join(",")}."}
        end

      args =
        scope_args ++
          [
            quote do
              arg(unquote(attr[:name]), non_null(unquote(kind)))
            end
          ]

      quote do
        @desc unquote(description)
        field unquote(String.to_atom("by_#{attr[:name]}")),
              non_null(unquote(e[:name])) do
          unquote_splicing(args)

          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("get_by_#{attr[:name]}")) / 3))
        end
      end
    end)
  end

  defp graphql_query_find_by_keys(e, _schema) do
    e
    |> Entity.unique_keys()
    |> Enum.map(fn key ->
      fields = key[:fields] |> Enum.join(" and ")
      description = "Find a single #{e[:display_name]} given its #{fields}"
      resolver_fun = Entity.get_by_key_fun_name(key)
      query_name = resolver_fun |> to_string() |> String.replace("get_", "") |> String.to_atom()
      args = graphql_query_by_key_args(key, e)

      quote do
        @desc unquote(description)
        field unquote(query_name), non_null(unquote(e[:name])) do
          unquote_splicing(args)
          resolve(&(unquote(e[:resolver_module]).unquote(resolver_fun) / 3))
        end
      end
    end)
  end

  defp graphql_query_by_key_args(key, e) do
    Enum.map(key[:fields], fn name ->
      case Entity.attribute_or_relation(e, name) do
        {:attribute, attr} ->
          kind = Entity.attr_graphql_type(attr)

          quote do
            arg(unquote(name), non_null(unquote(kind)))
          end

        {:relation, _} ->
          quote do
            arg(unquote(name), non_null(:id))
          end
      end
    end)
  end

  defp graphql_query_find_by_parent_queries(e, _schema) do
    e
    |> Entity.parent_relations()
    |> Enum.reject(&Entity.virtual?/1)
    |> Enum.map(fn rel ->
      quote do
        @desc "Find all " <>
                unquote("#{e[:plural_display_name]}") <>
                " given their parent " <> unquote("#{rel[:target]}")
        field unquote(String.to_atom("by_#{rel[:name]}")),
              list_of(non_null(unquote(e[:name]))) do
          arg(unquote(rel[:name]), non_null(:id))
          unquote_splicing(graphql_args(@pagination_args, e))
          resolve(&(unquote(e[:resolver_module]).unquote(String.to_atom("list_by_#{rel[:name]}")) / 3))
        end
      end
    end)
  end

  defp graphql_query_aggregate_by_parent_queries(e, _schema) do
    e
    |> Entity.parent_relations()
    |> Enum.reject(&Entity.virtual?/1)
    |> Enum.map(fn rel ->
      name = String.to_atom("aggregate_by_#{rel[:name]}")
      description = "Aggregate all #{e[:plural_display_name]} by their parent #{rel[:target]}"

      quote do
        @desc unquote(description)
        field unquote(name), non_null(:aggregate) do
          arg(unquote(rel[:name]), non_null(:id))
          resolve(&(unquote(e[:resolver_module]).unquote(name) / 3))
        end
      end
    end)
  end

  defp graphql_list_by_non_unique_key_queries(e, _schema) do
    e
    |> Entity.non_unique_keys()
    |> Enum.map(fn key ->
      fields = Enum.join(key[:fields], " and ")
      description = "Find all #{e[:plural_display_name]} given their #{fields}"
      resolver_fun = Entity.list_by_key_fun_name(key)
      query_name = resolver_fun |> to_string() |> String.replace("list_", "") |> String.to_atom()
      args = graphql_query_by_key_args(key, e)

      quote do
        @desc unquote(description)
        field unquote(query_name), list_of(non_null(unquote(e[:name]))) do
          unquote_splicing(args)
          unquote_splicing(graphql_args(@pagination_args, e))
          resolve(&(unquote(e[:resolver_module]).unquote(resolver_fun) / 3))
        end
      end
    end)
  end

  defp graphql_aggregate_by_non_unique_key_queries(e, _schema) do
    e
    |> Entity.non_unique_keys()
    |> Enum.map(fn key ->
      fields = Enum.join(key[:fields], " and ")
      description = "Aggregate all #{e[:plural_display_name]} given their #{fields}"
      resolver_fun = Entity.aggregate_by_key_fun_name(key)
      query_name = resolver_fun
      args = graphql_query_by_key_args(key, e)

      quote do
        @desc unquote(description)
        field unquote(query_name), non_null(:aggregate) do
          unquote_splicing(args)
          resolve(&(unquote(e[:resolver_module]).unquote(resolver_fun) / 3))
        end
      end
    end)
  end

  defp graphql_input_types(e, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :has_many == rel[:kind] && Entity.inline_relation?(rel, :create) end)
    |> Enum.reject(&(Entity.virtual?(&1) && get_in(&1, [:opts, :using])))
    |> Enum.map(fn rel ->
      target = Entity.find_entity!(schema, rel[:target])
      input_type = String.to_atom("#{target[:name]}_input")

      quote do
        input_object unquote(input_type) do
          (unquote_splicing(
             graphql_attribute_fields(target, mode: :input, skip: [:id]) ++
               graphql_relation_fields(target, schema,
                 mode: :input,
                 skip_fun: fn _parent, rel ->
                   e[:name] == rel[:target] && e[:name] == rel[:name]
                 end
               )
           ))
        end
      end
    end)
  end

  defp graphql_update_input_types(e, schema) do
    e[:relations]
    |> Enum.filter(fn rel -> :has_many == rel[:kind] && Entity.inline_relation?(rel, :update) end)
    |> Enum.reject(&(Entity.virtual?(&1) && get_in(&1, [:opts, :using])))
    |> Enum.map(fn rel ->
      target = Entity.find_entity!(schema, rel[:target])
      input_type = String.to_atom("#{target[:name]}_update_input")

      quote do
        input_object unquote(input_type) do
          (unquote_splicing(
             graphql_attribute_fields(target, mode: :update) ++
               graphql_relation_fields(target, schema,
                 mode: :update_input,
                 skip_fun: fn _parent, rel ->
                   e[:name] == rel[:target] && e[:name] == rel[:name]
                 end
               )
           ))
        end
      end
    end)
  end

  defp graphql_mutations(e, schema) do
    case Entity.mutations?(e) do
      false ->
        nil

      true ->
        quote do
          object unquote(String.to_atom("#{e[:name]}_mutations")) do
            (unquote_splicing(
               List.flatten(
                 [
                   Entity.with_action(e, :create, fn _ -> graphql_create_mutation(e, schema) end),
                   Entity.with_action(e, :update, fn _ -> graphql_update_mutation(e, schema) end),
                   Entity.with_action(e, :delete, fn _ -> graphql_delete_mutation(e, schema) end)
                 ] ++ graphql_custom_mutations(e)
               )
               |> Enum.reject(&is_nil/1)
             ))
          end
        end
    end
  end

  defp graphql_custom_mutations(e) do
    e
    |> Entity.custom_mutations()
    |> Enum.map(fn {action, opts} ->
      graphql_custom_query_or_mutation(e, action, opts)
    end)
  end

  defp graphql_multiple_results_custom_queries(e) do
    e
    |> Entity.custom_queries()
    |> Enum.filter(&Entity.produces_multiple_results?/1)
    |> Enum.flat_map(fn {action, opts} ->
      [
        graphql_custom_query_or_mutation(e, action, opts, @pagination_args),
        graphql_custom_aggregation_query(e, action, opts)
      ]
    end)
  end

  defp graphql_single_result_custom_queries(e) do
    e
    |> Entity.custom_queries()
    |> Enum.filter(&Entity.produces_single_result?/1)
    |> Enum.map(fn {action, opts} ->
      graphql_custom_query_or_mutation(e, action, opts)
    end)
  end

  def graphql_resolver(e, action) do
    quote do
      &(unquote(e[:resolver_module]).unquote(action) / 3)
    end
  end

  defp mutation_arg_from_attribute(_, attr) do
    kind = Entity.attr_graphql_type(attr)

    quote do
      arg(
        unquote(attr[:name]),
        unquote(
          case Entity.optional?(attr) || Entity.has_default?(attr) do
            true ->
              kind

            false ->
              quote do
                non_null(unquote(kind))
              end
          end
        )
      )
    end
  end

  defp mutation_arg_from_relation(schema, e, rel, action) do
    {name, kind, _} = Entity.lookup_arg(schema, e, rel, action)

    case Entity.optional?(rel) do
      false ->
        quote do
          arg(unquote(name), non_null(unquote(kind)))
        end

      true ->
        quote do
          arg(unquote(name), unquote(kind))
        end
    end
  end

  defp mutation_arg_from_inlined_relation(_e, rel) do
    input_type = String.to_atom("#{rel[:target]}_input")

    quote do
      arg(unquote(rel[:name]), list_of(non_null(unquote(input_type))))
    end
  end

  defp maybe_client_generated_id_arg(e) do
    case Entity.client_ids?(e) do
      false ->
        []

      true ->
        [
          quote do
            arg(:id, non_null(:id))
          end
        ]
    end
  end

  defp graphql_create_mutation(e, schema) do
    return_type =
      case e[:actions][:create][:produces] do
        nil ->
          e[:name]

        type ->
          type
      end

    quote do
      @desc unquote("Create a new #{e[:display_name]}")
      field :create, non_null(unquote(return_type)) do
        unquote_splicing(
          maybe_client_generated_id_arg(e) ++
            (e[:attributes]
             |> Enum.reject(fn attr -> attr[:name] == :id end)
             |> Enum.reject(&Entity.computed?/1)
             |> Enum.reject(&(Entity.virtual?(&1) && get_in(&1, [:opts, :using])))
             |> Enum.map(&mutation_arg_from_attribute(e, &1))) ++
            (e
             |> Entity.parent_relations()
             |> Enum.reject(&Entity.computed?/1)
             |> Enum.reject(&Entity.virtual?/1)
             |> Enum.map(&mutation_arg_from_relation(schema, e, &1, :create))) ++
            (e[:relations]
             |> Enum.filter(fn rel ->
               :has_many == rel[:kind] && Entity.inline_relation?(rel, :create)
             end)
             |> Enum.reject(&Entity.virtual?/1)
             |> Enum.map(&mutation_arg_from_inlined_relation(e, &1)))
        )

        resolve(unquote(graphql_resolver(e, :create)))
      end
    end
  end

  defp graphql_update_mutation(e, _schema) do
    quote do
      @desc unquote("Update an existing #{e[:display_name]}")
      field :update, non_null(unquote(e[:name])) do
        unquote_splicing(
          [
            quote do
              arg(:id, non_null(:id))
            end
          ] ++
            (e[:attributes]
             |> Enum.reject(&(&1[:name] == :id))
             |> Enum.reject(&Entity.computed?/1)
             |> Enum.reject(&(Entity.virtual?(&1) && get_in(&1, [:opts, :using])))
             |> Enum.reject(&Entity.immutable?/1)
             |> Enum.map(fn attr ->
               kind = Entity.attr_graphql_type(attr)

               quote do
                 arg(
                   unquote(attr[:name]),
                   unquote(kind)
                 )
               end
             end)) ++
            (e
             |> Entity.parent_relations()
             |> Enum.reject(&Entity.computed?/1)
             |> Enum.reject(&(Entity.virtual?(&1) && get_in(&1, [:opts, :using])))
             |> Enum.reject(&Entity.immutable?/1)
             |> Enum.map(fn rel ->
               quote do
                 arg(unquote(rel[:name]), :id)
               end
             end)) ++
            (e[:relations]
             |> Enum.filter(fn rel ->
               :has_many == rel[:kind] && Entity.inline_relation?(rel, :update)
             end)
             |> Enum.reject(&Entity.virtual?/1)
             |> Enum.map(fn rel ->
               input_type = String.to_atom("#{rel[:target]}_update_input")

               quote do
                 arg(unquote(rel[:name]), list_of(non_null(unquote(input_type))))
               end
             end))
        )

        resolve(unquote(graphql_resolver(e, :update)))
      end
    end
  end

  defp graphql_delete_mutation(e, _schema) do
    quote do
      @desc "Delete an existing " <> unquote("#{e[:display_name]}")
      field :delete, unquote(e[:name]) do
        arg(:id, non_null(:id))

        resolve(unquote(graphql_resolver(e, :delete)))
      end
    end
  end

  defp graphql_args(args, e) do
    Enum.map(args, fn
      {arg, {:list, kind, :optional}} when is_atom(kind) ->
        quote do
          arg(unquote(arg), list_of(non_null(unquote(kind))))
        end

      {arg, {kind, :optional}} when is_atom(kind) ->
        quote do
          arg(unquote(arg), unquote(kind))
        end

      {arg, {:list, kind}} when is_atom(kind) ->
        quote do
          arg(unquote(arg), list_of(non_null(unquote(kind))))
        end

      {arg, kind} when is_atom(kind) ->
        quote do
          arg(unquote(arg), non_null(unquote(kind)))
        end

      arg when is_atom(arg) ->
        kind =
          case Entity.attribute(e, arg) do
            nil ->
              :id

            attr ->
              Entity.attr_graphql_type(attr)
          end

        quote do
          arg(unquote(arg), non_null(unquote(kind)))
        end
    end)
  end

  defp graphql_custom_query_or_mutation(e, action, opts, extra_args \\ []) do
    args = opts[:args] ++ extra_args
    produces = opts[:produces]
    desc = opts[:desc] || opts[:description] || "Custom action"

    quote do
      @desc unquote(desc)
      field unquote(action),
            unquote(
              case produces do
                {:list, produces} ->
                  quote do
                    list_of(non_null(unquote(produces)))
                  end

                produces ->
                  quote do
                    non_null(unquote(produces))
                  end
              end
            ) do
        (unquote_splicing(graphql_args(args, e)))

        resolve(unquote(graphql_resolver(e, action)))
      end
    end
  end

  defp graphql_custom_aggregation_query(e, action, opts) do
    name = String.to_atom("aggregate_#{action}")
    args = opts[:args]
    desc = opts[:desc] || opts[:description] || "Custom aggregation"

    quote do
      @desc unquote(desc)
      field unquote(name), non_null(:aggregate) do
        (unquote_splicing(graphql_args(args, e)))
        resolve(&(unquote(e[:resolver_module]).unquote(name) / 3))
      end
    end
  end

  defp raise_if_empty(enum, msg) do
    if Enum.empty?(enum) do
      raise msg
    end

    enum
  end
end
