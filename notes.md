### index all functions ranked by package popularity

This would make UI similar to devdocs possible.

```elixir
Doku.post("collections", %{
  "name" => "functions",
  "default_sorting_field" => "recent_downloads",
  "token_separators" => ["."],
  "fields" => [
    %{"name" => "package", "type" => "string", "facet" => true},
    %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
    %{"name" => "title", "type" => "string"},
    %{"name" => "recent_downloads", "type" => "int32"}
  ]
})
```

Example search that filters functions in related packages only:

```elixir
collection = "functions"
query = %{"q" => "json", "query_by" => "title", "filter_by" => "package:[ecto,ecto_sql,phoenix]"}
take_fields = ["package", "ref"]

result = Doku.search(collection, query, take_fields)

result == [
  %{"package" => "ecto", "ref" => "Ecto.Query.API.html#json_extract_path/2"},
  %{"package" => "phoenix", "ref" => "Phoenix.ConnTest.html#json_response/2"},
  %{"package" => "phoenix", "ref" => "Phoenix.Controller.html#json/2"},
  %{"package" => "phoenix", "ref" => "Phoenix.html#json_library/0"}
]
```

This can also be achieved automatically by using geosearch with coordinates representing package position in 2d map of hex.pm.

```elixir

```

Typesense instance with these docs deployed on digitalocean:

Integrating into ex_doc:

Example package using this ex_doc version:

### index both functions and guides headers

### index everything (functions, docs, guides)

### semantic search
