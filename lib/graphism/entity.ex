defmodule Graphism.Entity do
  @moduledoc "Entity helpers"

  alias Graphism.{Ast, Hooks, Policy}

  def ensure_not_empty!(e) do
    if Enum.empty?(e[:attributes]) and
         Enum.empty?(e[:relations]) do
      raise "Entity #{e[:name]} is empty"
    end
  end

  def ensure_action_scopes!(e, scopes) do
    Enum.each(e[:actions] ++ e[:custom_actions], fn {name, opts} ->
      Enum.each(opts[:policies] || [], fn
        {_policy, _role, :any} ->
          :ok

        {_policy, _role, scope} ->
          unless Policy.scope?(scopes, scope) do
            raise "undefined scope #{inspect(scope)} for action #{inspect(name)} of entity #{inspect(e[:name])}. Did you mean one of: #{inspect(Map.keys(scopes))}?"
          end

        _ ->
          :ok
      end)
    end)
  end

  def action_for(e, action) do
    (e[:actions] ++ e[:custom_actions])
    |> Enum.filter(fn {name, _} ->
      name == action
    end)
    |> Enum.map(fn {_, opts} -> opts end)
    |> List.first()
  end

  def find_entity!(schema, name) do
    case Enum.filter(schema, fn e ->
           name == e[:name]
         end) do
      [] ->
        raise "Could not resolve entity #{name}: #{inspect(Enum.map(schema, fn e -> e[:name] end))}"

      [e] ->
        e
    end
  end

  @readonly_actions [:read, :list]

  def readonly_action?(name) do
    Enum.member?(@readonly_actions, name)
  end

  def action_names(e) do
    (e[:actions] ++ e[:custom_actions])
    |> Enum.map(fn {name, _} -> name end)
  end

  def mutations?(e) do
    e
    |> action_names()
    |> Enum.reject(&readonly_action?(&1))
    |> Enum.count() > 0
  end

  def action?(e, action) do
    e
    |> action_names()
    |> Enum.find(fn name ->
      action == name
    end) != nil
  end

  def find_action(e, action) do
    e[:actions][action] || e[:custom_actions][action]
  end

  def list_actions(e) do
    Enum.filter(e[:actions] ++ e[:custom_actions], &action_of_kind?(&1, :list))
  end

  def non_list_actions(e) do
    Enum.reject(e[:actions] ++ e[:custom_actions], &action_of_kind?(&1, :list))
  end

  def custom_action?(e, name) do
    e
    |> find_action(name)
    |> action_of_kind?(:custom)
  end

  defp action_of_kind?({_, opts}, kind), do: action_of_kind?(opts, kind)
  defp action_of_kind?(opts, kind), do: kind in (opts[:kind] || [])

  def virtual?(e), do: modifier?(e, :virtual)
  def client_ids?(e), do: modifier?(e, :client_ids)
  def refetch?(e), do: modifier?(e, :refetch)
  def internal?(e), do: modifier?(e, :internal)
  def scope_results?(e), do: modifier?(e, :scope_results)

  def id?(attr), do: attr[:name] == :id
  def computed?(field), do: modifier?(field, :computed)
  def ancestor?(rel), do: rel[:opts][:from] != nil
  def optional?(attr), do: modifier?(attr, :optional)
  def required?(attr), do: !optional?(attr) && !computed?(attr)
  def unique?(attr), do: modifier?(attr, :unique)
  def immutable?(attr), do: modifier?(attr, :immutable)
  def non_empty?(attr), do: modifier?(attr, :non_empty)
  def private?(attr), do: modifier?(attr, :private)
  def public?(field), do: !private?(field) && !internal?(field)
  def preloaded?(rel), do: rel[:opts][:preloaded]

  def boolean?(attr), do: attr[:kind] == :boolean
  def enum?(attr), do: attr[:opts][:one_of] != nil
  def attr_graphql_type(attr), do: attr[:opts][:one_of] || attr[:kind]
  def has_default?(attr), do: Keyword.has_key?(attr[:opts], :default)

  defp modifier?(any, modifier), do: any |> modifiers() |> Enum.member?(modifier)
  defp modifiers(any), do: any[:opts][:modifiers] || any[:modifiers] || []

  def relation?(e, name), do: field?(e[:relations], name)
  def attribute?(e, name), do: field?(e[:attributes], name)
  defp field?(fields, name) when is_atom(name), do: Enum.find(fields, &(&1[:name] == name))
  defp field?(_, _), do: nil

  def attribute!(e, name) do
    attr = attribute?(e, name)

    unless attr do
      raise """
      no such attribute #{name} in entity #{e[:name]}.
        Existing attributes: #{e[:attributes] |> names() |> inspect()}"
      """
    end

    attr
  end

  def unique_attribute!(e, name) do
    attr = attribute!(e, name)

    unless unique?(attr) do
      raise """
      attribute #{name} of entity #{e[:name]} is not marked as :unique: #{inspect(attr)}"
      """
    end

    attr
  end

  def relation!(e, name) do
    rel = relation?(e, name)

    unless rel do
      raise """
      no such relation #{name} in entity #{e[:name]}.
        Existing relations: #{e[:relations] |> names() |> inspect()}"
      """
    end

    rel
  end

  def inverse_relation!(schema, e, name) do
    inverse_rel = inverse_relation(schema, e, name)

    unless inverse_rel do
      rel = relation!(e, name)
      target = find_entity!(schema, rel[:target])

      raise """
      Could not find inverse for #{inspect(rel[:kind])} relation #{inspect(rel[:name])} of #{inspect(e[:name])} in
      entity #{inspect(target[:name])}
      """
    end

    inverse_rel
  end

  def inverse_relation(schema, e, name) do
    rel = relation!(e, name)
    target = find_entity!(schema, rel[:target])

    case rel[:kind] do
      :has_many ->
        target
        |> parent_relations()
        |> Enum.find(fn rel -> rel[:target] == e[:name] end)

      :belongs_to ->
        target
        |> child_relations()
        |> Enum.find(fn rel -> rel[:target] == e[:name] end)
    end
  end

  def inline_relation?(rel, action) do
    Enum.member?(rel[:opts][:inline] || [], action)
  end

  def computed_relation_path(rel) do
    case rel[:opts][:from] do
      [parent_rel, rel_name] -> [parent_rel, rel_name]
      parent_rel -> [parent_rel, rel[:name]]
    end
  end

  def find_relation_by_kind_and_target!(e, kind, target) do
    rel =
      e[:relations]
      |> Enum.find(fn rel ->
        rel[:kind] == kind && rel[:target] == target
      end)

    unless rel do
      raise "relation of kind #{kind} and target #{target} not found in #{inspect(e)}"
    end

    rel
  end

  def column_name!(_e, :inserted_at), do: :inserted_at
  def column_name!(_e, :updated_at), do: :updated_at

  def column_name!(e, name) do
    case attribute_or_relation(e, name) do
      {:attribute, _} -> name
      {:relation, rel} -> Keyword.fetch!(rel, :column)
    end
  end

  def attribute_or_relation(e, name) do
    case attribute(e, name) do
      nil ->
        case relation(e, name) do
          nil ->
            raise "No attribute or relation #{name} in entity #{e[:name]}"

          rel ->
            {:relation, rel}
        end

      attr ->
        {:attribute, attr}
    end
  end

  def attribute(_e, :inserted_at), do: attribute([:inserted_at, :datetime])
  def attribute(_e, :updated_at), do: attribute([:updated_at, :datetime])

  def attribute(e, name) do
    Enum.find(e[:attributes], fn attr ->
      name == attr[:name]
    end)
  end

  def relation(e, name) do
    Enum.find(e[:relations], fn attr ->
      name == attr[:name]
    end)
  end

  def all_fields(e), do: e[:attributes] ++ e[:relations]

  def required_attributes(e), do: Enum.filter(e[:attributes], &required?/1)
  def required_fields(e), do: Enum.filter(e[:attributes] ++ e[:relations], &required?/1)
  def public_attributes(e), do: Enum.filter(e[:attributes], &public?/1)
  def public_relations(e), do: Enum.filter(e[:relations], &public?/1)

  def unique_keys(e), do: Enum.filter(e[:keys], &unique_key?/1)
  def non_unique_keys(e), do: Enum.reject(e[:keys], &unique_key?/1)
  def unique_attributes(e), do: Enum.filter(e[:attributes], &unique?/1)

  def unique_keys_and_attributes(e) do
    unique_keys(e) ++
      (e |> unique_attributes() |> Enum.map(&attribute_as_unique_key/1))
  end

  defp attribute_as_unique_key(attr) do
    [name: attr[:name], fields: [attr[:name]], unique: true]
  end

  defp unique_key?(k), do: k[:unique]

  def list_by_parent_fun_name(rel) do
    String.to_atom("list_by_#{rel[:name]}")
  end

  def aggregate_by_parent_fun_name(rel) do
    String.to_atom("aggregate_by_#{rel[:name]}")
  end

  def get_by_key_fun_name(key) do
    fields = Enum.join(key[:fields], "_and_")
    String.to_atom("get_by_#{fields}")
  end

  def list_by_key_fun_name(key) do
    fields = Enum.join(key[:fields], "_and_")
    String.to_atom("list_by_#{fields}")
  end

  def aggregate_by_key_fun_name(key) do
    fields = Enum.join(key[:fields], "_and_")
    String.to_atom("aggregate_by_#{fields}")
  end

  def custom_mutations(e) do
    Enum.filter(e[:custom_actions], &action_of_kind?(&1, :write))
  end

  def custom_queries(e) do
    Enum.filter(e[:custom_actions], &(action_of_kind?(&1, :read) && !action_of_kind?(&1, :custom)))
  end

  def produces_single_result?(action), do: !produces_multiple_results?(action)
  def produces_multiple_results?({_name, opts}), do: match?({:list, _}, opts[:produces])

  def preloads(e), do: parent_preloads(e) ++ child_preloads(e)

  defp child_preloads(e) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :has_many && rel[:opts][:preloaded] end)
    |> Enum.reduce([], fn rel, acc ->
      Keyword.put(acc, rel[:name], rel[:opts][:preload] || [])
    end)
    |> Enum.reverse()
  end

  defp parent_preloads(e) do
    e[:relations]
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to && rel[:opts][:preloaded] end)
    |> Enum.reduce([], fn rel, acc ->
      Keyword.put(acc, rel[:name], rel[:opts][:preload] || [])
    end)
    |> Enum.reverse()
  end

  def relations(e), do: e[:relations]

  def parent_relations(e) do
    e
    |> relations()
    |> Enum.filter(fn rel -> rel[:kind] == :belongs_to end)
  end

  def child_relations(e) do
    e
    |> relations()
    |> Enum.filter(fn rel -> rel[:kind] == :has_many end)
  end

  def hook!(hooks, kind, name) do
    hook = Hooks.find(hooks, kind, name)

    unless hook do
      "No hook defined of type #{kind} and name #{name}"
    end

    hook
  end

  defp hook_call(e, mod, :before, :update) do
    quote do
      {:ok, unquote(Ast.var(:attrs))} <- unquote(mod).execute(unquote(Ast.var(e)), unquote(Ast.var(:attrs)))
    end
  end

  defp hook_call(_, mod, :before, _) do
    quote do
      {:ok, unquote(Ast.var(:attrs))} <- unquote(mod).execute(unquote(Ast.var(:attrs)))
    end
  end

  defp hook_call(e, mod, :after, _) do
    quote do
      {:ok, unquote(Ast.var(e))} <- unquote(mod).execute(unquote(Ast.var(e)))
    end
  end

  def hooks(nil), do: []
  def hooks(mod) when is_atom(mod), do: [mod]
  def hooks(mods) when is_list(mods), do: mods

  def hooks(e, phase, action) do
    opts =
      e[:actions][action] ||
        e[:custom_actions][action]

    opts[phase]
    |> hooks()
    |> Enum.map(&hook_call(e, &1, phase, action))
  end

  def names(rels) do
    rels
    |> Enum.map(fn rel -> rel[:name] end)
  end

  def attrs_with_parent_relations(e) do
    rels = parent_relations(e)

    attrs_with_required_parent_relations(rels) ++ attrs_with_optional_parent_relations(rels)
  end

  defp attrs_with_required_parent_relations(rels) do
    rels
    |> Enum.reject(&optional?/1)
    |> Enum.flat_map(fn rel ->
      rel_key = String.to_atom("#{rel[:name]}_id")

      [
        quote do
          unquote(Ast.var(:attrs)) <- Map.put(unquote(Ast.var(:attrs)), unquote(rel[:name]), unquote(Ast.var(rel)))
        end,
        quote do
          unquote(Ast.var(:attrs)) <- Map.put(unquote(Ast.var(:attrs)), unquote(rel_key), unquote(Ast.var(rel)).id)
        end
      ]
    end)
  end

  defp attrs_with_optional_parent_relations(rels) do
    rels
    |> Enum.filter(&optional?/1)
    |> Enum.flat_map(fn rel ->
      rel_key = String.to_atom("#{rel[:name]}_id")

      [
        quote do
          unquote(Ast.var(:attrs)) <- Map.put(unquote(Ast.var(:attrs)), unquote(rel[:name]), unquote(Ast.var(rel)))
        end,
        quote do
          unquote(Ast.var(:attrs)) <-
            Map.put(
              unquote(Ast.var(:attrs)),
              unquote(rel_key),
              if(unquote(Ast.var(rel)) != nil, do: unquote(Ast.var(rel)).id, else: nil)
            )
        end
      ]
    end)
  end

  def lookup_arg(schema, e, rel, action) do
    case get_in(e, [:actions, action, :lookup, rel[:name]]) do
      nil ->
        {rel[:name], :id, :get_by_id}

      key ->
        target = find_entity!(schema, rel[:target])
        attr = unique_attribute!(target, key)
        lookup_arg_name = String.to_atom("#{rel[:target]}_#{attr[:name]}")
        {lookup_arg_name, attr[:kind], String.to_atom("get_by_#{attr[:name]}")}
    end
  end

  def with_action(e, action, next) do
    with opts when opts != nil <- action_for(e, action),
         false <- action_of_kind?(opts, :custom) do
      next.(opts)
    else
      _ -> nil
    end
  end

  def resolve_schema(schema) do
    plurals =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:plural], e[:name])
      end)

    index =
      Enum.reduce(schema, %{}, fn e, index ->
        Map.put(index, e[:name], e)
      end)

    schema
    |> Enum.map(fn e ->
      e
      |> with_display_name()
      |> with_camel_name()
      |> with_relations!(index, plurals)
    end)
  end

  def with_camel_name(e) do
    e
    |> Keyword.put(:camel_name, Inflex.camelize(e[:name], :lower))
    |> Keyword.put(:plural_camel_name, Inflex.camelize(e[:plural], :lower))
  end

  def with_display_name(e) do
    display_name = display_name(e[:name])

    plural_display_name = display_name(e[:plural])

    e
    |> Keyword.put(:display_name, display_name)
    |> Keyword.put(:plural_display_name, plural_display_name)
  end

  defp display_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> Inflex.camelize()
    |> :string.titlecase()
  end

  # Ensure all relations are properly formed.
  # This function will raise an error if the target entity
  # for a relation cannot be found
  defp with_relations!(e, index, plurals) do
    relations =
      e[:relations]
      |> Enum.map(fn rel ->
        rel =
          case rel[:kind] do
            :has_many ->
              target = plurals[rel[:plural]]

              unless target do
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(plurals))}. Relation: #{inspect(rel)}"
              end

              rel
              |> Keyword.put(:target, target)
              |> Keyword.put(:name, rel[:opts][:as] || rel[:name])

            _ ->
              target = index[rel[:name]]

              unless target do
                raise "Entity #{e[:name]} has relation #{rel[:name]} of unknown type: #{inspect(Map.keys(index))}"
              end

              name = rel[:opts][:as] || rel[:name]

              rel
              |> Keyword.put(:target, target[:name])
              |> Keyword.put(:name, name)
              |> Keyword.put(:column, String.to_atom("#{name}_id"))
          end

        opts = rel[:opts]

        opts =
          opts
          |> with_action_hook(:allow)

        Keyword.put(rel, :opts, opts)
      end)

    Keyword.put(e, :relations, relations)
  end

  defp with_action_hook(opts, name) do
    case opts[name] do
      nil ->
        opts

      {:__aliases__, _, mod} ->
        Keyword.put(opts, name, Module.concat(mod))

      mods when is_list(mods) ->
        Keyword.put(
          opts,
          name,
          Enum.map(mods, fn {:__aliases__, _, mod} ->
            Module.concat(mod)
          end)
        )
    end
  end

  def validate_attribute_name!(name) do
    unless is_atom(name) do
      raise "Attribute #{name} should be an atom"
    end
  end

  @supported_attribute_types [
    :id,
    :string,
    :integer,
    :number,
    :date,
    :boolean,
    :upload,
    :json
  ]

  def validate_attribute_type!(type) do
    unless Enum.member?(@supported_attribute_types, type) do
      raise "Unsupported attribute type #{inspect(type)}. Must be one of #{inspect(@supported_attribute_types)}"
    end
  end

  def validate_attribute_opts!(opts) do
    unless is_list(opts) do
      raise "Unsupported attribute opts #{inspect(opts)}. Must be a keyword list"
    end
  end

  def with_plural(entity) do
    case entity[:plural] do
      nil ->
        plural = Inflex.pluralize("#{entity[:name]}")
        Keyword.put(entity, :plural, String.to_atom(plural))

      _ ->
        entity
    end
  end

  def with_table_name(entity) do
    table_name =
      entity[:plural]
      |> Atom.to_string()
      |> Inflex.parameterize("_")
      |> String.to_atom()

    Keyword.put(entity, :table, table_name)
  end

  def with_resolver_module(entity, caller_mod) do
    module_name(caller_mod, entity, :resolver_module, :resolver)
  end

  def with_api_module(entity, caller_mod) do
    module_name(caller_mod, entity, :api_module, :api)
  end

  def with_handler_module(entity, caller_mod) do
    module_name(caller_mod, entity, :handler_module, :handler)
  end

  def with_json_encoder_module(entity, caller_mod) do
    module_name(caller_mod, entity, :json_encoder_module, :json_encoder)
  end

  def module_name(prefix, entity, name, suffix \\ nil) do
    module_name =
      [prefix, entity[:name], suffix]
      |> Enum.reject(fn part -> part == nil end)
      |> Enum.map(&Atom.to_string(&1))
      |> Enum.map(&Inflex.camelize(&1))
      |> Module.concat()

    Keyword.put(
      entity,
      name,
      module_name
    )
  end

  def maybe_with_scope(entity) do
    (entity[:opts][:scope] || [])
    |> Enum.each(fn name ->
      relation!(entity, name)
    end)

    entity
  end

  def split_actions(opts, all) do
    if virtual?(opts) do
      {[], all}
    else
      Enum.split_with(all, fn {name, _} ->
        built_in_action?(name)
      end)
    end
  end

  @built_in_actions [:read, :list, :create, :update, :delete]

  defp built_in_action?(name) do
    Enum.member?(@built_in_actions, name)
  end

  def attributes_from({:__block__, _, attrs}) do
    attrs
    |> Enum.map(&attribute/1)
    |> Enum.map(&maybe_computed/1)
    |> Enum.reject(&is_nil/1)
  end

  def attributes_from({:attribute, _, attr}) do
    [attribute(attr)]
  end

  def attributes_from(other) do
    Enum.reject([attribute(other)], &is_nil/1)
  end

  def attribute({:attribute, _, opts}), do: attribute(opts)
  def attribute([name, kind]), do: attribute([name, kind, []])
  def attribute([name, kind, opts]), do: [name: name, kind: kind, opts: opts]

  def attribute({:unique, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:unique | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  def attribute({:maybe, _, [opts]}) do
    attribute({:optional, nil, [opts]})
  end

  def attribute({:immutable, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:immutable | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  def attribute({:non_empty, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:non_empty | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  def attribute({:virtual, _, [opts]}) do
    with attr when attr != nil <- attribute(opts) do
      modifiers = [:virtual | get_in(attr, [:opts, :modifiers]) || []]
      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  def attribute({:optional, _, [{:belongs_to, _, _}]}), do: nil

  def attribute({:optional, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:optional | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  def attribute({:computed, _, [opts, [using: {:__aliases__, _, using}]]}) do
    with attr when not is_nil(attr) <- attribute(opts) do
      modifiers = [:computed | get_in(attr, [:opts, :modifiers]) || []]
      using = Module.concat(using)

      attr
      |> put_in([:opts, :modifiers], modifiers)
      |> put_in([:opts, :using], using)
    end
  end

  def attribute({:computed, _, [opts]}) do
    with attr when not is_nil(attr) <- attribute(opts) do
      modifiers = [:computed | get_in(attr, [:opts, :modifiers]) || []]

      put_in(attr, [:opts, :modifiers], modifiers)
    end
  end

  def attribute({:private, _, [opts]}) do
    attr = attribute(opts)
    modifiers = [:private | get_in(attr, [:opts, :modifiers]) || []]
    put_in(attr, [:opts, :modifiers], modifiers)
  end

  def attribute({:string, _, [name]}), do: attribute([name, :string])
  def attribute({:text, _, [name]}), do: attribute([name, :string, [store: :text]])
  def attribute({:integer, _, [name]}), do: attribute([name, :integer])
  def attribute({:boolean, _, [name]}), do: attribute([name, :boolean])
  def attribute({:float, _, [name]}), do: attribute([name, :float])
  def attribute({:datetime, _, [name]}), do: attribute([name, :datetime])
  def attribute({:time, _, [name]}), do: attribute([name, :time])
  def attribute({:date, _, [name]}), do: attribute([name, :date])
  def attribute({:decimal, _, [name]}), do: attribute([name, :decimal])
  def attribute({:upload, _, [name]}), do: attribute([name, :upload, [modifiers: [:virtual]]])
  def attribute({:json, _, [name]}), do: attribute([name, :json, [schema: Graphism.Type.Ecto.Jsonb, store: :map]])

  def attribute({kind, _, [attr, opts]}) do
    with attr when attr != nil <- attribute({kind, nil, [attr]}) do
      opts = Keyword.merge(attr[:opts], opts)
      Keyword.put(attr, :opts, opts)
    end
  end

  def attribute(_), do: nil

  def keys_from({:__block__, _, items}) do
    items
    |> Enum.map(&key_from/1)
    |> Enum.reject(&is_nil/1)
  end

  def keys_from(_), do: []

  def key_from({:key, _, [fields]}) do
    [name: key_name(fields), fields: fields, unique: true]
  end

  def key_from({:key, _, [fields, opts]}) do
    [name: key_name(fields), fields: fields, unique: Keyword.get(opts, :unique, true)]
  end

  def key_from(_), do: nil

  def key_name(fields), do: fields |> Enum.map(&to_string/1) |> Enum.join("_") |> String.to_atom()

  def maybe_add_id_attribute(attrs) do
    if attrs |> Enum.filter(fn attr -> attr[:name] == :id end) |> Enum.empty?() do
      [attribute([:id, :id]) | attrs]
    else
      attrs
    end
  end

  def maybe_add_slug_attribute(attrs, schema_module, block) do
    case slug_field(block) do
      nil ->
        attrs

      field ->
        slug = [
          name: :slug,
          kind: :string,
          opts: [
            using: slugify_module_name(schema_module),
            using_field: field,
            modifiers: [:unique, :computed]
          ]
        ]

        [slug | attrs]
    end
  end

  def slugify_module_name(schema_module) do
    Module.concat([schema_module, Slugify])
  end

  defp slug_field({:__block__, _, fields}) do
    fields
    |> Enum.map(fn
      {:slug, _, [field]} -> field
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  def relations_from({:__block__, _, rels}) do
    rels
    |> Enum.map(&relation_from/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&maybe_computed/1)
    |> Enum.map(&maybe_preloaded/1)
  end

  def relations_from(_) do
    []
  end

  def relation_from({:maybe, _, [opts]}),
    do: relation_from({:optional, nil, [opts]})

  def relation_from({:optional, _, [{kind, _, _} = opts]}) when kind in [:belongs_to, :has_many] do
    rel = relation_from(opts)
    modifiers = get_in(rel, [:opts, :modifiers]) || []
    put_in(rel, [:opts, :modifiers], [:optional | modifiers])
  end

  def relation_from({:immutable, _, [opts]}) do
    with rel when rel != nil <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []
      put_in(rel, [:opts, :modifiers], [:immutable | modifiers])
    end
  end

  def relation_from({:non_empty, _, [opts]}) do
    with rel when rel != nil <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []
      put_in(rel, [:opts, :modifiers], [:non_empty | modifiers])
    end
  end

  def relation_from({:has_many, _, [name]}),
    do: [name: name, kind: :has_many, opts: [], plural: name]

  def relation_from({:has_many, _, [name, opts]}),
    do: [name: name, kind: :has_many, opts: opts, plural: name]

  def relation_from({:belongs_to, _, [name]}), do: [name: name, kind: :belongs_to, opts: []]

  def relation_from({:belongs_to, _, [name, opts]}),
    do: [name: name, kind: :belongs_to, opts: opts]

  def relation_from({:preloaded, _, [opts]}) do
    rel = relation_from(opts)
    unless rel, do: raise("Unsupported relation #{inspect(opts)} for preloaded modifier")
    opts = rel[:opts] || []
    opts = Keyword.put(opts, :preloaded, true)
    Keyword.put(rel, :opts, opts)
  end

  def relation_from({:computed, _, [opts, [using: {:__aliases__, _, using}]]}) do
    with rel when not is_nil(rel) <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []
      using = Module.concat(using)

      rel
      |> put_in([:opts, :modifiers], [:computed | modifiers])
      |> put_in([:opts, :using], using)
    end
  end

  def relation_from({:computed, _, [opts]}) do
    with rel when not is_nil(rel) <- relation_from(opts) do
      modifiers = get_in(rel, [:opts, :modifiers]) || []

      put_in(rel, [:opts, :modifiers], [:computed | modifiers])
    end
  end

  def relation_from(_), do: nil

  def maybe_computed(field) do
    computed? =
      get_in(field, [:opts, :from]) ||
        get_in(field, [:opts, :from_context]) ||
        get_in(field, [:opts, :using])

    if computed?, do: with_modifier(field, :computed), else: field
  end

  defp with_modifier(field, mod) do
    mods = get_in(field, [:opts, :modifiers]) || []
    put_in(field, [:opts, :modifiers], Enum.uniq([mod | mods]))
  end

  def maybe_preloaded(rel) do
    case rel[:opts][:preload] do
      nil -> rel
      _ -> put_in(rel, [:opts, :preloaded], true)
    end
  end

  def with_action_produces(opts, entity_name) do
    if !built_in_action?(opts[:name]) && !opts[:produces] do
      Keyword.put(opts, :produces, entity_name)
    else
      opts
    end
  end

  def with_action_args(opts, _entity_name) do
    args = opts[:args] || []

    if opts[:produces] && Enum.empty?(args) && !action_of_kind?(opts, :list) do
      Keyword.put(opts, :args, [:id])
    else
      args =
        Enum.map(args, fn
          {name, {:{}, _, [:list, kind, :optional]}} -> {name, {:list, kind, :optional}}
          {name, {:{}, _, [:list, kind]}} -> {name, {:list, kind}}
          {name, kind} -> {name, kind}
          name when is_atom(name) -> name
        end)

      Keyword.put(opts, :args, args)
    end
  end

  def with_action_kind(opts, name) when name in [:list] do
    Keyword.put_new(opts, :kind, [:read, :list])
  end

  def with_action_kind(opts, name) when name in [:read] do
    Keyword.put_new(opts, :kind, [:read])
  end

  def with_action_kind(opts, _) do
    Keyword.put_new(opts, :kind, [:write])
  end

  defp maybe_custom_action(opts) do
    if in_block?(opts[:do], &custom?/1) do
      kind = opts[:kind]
      Keyword.put(opts, :kind, [:custom | kind])
    else
      opts
    end
  end

  defp in_block?({:__block__, [], items}, fun) when is_list(items) do
    items
    |> Enum.filter(fun)
    |> List.first()
  end

  defp in_block?({:__block__, [], item}, fun), do: fun.(item)
  defp in_block?(_, _), do: false

  defp custom?({:custom, _, _}), do: true
  defp custom?(_), do: false

  def with_action_policies(opts) do
    case opts[:do] do
      nil ->
        opts

      block ->
        block
        |> action_policies()
        |> List.flatten()
        |> case do
          [] -> opts
          policy -> Keyword.put(opts, :policies, policy)
        end
    end
  end

  defp action_policies({:__block__, _, block}) do
    block
    |> Enum.map(&action_policies/1)
    |> Enum.reject(&is_nil/1)
  end

  defp action_policies({policy, _, [role]}), do: [{policy, role, :any}]

  defp action_policies({policy, _, [role, {:scope, _, [scope]}]}) do
    [{policy, role, scope}]
  end

  defp action_policies(_), do: []

  def entity_policies({:__block__, _, spec}) do
    spec
    |> Enum.filter(fn {policy, _, _} -> policy in [:allow, :deny] end)
    |> Enum.map(fn
      {policy, _, [[do: {kind, _, [role, {:scope, _, [scope]}]}]]} ->
        {kind, {policy, role, scope}}

      {policy, _, [[do: {kind, _, [role]}]]} ->
        {kind, {policy, role, :any}}

      {policy, _, [[do: {:__block__, _, actions}]]} ->
        Enum.map(actions, fn
          {kind, _, [role, {:scope, _, [scope]}]} ->
            {kind, {policy, role, scope}}

          {kind, _, [role]} ->
            {kind, {policy, role, :any}}
        end)
    end)
    |> List.flatten()
    |> Enum.reduce([], fn {kind, policy}, acc ->
      policies = Keyword.get(acc, kind, [])
      policies = [policy | policies]
      Keyword.put(acc, kind, policies)
    end)
  end

  def actions_from({:__block__, _, actions}, entity_name) do
    actions
    |> Enum.reduce([], fn action, acc ->
      case action_from(action, entity_name) do
        nil ->
          acc

        action ->
          Keyword.put(acc, action[:name], action[:opts])
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def actions_from(_, _), do: []

  def action_from({:action, _, [name, opts]}, entity_name),
    do: action_from(name, opts, entity_name)

  def action_from({:action, _, [name]}, entity_name), do: action_from(name, [], entity_name)

  def action_from({:action, _, [name, opts, block]}, entity_name) do
    action_from(name, Keyword.merge(opts, block), entity_name)
  end

  def action_from(_, _), do: nil

  def action_from(name, opts, entity_name) do
    opts =
      opts
      |> with_action_kind(name)
      |> maybe_custom_action()
      |> with_action_hook(:using)
      |> with_action_hook(:before)
      |> with_action_hook(:after)
      |> with_action_produces(entity_name)
      |> with_action_args(entity_name)
      |> with_action_hook(:allow)
      |> with_action_hook(:scope)
      |> with_action_policies()
      |> Keyword.drop([:do])

    [name: name, opts: opts]
  end

  def actions_with_policies(actions, e, default) do
    Enum.map(actions, fn {name, opts} ->
      default_policies = default_policy_for(opts[:kind], default)
      opts = Keyword.put_new(opts, :policies, default_policies)

      if !opts[:policies] || Enum.empty?(opts[:policies]) do
        raise "No policy defined for action #{inspect(name)} of entity #{inspect(e)}"
      end

      {name, opts}
    end)
  end

  defp default_policy_for(kinds, policies) do
    kinds
    |> Enum.map(&Keyword.get(policies, &1))
    |> Enum.reject(&is_nil/1)
    |> List.first()
  end

  def lists_from({:__block__, _, actions}, entity_name) do
    actions
    |> Enum.reduce([], fn list, acc ->
      case list_from(list, entity_name) do
        nil ->
          acc

        list ->
          Keyword.put(acc, list[:name], list[:opts])
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def lists_from(_, _), do: []

  def list_from({:list, _, [name, opts]}, entity_name),
    do: list_from(name, opts, entity_name)

  def list_from({:list, _, [name]}, entity_name), do: list_from(name, [], entity_name)

  def list_from({:list, _, [name, opts, block]}, entity_name) do
    policies =
      block
      |> with_action_policies()
      |> Keyword.fetch!(:policies)

    name
    |> list_from(opts, entity_name)
    |> put_in([:opts, :policies], policies)
  end

  def list_from(_, _), do: nil

  def list_from(name, opts, entity_name) do
    opts =
      (opts || [])
      |> Keyword.put(:kind, [:query, :read, :list])
      |> Keyword.put(:produces, {:list, entity_name})

    action_from(name, opts, entity_name)
  end
end
