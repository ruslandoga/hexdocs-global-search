- index all functions ranked by package popularity

For UI similar to devdocs

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

Example search that filters functions in related packages only

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

- [x] search headers (autocomplete)
- [x] build vectors.json with node2vec
- [x] related packages v0.25-rc as node2vec
- [x] sorting by vector distance https://github.com/typesense/typesense/issues/1137#issuecomment-1671260221
- [x] limit by type?
- [x] semantic search
- [ ] join on packages v0.26-rc https://github.com/typesense/typesense/issues/1164
- [ ] reproduce ex_doc behaviour as much as i can
- [ ] index docs field (full search)
- [ ] upload search index on s3
- [ ] deploy typesense on digitalocean
- [ ] integrate into fork of ex_doc
- [ ] use forked ex_doc in before_ch, mua, bamboo_mua, swoosh_mua
- [ ] ~~related packages 2d~~ decided not to do
