Start typesense

```console
$ docker run -p 8108:8108 -v kex_typesense_data:/data typesense/typesense:0.24.1 --data-dir /data --api-key=kex
```

Build the index

```elixir
Doku.scrape()
Doku.import_collection()
```

Try

```elixir
Doku.search(%{"query_by" => "title", "q" => "assert"})
```
