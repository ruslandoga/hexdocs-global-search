defmodule Doku.Repo.Migrations.AddDocs do
  use Ecto.Migration

  def change do
    create table(:docs, options: "STRICT") do
      add :title, :text, null: false
      add :ref, :text, null: false
      add :doc, :text, null: false
      add :function, :text
      add :module, :text
      add :type, :text, null: false
      add :package, :text, null: false
    end

    create index(:docs, [:title])
    create index(:docs, [:function])
    create index(:docs, [:module])

    create table(:packages, primary_key: false, options: "STRICT, WITHOUT ROWID") do
      add :name, :text, primary_key: true, null: false
      add :recent_downloads, :integer, null: false, default: 0
    end

    create index(:packages, [:recent_downloads])
  end
end
