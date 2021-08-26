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

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "alter(table(:blogs))"
    assert code =~ "modify(:tags, :string, null: true)"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "adds values to existing enums" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      data(:topics, [:nature, :science])

      entity :blog do
        string(:tags)
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
            execute("create type topics as ENUM ('nature','life')")

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

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "alter type topics add value 'science'"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "drops enums that are no longer in use" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
        string(:tags)
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
            execute("create type topics as ENUM ('nature','life')")

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

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "drop type topics"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "adds unique constraints on existing columns" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
        unique(string(:name))
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
              add(:name, :string, null: false)
            end
          end

          def(down) do
          end
        end
        """
      ]
    ]

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "create(unique_index(:blogs, [:name], name: :unique_name_in_blogs))"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "removes unique constraints from existing columns" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
        string(:name)
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
              add(:name, :string, null: false)
            end

            create(unique_index(:blogs, [:name], name: :unique_name_in_blogs))
          end

          def(down) do
          end
        end
        """
      ]
    ]

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "drop_if_exists(index(:blogs, [:name], name: :unique_name_in_blogs))"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "also adds unique indices when adding new columns to existing tables" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
        unique(string(:name))
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
            end
          end

          def(down) do
          end
        end
        """
      ]
    ]

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "alter(table(:blogs))"
    assert code =~ "add(:name, :string, unique: true, null: false)"
    assert code =~ "create(unique_index(:blogs, [:name], name: :unique_name_in_blogs))"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end

  test "also drops unique indices when removing columns from existing tables" do
    defmodule MySchema do
      use Graphism, repo: TestRepo

      entity :blog do
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
              add(:name, :string, unique: true, null: false)
            end

            create(unique_index(:blogs, [:name], name: :unique_name_in_blogs))
          end

          def(down) do
          end
        end
        """
      ]
    ]

    assert [path: _, code: code] = Migrations.generate(opts)
    assert code
    assert code =~ "alter(table(:blogs))"
    assert code =~ "remove(:name)"
    assert code =~ "drop_if_exists(index(:blogs, [:name], name: :unique_name_in_blogs))"

    opts = Keyword.put(opts, :files, opts[:files] ++ [code])
    assert [] = Migrations.generate(opts)
  end
end
