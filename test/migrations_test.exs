defmodule MigrationsTest do
  use ExUnit.Case
  alias Graphism.Migrations

  test "detects when an existing field becomes optional" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
        optional(string(:tags))
        action(:list)
        action(:create)
      end
    end

    opts = [
      module: MySchema,
      write_to_disk: false,
      files: [
        """
        defmodule(Graphism.Migration.V1) do
          use(Ecto.Migration)

          def(up) do
            create(table(:blogs, primary_key: false)) do
              add(:id, :uuid, null: false, primary_key: true)
              add(:tags, :string, null: false)
            end
          end

          def(down) do
          end
        end
        """
      ]
    ]

    assert [migration] = Migrations.generate(opts)

    assert migration =~ "alter(table(:blogs))"
    assert migration =~ "modify :tags, :string, null: true"
  end
end
