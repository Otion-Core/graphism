# Graphism

An Elixir DSL that makes it faster & easier to build Absinthe powered GraphQL apis 
on top of Ecto and Postgres.

## Contributing

Please make sure your read and honour [our contributing guide](CONTRIBUTING.md).

## Getting started

### Setting up your project

These steps will setup a minimal Elixir project for a blogging application:

```bash
$ mix new --sup blog
```

### Add Graphism to your project

Include Graphism in our list of dependencies:

```elixir
def deps do
  [
    {:graphism, git: "https://github.com/gravity-core/graphism.git", tag: "v0.7.1"}
  ]
end
```

and add it to the list of extra applications:

```elixir
 def application do
    [
      extra_applications: [:graphism],
      ...
    ]
  end
```

Fetch all dependencies and compile the project:

```bash
$ mix deps.get
$ mix compile
```

### Database setup

Configure a new Ecto repo module:

```elixir
# lib/blog/repo.ex
defmodule Blog.Repo do
  use Ecto.Repo, 
    :otp_app: :blog, 
    adapter: Ecto.Adapters.Postgres
end
```

```elixir
# config/config.exs
import Config

config :blog, ecto_repos: [Blog.Repo]
```

and connect it to our database:

```elixir
# config/runtime.exs
import Config

config :blog, Blog.Repo, database: "blog"
```

Lets not forget to actually create the Postgres database!

```bash
$ createdb blog
```

Finally, let's start the repo when our application starts:

```elixir
# lib/blog/application.ex
defmodule Blog.Application do
  ...
  def start(_type, _args) do
    children = [
      ...
      Blog.Repo, # <-- add this
      ...
    ]
  ...
end`
```

At this point, the project should be able to boot:

```bash
$ iex -S mix
```

and it should be able to connect okay:

```
iex> Ecto.Adapters.SQL.query(Blog.Repo, "SELECT 1")
```

### Our first Graphism schema

At this point, we are ready to bootstrap our first Graphism schema.

```elixir
# lib/blog/schema.ex
defmodule Blog.Schema do
  use Graphism, repo: Blog.Repo
  
  allow(Blog.Auth)

  entity :blog do
    string(:name)
    
    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end   
end
```

For now, our authorization module will simply allow access to everything:

```elixir
# lib/blog/auth.ex
defmodule Blog.Auth do
  def allow?(_data, _context), do: true    
  def scope(query, _context), do: query  
end
```

### Migrating the database

With this, we are almost ready to migrate our database. 

But first, we need to tell Graphism about our schema.

```elixir
# config/config.exs
config :graphism, schema: Blog.Schema
```

Then, let Graphism figure out things:

```bash
$ mix graphism.migrations
```

Have a look at the generated migration in your `priv/repo/migrations` folder. 

Then, as usual, migrate the database with:

```bash
$ mix ecto.migrate
```

If everything went okay, you should have a new `blog` table in your database with some default columns such a `uuid` primary key and timestamps. 

### Exposing our api

For simplicity, lets stick with `Cowboy` and `Plug`:

```elixir
# lib/blog/api.ex
defmodule Blog.Api do
  def child_spec(_) do
    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Blog.Endpoint,
      options: [port: 4001]
    )
  end
end
```

and a minimal endpoint:

```elixir
# lib/blog/endpoint.ex
defmodule Blog.Endpoint do
  use Plug.Router

  use Graphism.Plug, schema: Blog.Schema

  get "/health" do
    send_resp(conn, 200, "")
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
```

Let's not forget to add the api to our supervision tree:

```elixir
# lib/blog/application.ex
defmodule Blog.Application do
  ...
  def start(_type, _args) do
    children = [
      ...
      Blog.Repo,
      Blog.Api  # <-- add this
      ...
    ]
  ...
end`
```

Start the IEx with `mix -S mix` and, visit http://localhost:4001/graphiql and start playing:

```graphql
mutation {
  blog{
    create(name: "My first blog") {
      id,
      name
    }
  }
}
```

```graphql
query {
  blogs {
    all {
      id,
      name
    }
  }
}
```

Don't forget to check the Documentation Explorer, in order to learn about all the queries and mutations that Graphism automatically generated for us.

### Next steps

Our project is now up and running !

