defmodule Graphism.Dataloader do
  @moduledoc "Provides with a custom dataloader"

  alias Graphism.Entity

  def dataloader_module(opts) do
    caller = Keyword.fetch!(opts, :caller)

    module_name = Module.concat([caller.module, Dataloader])

    quote do
      defmodule unquote(module_name) do
        defstruct specs: %{}, cache: %{}

        defmodule Spec do
          defstruct name: nil, source: nil, value: nil, items: [], pending: true

          def new(name, {m, f, ids, _}, value) do
            ids = Enum.uniq(ids)

            %__MODULE__{name: name, source: {m, f, ids}, value: value}
          end
        end

        def new, do: %__MODULE__{}

        def load(%__MODULE__{specs: specs} = loader, name, source, value) do
          case Map.get(specs, name) do
            nil ->
              spec =
                name
                |> Spec.new(source, value)
                |> maybe_resolve(loader)

              %{loader | specs: Map.put(specs, name, spec)}

            _ ->
              loader
          end
        end

        def run(%__MODULE__{specs: specs, cache: old_cache} = loader, context \\ %{}) do
          contet = context = Map.drop(context, [:loader, :__absinthe_plug__, :pubsub])

          to_query =
            specs
            |> Map.values()
            |> Enum.filter(& &1.pending)
            |> Enum.reduce(%{}, fn %Spec{source: {m, f, new_ids}}, acc ->
              key = {m, f}
              ids = Map.get(acc, key, [])
              Map.put(acc, key, Enum.uniq(new_ids ++ ids))
            end)

          results =
            Enum.map(to_query, fn {{m, f} = key, ids} ->
              api = Module.concat([m, Api])

              context =
                Map.put(contet, :graphism, %{
                  entity: m.entity(),
                  action: :read,
                  schema: m
                })

              case apply(api, f, [ids, context]) do
                {:ok, items} ->
                  {key, items}

                _ ->
                  {key, []}
              end
            end)

          cache =
            Enum.reduce(results, old_cache, fn {{m, _}, new_items}, acc ->
              items = Map.get(acc, m, %{})

              items =
                Enum.reduce(new_items, items, fn new_item, acc2 ->
                  Map.put(acc2, new_item.id, new_item)
                end)

              Map.put(acc, m, items)
            end)

          loader = %__MODULE__{loader | cache: cache}

          specs =
            specs
            |> Enum.map(fn {name, spec} -> {name, resolve(spec, loader)} end)
            |> Enum.into(%{})

          %{loader | cache: cache, specs: specs}
        end

        def pending_batches?(%__MODULE__{specs: specs}) do
          specs |> Map.values() |> Enum.any?(& &1.pending)
        end

        def get(%__MODULE__{specs: specs, cache: cache}, name) do
          specs
          |> Map.fetch!(name)
          |> Map.fetch!(:items)
        end

        defp resolve(%Spec{source: {schema, _, _}, value: value_fn} = spec, %__MODULE__{} = loader) do
          items = Map.get(loader.cache, schema, %{})
          %Spec{spec | pending: false, items: value_fn.(items)}
        end

        defp maybe_resolve(
               %Spec{source: {schema, :list_by_ids, ids}, value: value_fn} = spec,
               %__MODULE__{} = loader
             ) do
          case Map.get(loader.cache, schema, nil) do
            nil ->
              %Spec{spec | pending: true, items: nil}

            items ->
              pending = Enum.any?(ids, &(!Map.has_key?(items, &1)))

              items =
                if !pending do
                  value_fn.(items)
                else
                  nil
                end

              %Spec{spec | pending: pending, items: items}
          end
        end

        defp maybe_resolve(%Spec{} = spec, _loader), do: spec
      end
    end
  end

  def absinthe_middleware(opts) do
    caller = Keyword.fetch!(opts, :caller)
    dataloader = Module.concat([caller.module, Dataloader])
    module_name = Module.concat([dataloader, Absinthe])

    quote do
      defmodule unquote(module_name) do
        @behaviour Absinthe.Middleware
        @behaviour Absinthe.Plugin

        @impl Absinthe.Plugin
        def before_resolution(%{context: context} = exec) do
          context =
            with %{loader: loader} <- context do
              %{context | loader: unquote(dataloader).run(loader, context)}
            end

          %{exec | context: context}
        end

        @impl Absinthe.Plugin
        def after_resolution(exec) do
          exec
        end

        @impl Absinthe.Middleware
        def call(%{state: :unresolved} = resolution, {loader, callback}) do
          if !unquote(dataloader).pending_batches?(loader) do
            resolution.context.loader
            |> put_in(loader)
            |> get_result(callback)
          else
            %{
              resolution
              | context: Map.put(resolution.context, :loader, loader),
                state: :suspended,
                middleware: [{__MODULE__, callback} | resolution.middleware]
            }
          end
        end

        def call(%{state: :suspended} = resolution, callback) do
          get_result(resolution, callback)
        end

        defp get_result(resolution, callback) do
          value = callback.(resolution.context.loader)
          Absinthe.Resolution.put_result(resolution, value)
        end

        @impl Absinthe.Plugin
        def pipeline(pipeline, exec) do
          with %{loader: loader} <- exec.context,
               true <- unquote(dataloader).pending_batches?(loader) do
            [Absinthe.Phase.Document.Execution.Resolution | pipeline]
          else
            _ -> pipeline
          end
        end
      end
    end
  end

  def resolve_fun(e, rel, schema) do
    target_entity = Entity.find_entity!(schema, rel[:target])
    kind = Keyword.fetch!(rel, :kind)

    do_dataloader =
      quote do
        case Map.get(parent, unquote(rel[:name])) do
          %{__struct__: Ecto.Association.NotLoaded} ->
            name = unquote(dataloader_key_name(e, rel))
            source = unquote(dataloader_source(schema, e, target_entity, rel, kind))
            value = unquote(dataloader_value_fun(schema, e, target_entity, rel, kind))
            callback = unquote(dataloader_callback_fun())
            loader = __MODULE__.Dataloader.load(context.loader, name, source, value)
            {:middleware, __MODULE__.Dataloader.Absinthe, {loader, callback}}

          other ->
            {:ok, other}
        end
      end

    case kind do
      :has_many ->
        quote do
          fn parent, args, %{context: context} ->
            unquote(do_dataloader)
          end
        end

      :belongs_to ->
        quote do
          fn parent, args, %{context: context} ->
            case parent.unquote(rel[:column]) do
              nil ->
                {:ok, nil}

              _id ->
                unquote(do_dataloader)
            end
          end
        end
    end
  end

  defp dataloader_callback_fun do
    quote do
      fn loader -> {:ok, __MODULE__.Dataloader.get(loader, name)} end
    end
  end

  defp dataloader_key_name(e, rel) do
    quote do
      {
        unquote(e[:name]),
        parent.id,
        unquote(rel[:name])
      }
    end
  end

  defp dataloader_source(schema, e, target, rel, :has_many) do
    inverse_rel = Entity.inverse_relation!(schema, e, rel[:name])
    schema_module = Keyword.fetch!(e, :schema_module)

    quote do
      {
        unquote(target[:schema_module]),
        unquote(String.to_atom("list_by_#{inverse_rel[:name]}")),
        [parent.id],
        unquote(schema_module)
      }
    end
  end

  defp dataloader_source(_schema, _e, target, rel, :belongs_to) do
    schema_module = Keyword.fetch!(target, :schema_module)

    quote do
      {
        unquote(schema_module),
        unquote(:list_by_ids),
        [parent.unquote(rel[:column])],
        unquote(schema_module)
      }
    end
  end

  defp dataloader_value_fun(schema, e, _target, rel, :has_many) do
    inverse_rel = Entity.inverse_relation!(schema, e, rel[:name])

    quote do
      fn items ->
        items
        |> Map.values()
        |> Enum.filter(&(&1.unquote(inverse_rel[:column]) == parent.id))
        |> Enum.sort_by(& &1.inserted_at)
      end
    end
  end

  defp dataloader_value_fun(_schema, _e, _target, rel, :belongs_to) do
    quote do
      fn items ->
        Map.get(items, parent.unquote(rel[:column]))
      end
    end
  end
end
