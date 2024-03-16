# Graphism

An Elixir DSL that makes it faster & easier to build Absinthe powered GraphQL apis
on top of Ecto and Postgres.

## Contributing

Please make sure your read and honour [our contributing guide](CONTRIBUTING.md).

## Getting started

### Configure mix

Install the `graphism.new` mix task:

```bash
$ wget https://github.com/pedro-gutierrez/graphism_new/raw/main/graphism_new-0.1.0.ez
$ mix archive.install ./graphism_new-0.1.0.ez
```

### Create your project

```bash
$ mix graphism.new blog
```

and run the following commands:

```bash
$ cd blog
$ mix deps.get
$ mix compile
$ mix graphism.migrations
$ mix ecto.create
$ mix ecto.migrate
```

### Run it

The generated projects contains a sample schema with a single `user` entity.

Start the project:

```bash
$ iex -S mix
```

Then visit [http://localhost:4001/graphiql](http://localhost:4001/graphiql) and start sending GraphQL requests:

```graphql
mutation {
  user {
    create(email: "john@farscape.com") {
      id
      email
    }
  }
}
```

```graphql
query {
  users {
    all {
      id
      email
    }
  }
}
```

Don't forget to check the Documentation Explorer and discover all the queries and mutations that Graphism automatically generated for us.

### Next steps

From here, you might want to add new entities, attributes, unique keys, relations, custom actions etc.. to your schema.

For example, add the `:blog` and `:post` entities right after the existing `:user` entity:

```elixir
# lib/blog/schema.ex
defmodule Blog.Schema do
  use Graphism, repo: Blog.Repo

  ...

  entity :blog do
    unique(string(:name))
    belongs_to(:user, as: :owner)
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
    belongs_to(:user, as: :author, from: [:blog, :owner])

    action(:read)
    action(:list)
    action(:create)
    action(:update)
    action(:delete)
  end
end
```

Migrate your database:

```bash
$ mix graphism.migrations
$ mix ecto.migrate
```

Start your project:

```bash
$ iex -S mix
```

Then refresh the GraphiQL UI, and start testing these brand new features that you just **didn't need to
code** (note: the uuids below will be different for you):

```graphql
mutation {
  blog {
    create(name: "John's blog", owner: "353e3684-8a55-482e-9bab-b91149db03bb") {
      id
      name
      owner {
        id
        email
      }
    }
  }
}
```

```graphql
mutation {
  post {
    create(
      title: "Fetch the comfy chair"
      content: "It’s just like a VCR, except easier"
      blog: "b53a63c8-1400-4ca1-92eb-62cb3e73a782"
    ) {
      id
      title
      content
      blog {
        id
        name
        owner {
          id
          email
        }
      }
      author {
        id
        email
      }
    }
  }
}
```

That is all for this guide!

Keep reading if you want to learn about all the features offered by Graphism...

## Schema Features

### Attribute types

The following attribute types are supported:

- `string`
- `text`
- `integer`
- `bigint`
- `decimal`
- `float`
- `boolean`
- `datetime`
- `date`
- `time`
- `upload`
- `json`
- `slug`

Each of these types offers its own macro, for example:

```elixir
entity :event do
  string(:title)
  text(:description)
  boolean(:confirmed)
  datetime(:scheduled_at)
  ...
end
```

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

In order to set the initial value of a computed attribute, a `:before` or `:after` action hook can be used:

```elixir
entity :post do
  computed(boolean(:draft))

  action :create, before: [MarkAsDraft] do
  end
end
```

Alternatively, a `:using` hook can be specified at the field level:

```elixir
entity :post do
  computed(boolean(:draft), using: MarkAsDraft)
end
```

### Computed relations

Relations can also be declared as computed in two different ways, explicitly and implicitly. Explict computed relations are declared with a `:using` hook:

```elixir
entity :post do
  belongs_to(:blog)
  computed(belongs_to(:user), using: SetUserFromBlog)
end
```

Alternatively, relations can also be implicitly populated from the context:

```elixir
entity :post do
  belongs_to(:blog)
  belongs_to(:user, from_context: [:current_user]])
end
```

but also from other relations:

```elixir
entity :post do
  belongs_to(:blog)
  belongs_to(:user, from: :blog])
end
```

### Virtual attributes

Virtual attributes are similar to computed attributes in the sense that they are also part of your schema, and can be queried, however they are not stored:

```elixir
entity :post do
  virtual(integer(:likes), using: CountLikes)
end
```

Virtual attributes are evaluated by GraphQL resolvers that delegate to the configured `:using` hook. Because of this design choice, virtual attributes are not available from the Elixir api.

Also, since their values are expressed in Elixir, **virtual attributes cannot be used in scopes**. This is also obvious since scopes need to be translated into SQL and this would require virtual attributes to exist in the persistence, which would enter in contradiction with its own very nature.

In other words, if you are tempted to use virtual attributes in scopes, then most likely what you need is a computed attribute, not a virtual one.

Finally virtual attributes must define a `:using` hook, otherwise a compilation error will be raised, and virtual attributes are excluded from mutation arguments. In essence, they are a read-only, runtime feature.

### Slugs

Slugs are a special type of convenience, computed attribures:

```elixir
entity :post do
  string(:title)
  slug(:title)
  ...
```

This will automatically create a `:slug` attribute, that will be unique, and that will store a slug of the `:title` field.

### Self referencing entities

Sometimes it is useful to have schemas where an entity needs to reference itself, eg when building a tree-like structure:

```elixir
entity :node do
  maybe(belongs_to(:node, as: :parent))
  ...
end
```

### Virtual relations

Virtual relations work exactly the same as virtual attributes.

Since they are not persisted, virtual relations are ignored in mutations, migrations, lists and
aggregation queries.

For example if you define a virtual parent relation:

```elixir
entity :blog do
  virtual(belongs_to(:post))
end
```

then Graphism won't generate the usual `listByPost` or `aggregateByPost` queries for the `blog`
entity.


### Sorting results

It is possible to customize the default ordering of results when doing list queries:

```elixir
entity :post, sort: [desc: :inserted_at] do
...
end
```

The `:sort` options can take the following values:

- `:none`, meaning no default ordering should be applied.
- an Ecto compatible keyword list expression, eg `[desc: :inserted_at]`

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

- `read`
- `list`
- `create`
- `update`
- `delete`

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

- `Graphism.Hooks.Simple` are suitable as `:using` hooks in custom actions.
- `Graphism.Hooks.Update` are suitable as `:before` hooks on standard `:update` actions.
- `Graphism.Hooks.Allow` are suitable as `:allow` hooks in both standard or custom actions.

Please see the module documentations for further details.

### Absinthe middleware

Custom Absinthe middlewares can be also be plugged:

```elixir
use Graphism, repo: ..., middleware: [My.Middleware]
```

### Authorization

Graphism does not implement any specific authorization or access control scheme, however it provides a few callbacks so
that you can implement your own.

```elixir
defmodule MySchema do
  use Graphism, repo: MyRep

  allow(MyAuth)
  ...
end
```

In the above example:

- `MyAuth` is an allow hook that needs to implement both `allow/2` and `scope/2`.

Please note authorization is completely optional.

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

For optional parent relations, it is possible to nullify the value pointed at with:

```elixir
entity :node do
  ...
  maybe_belongs_to(:node, as: parent, delete: :set_nil)
  ...
end
```

### Schema introspection

Sometimes you might need to be able to instrospect your schema in a programmatic way. Graphism generates
for you several useful functions:

- `field_spec/1`
- `field_specs/1`
- `inverse_relation/1`

Examples:

```elixir
iex> MyBlog.Schema.Post.field_spec("body")
{:ok, :string, :body}

iex> MyBlog.Schema.Post.field_spec("comments")
{:ok, :has_many, :comment, MyBlog.Schema.Comment}

iex> MyBlog.Schema.Post.inverse_relation("comments")
{:ok, :belongs_to, :blog, MyBlog.Schema.Post, :blog_id}

iex> MyBlog.Schema.Comment.field_spec("blog")
{:ok, :belongs_to, :blog, MyBlog.Schema.Post, :blog_id}

iex> MyBlog.Schema.Comment.field_specs({:belongs_to, MyBlog.Schema.Post})
[{:belongs_to, :blog, MyBlog.Schema.Post, :blog_id}]


```

### Schema querying

Since v0.9.0, Graphism provides with a high level `filter/1` query api that allows you to form complex Ecto queries with little
code.

Example:

```elixir
iex> Blog.Schema.filter({Blog.Schema.Comment, [:post, :slug], :eq, "P123"}

#Ecto.Query<from c0 in Blog.Schema.Comment, as: :comment,
 join: p1 in Blog.Schema.Post, as: :post, on: p1.id == c0.post_id,
 where: p1.slug == ^"P123">
```

A more complex example:

```elixir
iex> Blog.Schema.filter({:intersect, [
  {Blog.Schema.Comment, [:post, :slug], :eq, "P123"},
  {Blog.Schema.Comment, [:"**", :user], :eq, Ecto.UUID.generate()},
  {Blog.Schema.Comment, [[:post], [:"**", :user]], :eq, Ecto.UUID.generate()},
  {:union, [
    {Blog.Schema.Comment, [:post, :slug], :eq, "P098"},
    {Blog.Schema.Comment, [:comment, :post, :slug], :eq, "P091"},
    {Blog.Schema.Comment, [:"**", :user], :eq, Ecto.UUID.generate()}
  ]}
]})

#Ecto.Query<from c0 in Blog.Schema.Comment, as: :comment,
join: p1 in Blog.Schema.Post, as: :post, on: p1.id == c0.post_id,
where: p1.slug == ^"P123",
intersect: (from c0 in Blog.Schema.Comment,
as: :comment,
join: p1 in Blog.Schema.Post,
as: :post,
on: p1.id == c0.post_id,
where: p1.user_id == ^"5ed1fb19-4f1b-4926-abe0-0a28fb42dadd"),
intersect: (from c0 in Blog.Schema.Comment,
as: :comment,
where: c0.post_id == ^"5064fe2a-e392-4a2a-92d5-86c85befced7",
union: (from c0 in Blog.Schema.Comment,
as: :comment,
join: p1 in Blog.Schema.Post,
as: :post,
on: p1.id == c0.post_id,
where: p1.user_id == ^"5064fe2a-e392-4a2a-92d5-86c85befced7")),
intersect: (from c0 in Blog.Schema.Comment,
as: :comment,
join: p1 in Blog.Schema.Post,
as: :post,
on: p1.id == c0.post_id,
where: p1.slug == ^"P098",
union: (from c0 in Blog.Schema.Comment,
as: :comment,
join: p1 in Blog.Schema.Post,
as: :post,
on: p1.id == c0.post_id,
where: p1.slug == ^"P091"),
union: (from c0 in Blog.Schema.Comment,
as: :comment,
join: p1 in Blog.Schema.Post,
as: :post,
on: p1.id == c0.post_id,
where: p1.user_id == ^"f6dc2148-7012-4fde-820e-a2dd4699d122"))>
```

### Schema evaluation

Similar to the query api, Graphism also provides with an `evaluate/2` api, that recursively resolves paths on a context.

For example the expression:

```elixir
iex> user = %Blog.Schema.User{id: ...}
iex> Blog.Schema.evaluate(user, [:posts, comments, :text])
```

would return all the comments' texts for the user found in the context.

Relations are resolved lazily and cached.

### Fuzzy comparisons

In addition to the `query/1` and `evaluate/2` apis, the `compare/3` performs fuzzy comparions on data.

The following comparators are supported:

- `:eq`
- `:neq`
- `:lt`
- `:lte`
- `:gt`
- `:gte`
- `:in`
- `:not_in`

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
  color {
    create(data: "{ \"r\": 255, \"g\": 0, \"b\": 0 }") {
      id
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

| event                           | measurement | metadata                     |
| ------------------------------- | ----------- | ---------------------------- |
| `[:graphism, :allow, :stop]`    | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :scope, :stop]`    | `:duration` | `:entity`, `:kind`, `:value` |
| `[:graphism, :relation, :stop]` | `:duration` | `:entity`, `:relation`       |

You can also subscribe to the `[:start]` and `[:exception]` events, since Graphism relies on `:telemetry.span/3`.

### REST

Since v0.8.0, Graphism now also generates a REST api for your schema.

To enable this, select the `:rest` style:

```elixir
defmodule MySchema do
  use Graphism, repo: MyRepo, styles: [:rest]
end
```

Graphism will then generate a router module for your schema, an OpenApi 3.0 spec and a RedocUI static html so that you
can easily discover your api.

Sample configuration using Plug:

```elixir
defmodule MyRouter do
  use Plug.Router

  plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Jason
  )
  plug :match
  plug :dispatch
  ...
  forward("/api", to: MySchema.Router)
  get("/redoc", to: MySchema.RedocUI, init_opts: [spec_url: "/api/openapi.json"])>
  ...
end
```