From here, you might want to add new entities, attributes, unique keys, relations, custom actions etc.. to your schema.

For example:

```elixir
# lib/blog/schema.ex
defmodule Blog.Schema do
  use Graphism, repo: Blog.Repo

  allow(Blog.Auth)

  entity :user do
    unique(string(:email))
    has_many(:blogs)

    action(:create)
    action(:list)
  end

  entity :blog do
    unique(string(:name))
    optional(belongs_to(:user, as: :owner))
    has_many(:posts)

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end

  entity :post do
    string(:title)
    text(:content)
    belongs_to(:blog)
    optional(belongs_to(:user, as: :author, from: :blog))

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end
end
```

Don't forget to run 

```bash
$ mix graphism.migrations
$ mix ecto.migrate
```

Start your IEx session, visit the GraphiQL UI, and start testing these brand new features that you just **didn't need to
code**:

```graphql
mutation {
  user {
    create(email:"foo@bar.com") {
      id
    }
  }
}
```

```graphql
mutation {
  blog{
    create(name: "My second blog", owner: "353e3684-8a55-482e-9bab-b91149db03bb") {
      id,
      name,
      owner {
        id
      }
    }
  }
```

Keep reading if you want to learn about all the features offered by Graphism.

## Schema Features

### Unique attributes

If you wish to ensure unicity, you can declare a field being `:unique`:

```elixir
entity :user do
  unique(string(:email))
  ...
end
```

Graphism will generate proper GraphQL queries for you, as well as indices in your database migrations.


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

### Self referencing entities

Sometimes it is useful to have schemas where an entity needs to reference itself, eg when building a tree-like structure:

```elixir
entity :node do
  maybe(belongs_to(:node, as: :parent))
  ...
end
```

### Sorting results

It is possible to customize the default ordering of results when doing list queries:

```elixir
entity :post, sort: [desc: :inserted_at] do
...
end 
```

The `:sort` options can take the following values:

* `:none`, meaning no default ordering should be applied.
* an Ecto compatible keyword list expression, eg `[desc: :inserted_at]`

If not specified, then `[asc: :inserted_at]` will be used by default.

### Immutable fields

Attributes or relations can be made immutable. This means once they are initialized, they cannot be modified:

```elixir
entity :file do
  ...
  immutable(upload(:content))
  ...
end
```

### Non empty fields

Sometimes we need fields that are optional at the api level, while ensuring non empty values are stored in the database:

```elixir
entity :file do
  ...
  optional(non_empty(string(:name))
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

### Aggregate queries

In addition to listing entities, it is also possible to aggregate (eg. count) them. 

```
query {
  contacts {
    aggregateAll {
      count
    }
  }
}
```

These will be generated by Graphism for you. 


### User defined lists

Sometimes the default lists added by Graphism might not suit you and it is possible that you need to
define your own queries:

```elixir
entity :post do
  list(:my_custom_query, args: [...], using: MyBlog.Post.MyCustomQuery)
end
```

All you need need to do is return an ok tuple with the query to execute. 

Graphism will automatically add support for sorting and pagination for you. In addition, Graphism will also generate
custom aggregations so that you can also run:

```
query {
  posts {
    aggregateMyCustomQuery(...) {
      count 
    }
  }
}
```

### Lookup arguments

Let's say you want to create an invite for a user. Here is a basic schema:

```elixir
entity :user do
  unique(string(:email))
  ...
end

entity :invite do
  belongs_to(:user)
  action(:create)
  ...
end
```

With this, your create invite mutation will receive the ID of an existing user. But in practice,
sometimes it might happen that you don't know that user's id, just their email.

In that case, you can tell Graphism to lookup the user by their email for you:

```elixir
entity :invite do
  ...
  action(:create, lookup: [user: :email])
  ...
end
```

Graphism will however complain if the lookup you are defining is not based on a unique key.

### Client generated ids

Sometimes it makes more sense to let the client specify their own ids:

```elixir
entity :item, modifiers: [:client_ids] do
  ...
  action(:create)
  ...
end
```

This will stop Graphism from generating ids for you. However you will still need to pass in a valid
UUID v4 string.

### Composite keys

By default, Graphism uses UUIDs as primary keys, and, as you've already seen, it is also possible to define
unique keys, such as a name, or an email, using the `unique(string(:name))` or `unique(string(:email))` notation.

But sometimes unique keys are made of more than just one field:

```elixir
entity :user do
  unique(string(:name))
