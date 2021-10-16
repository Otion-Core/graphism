# Graphism

An Elixir DSL that makes it easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.

<p align="center">
  <img height="350" src="https://support.bite.social/images/graphism.png">
</p>

## Contributing

Please make sure your read and honour [our contributing guide](CONTRIBUTING.md).

## Installation :construction:

This library can be installed by adding `graphism` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:graphism, git: "https://github.com/gravity-core/graphism.git", branch: "main"}
  ]
end
```

Also add `:graphism` to your extra applications:

```elixir
 def application do
    [
      extra_applications: [:graphism],
      ...
    ]
  end

```

## Your first schema :world_map:

Assuming you already have an Ecto repo, define a new schema module with your entities, attributes, relations and actions: 

```elixir
defmodule MyBlog.Schema do
  use Graphism,
    repo: MyBlog.Repo,
    otp_app: :my_app

    
  entity :post do
    string(:body)
    has_many :comments

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end

  entity :comment do
    string(:body)
    belongs_to :post

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end
end

```

Graphism will automatically add unique IDs as UUIDs to all entities in your schema.

## Generate migrations :building_construction:

Graphism will keep track of your schema changes and generate proper Ecto migrations:


First, you need to tell graphism about your schema. In your config.exs,


```elixir
config :graphism, schema: MyBlog.Schema
```

Then:

```
$ mix graphism.migrations

```

Do not forget to run `mix ecto.migrate`.

## Expose your GraphQL api

You can use Graphism's convenience plug:


```elixir
defmodule MyBlog.Endpoint do
  use Plug.Router
  
  use Graphism.Plug, schema: MyBlog.Schema
end
```

This will make your GraphQL api available at `/api`. Also, you will have a GraphiQL UI at `/graphiql`. Internally, `Graphism.Plug` wraps `Abinsthe.Plug`.

Finally, you can easily add the endpoint to your supervision tree:

```elixir
defmodule MyBlog.Application do
  def start(_type, _args) do
    children = [
      ...,
      {MyBlog.Repo, []},
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: MyBlog.Endpoint,
        options: [port: 4000]
      ),
      ...
    ]

    opts = [strategy: :one_for_one, name: Bonny.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

For convenience, `Plug.Cowboy` is automatically downloaded by Graphism, so you don't need to add it to your project.

## Observability


## Schema Features :abacus:

### Optional attributes

Any standard attribute can be made optional:

```elixir
entity :post do
  optional(boolean(:draft))
  ...
end
```

Optional attributes will not be required in mutations.

### Default values

It is possible to defined default values for attributes that are optional. 

```elixir
entity :post do
  optional(boolean(:draft), default: true)
  ...
end
```

For convenience, the above can also be expressed as:

```elixir
entity :post do
  optional(boolean(:draft, default: true)
  ...
end
```

### Computed attributes

Computed attributes are part of your schema, they are stored, and can also be queried.

However, since they are computed, they won't be included in your mutations, therefore it is not possible to modify their values explicitly.

```elixir
entity :post do
  computed(boolean(:draft, default: true)
  ...
end
```

### Standard actions

Graphism provides with five basic standard actions:

* `read`
* `list`
* `create`
* `update`
* `delete`

### User defined actions

On top of the standard actions, it is possible to defined custom actions:

```elixir
entity :post do
  ...
  action(:publish, using: MyBlog.Post.Publish, desc: "Publish a post") 
  ...
end
```

It is also possible to further customize inputs (`args`) and outputs (`:produces`) in custom actions:

```elixir
entity :post do
  ...
  action(:publish, using: MyBlog.Post.Publish, args: [:id], :produces: :post) 
  ...
end
```

It is essential to provide the implementation for your custom action as a simple `:using` Graphism hook.

### Hooks

Hooks are a mechanism in Graphism for customization. They are implemented as standard OTP behaviours.

Graphism supports the following types of hooks:

* `Graphism.Hooks.Simple` are suitable as `:using` hooks in custom actions.
* `Graphism.Hooks.Update` are suitable as `:before` hooks on standard `:update` actions. 
* `Graphism.Hooks.Allow` are suitable as `:allow` hooks in both standard or custom actions.

Please see the module documentations for further details.

### Scopes

Graphism provides with the `scope` construct as a convenience in order to implement access control using hooks. A scope
is defined by its name, an optional description, an `allow` hook and a `filter` hook. Eg:

```elixir
scope :blog, "Restrict access to posts within a blog" do
  allow post, context do
    data.blog.id == context.blog.id
  end

  filter posts, context do
    from(p in posts,
      where: p.blog_id == ^context.blog.id
    )
  end
end
```

In the above example, the `allow` clause will defined whether a given query or mutation on a post is allowed. 
The `filter` clause will make sure we only return posts that belong to the blog we currently have in the our context.
