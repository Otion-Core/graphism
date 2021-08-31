# Graphism

An Elixir DSL that makes it easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.

<p align="center">
  <img height="350" src="https://support.bite.social/images/graphism.png">
</p>

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
$ mix graphism.gen.migrations

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

By default, Graphism embeds the great PromEx library in order to provide with built-in Prometheus metrics for all of your generated schema queries and mutations, but also for your Ecto repositories. 

For example, if your Graphism schema is `MyBlog.Schema`, then all your need to do is to add the generated 
module `MyBlog.Schema.Metrics` to the top of your supervision tree.

```elixir
defmodule MyBlog.Application do
  def start(_type, _args) do
    children = [
      MyBlog.Schema.Metrics,
      ...
    ]
    ...
  end
  ...
```

With this simple configuration, your metrics will be available at "/metrics". If you wished to customize 
the path, add the `metrics` option to your Graphism.Plug:

```elixir
use Graphism.Plug, schema: MyBlog.Schema, metrics: "/metrics/blog"
```

## Schema Modifiers :abacus:

We have two types of modifiers. Entity modifiers and attribute modifiers. They both allow customizations in behaviour.

### Entity modifiers

| Modifier | Description |
| --- | --- | 
| `internal`   |  indicates the entity is persisted, but is not part of the graphql api |
| `virtual` | indicates the entity is part of the graphql api, but is not persisted |

### Attribute modifiers

| Modifier | Description |
| --- | --- | 
| `optional`    |  indicates the attribute is optional (ie can be omitted in mutations, and will accept null values in the database) |
| `private`    | indicates the attribute is private and can only be written from the graphql api|
| `computed`    | indicates the attribute is computed and can only be read from the graphql api|


## Github Workflow :dna:
Our commit convention follows [conventionalcommits.org](https://www.conventionalcommits.org) workflow.

### General commit message pattern
`type(scope?): description`

* `type` - Possible values are `feat | fix | refactor | perf | docs | style | test | chore | ci`.
* `scope` - Any scope to which `type` applies, usually we either omit scope or use the component name / part of the app name.
* `description` - Description of changes, needs to start with **lowercase** character to pass checks.

### Supported types:
 - **feat** - a new feature

  `feat(scope): description` or `feat: description`
 - **fix** - a bug fix

  `fix(scope): description` or `fix: description`
 - **refactor** - a code change that neither fixes a bug nor adds a feature

  `refactor(scope): description` or `refactor: description`
 - **perf** - a code change that improves performance

  `perf(scope): description` or `perf: description`
 - **docs** - documentation only changes

  `docs(scope): description` or `docs: description`
 - **style** - changes that do not affect the meaning of the code (white-space, formatting, missing semi-colons, etc)

  `style(scope): description` or `style: description`
 - **test** - adding missing tests or correcting existing tests

  `test(scope): description` or `test: description`
 - **chore** - other changes that don't modify src or test files

  `chore(scope): description` or `chore: description`
 - **ci** - changes to our CI configuration files and scripts

  `ci(scope): description` or `ci: description`

### Introducing breaking changes
We try to always provide backward-compatible changes to our API but, if it’s necessary we might introduce a breaking change, we can do it by adding magic constant `BREAKING CHANGE` somewhere to commit description. This triggers `major` version bump to the package version.