end
      
entity :organisation do 
  unique(string(:name))
end

entity :membership do
  belongs_to(:user)
  belongs_to(:organisation)
  key([:user, :organisation]) # <-- composite key
  action(:read)
end
```

In the above example, we are saying that a user can belong to an organisation only once. Graphism will take
care of creating the right indices and GraphQL queries for you.

### Non unique keys

Composite keys can be turned into indices by setting `unique: false`.

In this case, Graphism will automatically generate list and aggregate queries for you.

### Hooks

Hooks are a mechanism in Graphism for customization. They are implemented as standard OTP behaviours.

Graphism supports the following types of hooks:

* `Graphism.Hooks.Simple` are suitable as `:using` hooks in custom actions.
* `Graphism.Hooks.Update` are suitable as `:before` hooks on standard `:update` actions. 
* `Graphism.Hooks.Allow` are suitable as `:allow` hooks in both standard or custom actions.

Please see the module documentations for further details.

### Absinthe middleware

Custom Absinthe middlewares can be also be plugged:

```elixir
use Graphism, repo: ..., middleware: [My.Middleware]
```

### Skippable migrations

Sometimes we need to write our own custom migrations. It is possible to tell Graphism to ignore these
by setting the `@graphism` module attribute:

```elixir
defmodule My.Custom.Migration do
  use Ecto.Migration

  @graphism [:skip] # add the :skip option

  def up do
    execute("...")
  end
end
```

### Pagination and sorting

Graphism will build all your queries with optional sorting and pagination. 

Based on this simple entity:

```elixir
entity :contact do
  string(:first_name)
  string(:last_name)
  action(:list)
end
```

You can query all your contacts by chunks:

```
query {
  contacts {
    all(sortBy: "lastName", sortDirection: ASC, limit: 20, offset: 40) {
      firstName,
      lastName
    }
  }
}
```



### Cascade deletes

By default, it is not possible to delete an entity if it has children entities pointing to it. But this can be
overriden on a per-relation basis:

```elixir
entity :node do
  ...
  belongs_to(:node, as: parent, delete: :cascade)
  ...
end
```

Graphism will take of writing the correct migrations, including dropping existing constraints, in order to fully support
changes in this policy.

### Schema introspection

Sometimes you might need to be able to instrospect your schema in a programmatic way. Graphism generates
for you a couple of useful functions:

* `field_spec/1`
* `field_specs/1`

Examples:

```elixir
iex> MyBlog.Schema.Post.field_spec("body")
{:ok, :string, :body}

iex> MyBlog.Schema.Post.field_spec("comments")
{:ok, :has_many, :comment, MyBlog.Schema.Comment}

iex> MyBlog.Schema.Comment.field_spec("blog")
{:ok, :belongs_to, :blog, MyBlog.Schema.Post, :blog_id}

iex> MyBlog.Schema.Comment.field_specs({:belongs_to, MyBlog.Schema.Post})
[{:belongs_to, :blog, MyBlog.Schema.Post, :blog_id}]
```

### Json types

Graphism allows you to define attributes of `json` type in order to store unstructured data as maps or arrays:

```elixir
entity :color do
  json(:data)
  action(:create)
  action(:list)
end
```

With this, you can define the `data` as a string value in your mutation:

```graphql
mutation {
  color{
    create(data: "{ \"r\": 255, \"g\": 0, \"b\": 0 }") {
     id,
     data 
    }
  }
}
```

And you will get the data back as json:

```json
{
  "data": {
    "color": {
      "create": {
        "id": "eb40ddfb-2208-4588-b57f-0931fa18c0fe",
        "data": {
          "b": 0,
          "g": 0,
          "r": 255
        }
      }
    }
  }
}
```

### Telemetry

Graphism emits telemetry events for various operations and publishes their duration:

| event | measurement | metadata |
| --- | --- | --- |
| `[:graphism, :allow, :stop]` | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :scope, :stop]` | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :relation, :stop]` | `:duration` | `:entity`, `:relation` |

You can also subscribe to the `[:start]` and `[:exception]` events, since Graphism relies on `:telemetry.span/3`.
