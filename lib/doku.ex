defmodule Doku do
  @moduledoc """
  Documentation for `Doku`.
  """

  @stdlib ["elixir", "eex", "ex_unit", "iex", "logger", "mix"]

  # for full text search
  def scrape do
    File.mkdir("index")

    packages = Enum.shuffle(packages() ++ Enum.map(@stdlib, &%{name: &1}))
    downloaded = MapSet.new(File.ls!("index") |> Enum.map(&String.trim_trailing(&1, ".json")))

    packages
    |> Enum.reject(fn package -> MapSet.member?(downloaded, package.name) end)
    |> async_stream(&__MODULE__.maybe_download_index/1,
      timeout: :timer.seconds(60),
      ordered: false,
      max_concurrency: 50
    )
    |> Stream.run()
  end

  # for autocomplete
  def scrape_sidebar_items do
    File.mkdir("sidebar")

    packages = Enum.shuffle(packages() ++ Enum.map(@stdlib, &%{name: &1}))
    downloaded = MapSet.new(File.ls!("sidebar") |> Enum.map(&String.trim_trailing(&1, ".json")))

    packages
    |> Enum.reject(fn package -> MapSet.member?(downloaded, package.name) end)
    |> async_stream(&__MODULE__.maybe_download_sidebar/1,
      timeout: :timer.seconds(60),
      ordered: false,
      max_concurrency: 50
    )
    |> Stream.run()
  end

  # for popularity ranking
  def scrape_stats do
    File.mkdir("stats")

    config = :hex_core.default_config()

    packages(config)
    |> async_stream(fn package -> maybe_download_stats(config, package) end,
      timeout: :timer.seconds(60),
      ordered: false,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Stream.run()
  end

  # don't need
  def scrape_tarballs do
    File.mkdir("tarballs")

    config = :hex_core.default_config()

    versions(config)
    |> async_stream(fn package -> maybe_download_tarball(config, package) end,
      timeout: :timer.seconds(60),
      ordered: false,
      max_concurrency: 100
    )
    |> Stream.run()
  end

  # don't need
  def scrape_releasess do
    File.mkdir("releases")

    config = :hex_core.default_config()

    packages(config)
    |> async_stream(fn package -> maybe_download_release(config, package) end,
      ordered: false,
      max_concurrency: 100
    )
    |> Stream.run()
  end

  def maybe_download_index(package) do
    %{name: name} = package

    if File.exists?("index/" <> name <> ".json") do
      warning("#{name} already downloaded")
    else
      debug("starting #{name}...")

      case Finch.request!(Finch.build(:get, "https://hexdocs.pm/#{name}/search.html"), Doku.Finch,
             receive_timeout: :timer.seconds(60)
           ) do
        %Finch.Response{status: 200, body: body} ->
          html = Floki.parse_document!(body)
          scripts = Floki.find(html, "script")

          if index_url =
               find_script(scripts, "dist/search_data") ||
                 find_script(scripts, "dist/search_items") do
            %Finch.Response{status: 200, body: body} =
              Finch.request!(
                Finch.build(:get, "https://hexdocs.pm/#{name}/" <> index_url),
                Doku.Finch,
                receive_timeout: :timer.seconds(60)
              )

            json =
              case body do
                "searchNodes=" <> json -> json
                "searchData=" <> json -> json
              end

            File.write!("index/" <> name <> ".json", json)
            info("downloaded #{name}")
          end

        %Finch.Response{status: 404} ->
          error("no search page for #{name}")
      end
    end
  end

  def maybe_download_sidebar(package) do
    %{name: name} = package

    if File.exists?("sidebar/" <> name <> ".json") do
      warning("#{name} already downloaded")
    else
      debug("starting #{name}...")

      case Finch.request!(Finch.build(:get, "https://hexdocs.pm/#{name}/index.html"), Doku.Finch,
             receive_timeout: :timer.seconds(60)
           ) do
        %Finch.Response{status: 200, body: body} ->
          case body
               |> Floki.parse_document!()
               |> Floki.find("meta[http-equiv=refresh]") do
            [{"meta", [{"http-equiv", "refresh"}, {"content", "0; url=" <> path}], []}] ->
              case Finch.request!(
                     # https://hexdocs.pm/supabase_types/Supabase Types.html
                     Finch.build(:get, "https://hexdocs.pm/#{name}/" <> URI.encode(path)),
                     Doku.Finch,
                     receive_timeout: :timer.seconds(60)
                   ) do
                %Finch.Response{status: 200, body: body} ->
                  html = Floki.parse_document!(body)
                  scripts = Floki.find(html, "script")

                  if sidebar_url = find_script(scripts, "dist/sidebar_items") do
                    case Finch.request!(
                           Finch.build(
                             :get,
                             # https://hexdocs.pm/stationary/dist/sidebar_items-04a9b1e5a6 5.js
                             "https://hexdocs.pm/#{name}/" <> URI.encode(sidebar_url)
                           ),
                           Doku.Finch,
                           receive_timeout: :timer.seconds(60)
                         ) do
                      %Finch.Response{status: 200, body: body} ->
                        case body do
                          "sidebarNodes=" <> json ->
                            File.write!("sidebar/" <> name <> ".json", json)

                          "sidebarNodes = " <> json ->
                            File.write!("sidebar/" <> name <> ".json", json)
                        end

                        info("downloaded #{name}")

                      %Finch.Response{status: 404} ->
                        error("no sidebar for #{name} (404 for #{sidebar_url}")
                    end
                  else
                    error("no sidebar for #{name} (script not found in HTML)")
                  end

                %Finch.Response{status: 404} ->
                  error("no sidebar for #{name} (404 after redirect)")
              end

            _not_hexdocs ->
              error("no sidebar for #{name} (not hexdocs)")
          end

        %Finch.Response{status: 404} ->
          error("no sidebar for #{name} (404)")
      end
    end
  end

  defp find_script(scripts, prefix) do
    Enum.find_value(scripts, fn {"script", attrs, _children} ->
      if src = :proplists.get_value("src", attrs, nil) do
        if String.starts_with?(src, prefix) do
          src
        end
      end
    end)
  end

  def async_stream(enumerable, fun, opts \\ []) do
    Task.Supervisor.async_stream(Doku.TaskSupervisor, enumerable, fun, opts)
  end

  def packages(config \\ :hex_core.default_config()) do
    {:ok, {200, _headers, %{packages: packages}}} = :hex_repo.get_names(config)
    packages
  end

  def versions(config \\ :hex_core.default_config()) do
    {:ok, {200, _headers, %{packages: packages}}} = :hex_repo.get_versions(config)
    packages
  end

  def maybe_download_stats(config, package) do
    %{name: name} = package

    if File.exists?("stats/" <> name <> ".json") do
      warning("#{name} already downloaded")
    else
      debug("starting #{name}...")

      case :hex_api.get(config, ["packages", name]) do
        {:ok, {200, _headers, stats}} ->
          json = Jason.encode_to_iodata!(stats)
          File.write!("stats/" <> name <> ".json", json)
          info("downloaded #{name}")

        {:ok, {429, headers, _body}} ->
          reset_at = Map.fetch!(headers, "x-ratelimit-reset")
          sleep_for = String.to_integer(reset_at) - :os.system_time(:second)

          if sleep_for > 0 do
            debug("sleeping for #{sleep_for} seconds")
            :timer.sleep(:timer.seconds(sleep_for))
          end

          maybe_download_stats(config, package)
      end
    end
  end

  def maybe_download_release(config, package) do
    %{name: name} = package

    if File.exists?("releases/" <> name <> ".json") do
      warning("#{name} already exists")
    else
      debug("starting #{name}...")

      case :hex_repo.get_package(config, name) do
        {:ok, {200, _headers, package}} ->
          %{releases: releases} = package
          releases = Enum.reject(releases, & &1[:retired])
          latest_release = List.last(releases)

          if latest_release do
            json =
              latest_release
              |> Map.take([:version, :dependencies])
              |> Jason.encode_to_iodata!()

            File.write!("releases/" <> name <> ".json", json)
            info("downloaded #{name}")
          else
            warning("#{inspect(package)} doesn't have a valid release")
          end

        {:ok, {429, headers, _body}} ->
          reset_at = Map.fetch!(headers, "x-ratelimit-reset")
          sleep_for = String.to_integer(reset_at) - :os.system_time(:second)

          if sleep_for > 0 do
            debug("sleeping for #{sleep_for} seconds")
            :timer.sleep(:timer.seconds(sleep_for))
          end

          maybe_download_release(config, package)
      end
    end
  end

  def maybe_download_tarball(config, package) do
    %{name: name} = package

    if File.exists?("tarballs/" <> name <> ".tar.gz") do
      warning("#{name} already downloaded")
    else
      debug("starting #{name}...")

      if version = latest_version(package) do
        {:ok, {200, _headers, tarball}} =
          :hex_repo.get_tarball(config, name, version)

        File.write!("tarballs/" <> name <> ".tar.gz", tarball)
        info("downloaded #{name}")
      else
        warning("#{inspect(package)} doesn't have a valid version")
      end
    end
  end

  def process_downloads do
    rows =
      Path.wildcard("downloads/*.json")
      |> Enum.map(fn path ->
        json = :json.decode(File.read!(path))

        downloads =
          Enum.map(["all", "recent", "week", "day"], fn field -> Map.get(json, field) end)

        [String.replace(path, ["downloads/", ".json"], "") | downloads]
      end)

    File.write!(
      "downloads.csv",
      NimbleCSV.RFC4180.dump_to_iodata([["package", "all", "recent", "week", "day"] | rows])
    )
  end

  def process_index do
    rows =
      Path.wildcard("index/*.json")
      |> Enum.flat_map(fn path ->
        json = File.read!(path)

        docs =
          try do
            :json.decode(json)
          rescue
            _e ->
              fixed_json = fix_json(json)
              :json.decode(fixed_json)
          end

        items =
          case docs do
            %{"items" => items} -> items
            items when is_list(items) -> items
          end

        package = path |> Path.basename() |> Path.rootname(".json")

        Enum.map(items, fn item ->
          [
            package,
            Map.fetch!(item, "type"),
            Map.fetch!(item, "ref"),
            Map.fetch!(item, "title"),
            Map.fetch!(item, "doc")
          ]
        end)
      end)

    File.write!(
      "search_data.csv",
      NimbleCSV.RFC4180.dump_to_iodata([["package", "type", "ref", "title", "doc"] | rows])
    )
  end

  def process_sidebar do
    # File.rm!("sidebar.csv")

    Path.wildcard("sidebar/*.json")
    |> Enum.flat_map(fn path ->
      json = File.read!(path)
      json = String.trim_trailing(json, ";\nfillSidebarWithNodes(sidebarNodes);\n")
      json = String.replace(json, "class=\"inline\"", "class=\\\"inline\\\"")

      _sidebar =
        try do
          :json.decode(json)
        rescue
          _e ->
            fixed_json = fix_json(json)
            :json.decode(fixed_json)
        end

      # exceptions = Map.get(sidebar, "exceptions", [])
      # extras = Map.get(sidebar, "extras", [])
      # modules = Map.get(sidebar, "modules", [])
      # protocols = Map.get(sidebar, "protocols", [])
      # tasks = Map.get(sidebar, "tasks", [])
    end)

    # File.write!(
    #   "downloads.csv",
    #   NimbleCSV.RFC4180.dump_to_iodata([["package", "all", "recent", "week", "day"] | rows])
    # )
  end

  defp latest_version(package) do
    %{versions: versions, retired: retired} = package

    with {version, _index} <-
           versions
           |> Enum.with_index()
           |> Enum.reject(fn {_version, index} -> index in retired end)
           |> List.last(),
         do: version
  end

  @headers [{"x-typesense-api-key", "kex"}]

  def remove_collection do
    delete("collections/docs")
  end

  def collection_info do
    get("collections/docs")
  end

  def recreate_docs_collection do
    [
      delete: delete("collections/docs"),
      create_collection: create_collection(node2vec_join_schema()),
      import_collection: import_docs_collection()
    ]
  end

  def recreate_packages_collection do
    a = delete("collections/packages")
    b = create_collection(packages_schema())
    c = import_packages_collection()
    [a, b, c]
  end

  def create_collection(schema) do
    case post("collections", schema) do
      %Finch.Response{status: 201} -> :ok
      resp -> raise "failed to create collection: " <> inspect(resp)
    end
  end

  def basic_collection do
    delete("collections/hexdocs_v0")

    create_collection(%{
      "name" => "hexdocs_v0",
      "token_separators" => ["."],
      "fields" => [
        %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
        %{"name" => "type", "type" => "string", "facet" => true},
        %{"name" => "title", "type" => "string", "infix" => true},
        %{"name" => "doc", "type" => "string"},
        %{"name" => "package", "type" => "string", "facet" => true}
      ]
    })

    File.ls!("index")
    |> async_stream(
      fn file ->
        package = String.trim_trailing(file, ".json")
        debug("importing #{package}")

        items =
          read_docs_items(file)
          |> Enum.filter(fn item -> item["ref"] && item["title"] && item["doc"] end)
          |> Enum.map(fn item ->
            Map.take(item, ["ref", "title", "type", "doc"])
            |> Map.update!("type", fn type -> type || "extra" end)
            |> Map.update!("type", fn type -> type || "extra" end)
            |> Map.put("package", package)
          end)

        import_items("hexdocs_v0", items)
      end,
      ordered: false,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Stream.run()
  end

  # def just_functions_schema do
  #   %{
  #     "name" => "functions",
  #     "default_sorting_field" => "recent_downloads",
  #     "token_separators" => [".", "_"],
  #     "fields" => [
  #       %{"name" => "package", "type" => "string", "facet" => true},
  #       %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
  #       %{"name" => "title", "type" => "string", "infix" => true},
  #       %{"name" => "recent_downloads", "type" => "int32"}
  #     ]
  #   }
  # end

  def semantic_schema do
    %{
      "name" => "semantic",
      "token_separators" => ["."],
      "fields" => [
        %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
        %{"name" => "type", "type" => "string", "facet" => true},
        %{"name" => "title", "type" => "string", "index" => true},
        %{"name" => "doc", "type" => "string"},
        %{
          "name" => "embedding",
          "type" => "float[]",
          "embed" => %{
            "from" => [
              "doc"
            ],
            "model_config" => %{
              "model_name" => "openai/text-embedding-ada-002",
              "api_key" => System.fetch_env!("OPENAI_API_KEY")
            }
          }
        }
      ]
    }
  end

  def add_docs(package) do
    items =
      read_docs_items("index/#{package}.json")
      |> Enum.map(fn item ->
        item
        |> Map.take(["ref", "title", "type", "doc"])
        |> Map.update!("type", fn type -> type || "extra" end)
      end)

    import_items("semantic", items)
  end

  def semantic_search(text) do
    post("multi_search", %{
      "searches" => [
        %{"collection" => "semantic", "q" => text, "query_by" => "embedding", "prefix" => false}
      ]
    })
  end

  def node2vec_join_schema do
    %{
      "name" => "docs",
      "token_separators" => ["."],
      "fields" => [
        %{
          "name" => "package",
          "type" => "string",
          "facet" => true,
          "reference" => "packages.name"
        },
        %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
        %{"name" => "type", "type" => "string", "facet" => true},
        %{"name" => "title", "type" => "string", "infix" => true}
      ]
    }
  end

  def node2vec_schema(name) do
    %{
      "name" => name,
      "default_sorting_field" => "recent_downloads",
      "token_separators" => ["."],
      "fields" => [
        %{"name" => "package", "type" => "string", "facet" => true},
        %{"name" => "ref", "type" => "string", "index" => false, "optional" => true},
        %{"name" => "type", "type" => "string", "facet" => true},
        %{"name" => "title", "type" => "string", "infix" => true},
        %{"name" => "recent_downloads", "type" => "int32"},
        # Enum.each(vectors, fn %{"name" => name, "vec" => vec} -> File.write!("vectors/#{name}.json", Jason.encode_to_iodata!(%{"vec" => vec})) end)
        %{"name" => "package_vec", "type" => "float[]", "num_dim" => 64, "optional" => true}
      ]
    }
  end

  def packages_schema do
    %{
      "name" => "packages",
      "symbols_to_index" => ["_"],
      "default_sorting_field" => "recent_downloads",
      "fields" => [
        %{"name" => "name", "type" => "string", "facet" => true},
        %{"name" => "recent_downloads", "type" => "int32"},
        %{"name" => "vec", "type" => "float[]", "num_dim" => 64, "optional" => true}
      ]
    }
  end

  ## for devdocs-like search
  # def import_just_functions_collection do
  #   File.ls!("index")
  #   |> async_stream(
  #     fn file ->
  #       package = String.trim_trailing(file, ".json")
  #       Logger.debug("importing #{package}")
  #       items = read_docs_items(file)
  #       stats = Jason.decode!(File.read!("stats/" <> file))
  #       recent_downloads = get_in(stats, ["downloads", "recent"]) || 0

  #       items =
  #         items
  #         |> Enum.filter(fn %{"type" => type, "ref" => ref, "title" => title} ->
  #           if type == "function" do
  #             segments = String.split(title, ".")
  #             {function, module} = List.pop_at(segments, -1)
  #             ref == Enum.join(module, ".") <> ".html#" <> function
  #           end
  #         end)
  #         |> Enum.map(fn item ->
  #           item |> Map.put("package", package) |> Map.put("recent_downloads", recent_downloads)
  #         end)

  #       import_items(_collection = "functions", items)
  #     end,
  #     ordered: false,
  #     max_concurrency: 100
  #   )
  #   |> Stream.run()
  # end

  # https://github.com/typesense/typesense/issues/1149
  # File.ls!("stats") |> Enum.map(fn file -> package = String.trim_trailing(file, ".json"); {package, String.replace(package, "_", "")} end) |> Enum.group_by(fn {_, p} -> p end, fn {p, _} -> p end) |> Enum.filter(fn {_, p} -> length(p) > 1 end) |> Enum.flat_map(fn {_, p} -> p end) |> Enum.uniq

  def import_docs_collection do
    File.ls!("index")
    |> async_stream(
      fn file ->
        package = String.trim_trailing(file, ".json")
        debug("importing #{package}")

        items =
          read_docs_items(file)
          |> Enum.map(fn item ->
            Map.take(item, ["ref", "title", "type"])
            |> Map.update!("type", fn type -> type || "extra" end)
            |> Map.put("package", package)
          end)

        import_items("docs", items)
      end,
      ordered: false,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Stream.run()
  end

  def import_functions_and_modules_collection do
    File.ls!("index")
    |> async_stream(
      fn file ->
        package = String.trim_trailing(file, ".json")
        debug("importing #{package}")
        items = read_docs_items(file)
        stats = Jason.decode!(File.read!("stats/" <> file))
        recent_downloads = get_in(stats, ["downloads", "recent"]) || 0

        package_vec =
          case File.read("vectors/" <> file) do
            {:ok, json} -> json |> Jason.decode!() |> Map.fetch!("vec")
            {:error, :enoent} -> nil
          end

        items =
          items
          # |> Enum.filter(fn %{"type" => type} ->
          #   cond do
          #     type in ["function", "module", "type"] ->
          #       true

          #     true ->
          #       IO.inspect(type)
          #       false
          #   end
          # end)
          |> Enum.map(fn item ->
            # TODO use separate collection + join
            Map.take(item, ["ref", "title", "type"])
            |> Map.update!("type", fn type -> type || "extra" end)
            |> Map.put("package", package)
            |> Map.put("package_vec", package_vec)
            |> Map.put("recent_downloads", recent_downloads)
          end)

        import_items(_collection = "eh", items)
      end,
      ordered: false,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Stream.run()
  end

  def import_packages_collection do
    File.ls!("stats")
    |> async_stream(
      fn file ->
        name = String.trim_trailing(file, ".json")
        debug("importing #{name}")
        stats = Jason.decode!(File.read!("stats/" <> file))
        recent_downloads = get_in(stats, ["downloads", "recent"]) || 0

        vec =
          case File.read("vectors/" <> file) do
            {:ok, json} -> json |> Jason.decode!() |> Map.fetch!("vec")
            {:error, :enoent} -> nil
          end

        import_items("packages", [
          %{"name" => name, "recent_downloads" => recent_downloads, "vec" => vec}
        ])
      end,
      ordered: false,
      timeout: :timer.seconds(15),
      max_concurrency: 10
    )
    |> Stream.run()
  end

  def everything_schema do
    %{
      "name" => "docs",
      "default_sorting_field" => "recent_downloads",
      "fields" => [
        %{"name" => "doc", "type" => "string"},
        %{"name" => "ref", "type" => "string", "index" => false},
        %{"name" => "title", "type" => "string"},
        %{"name" => "module", "type" => "string", "optional" => true},
        %{"name" => "function", "type" => "string", "optional" => true},
        %{"name" => "package", "type" => "string"},
        %{"name" => "type", "type" => "string", "facet" => true},
        %{"name" => "recent_downloads", "type" => "int32"}
      ]
    }
  end

  # def import_collection(name) do
  #   File.ls!("index")
  #   |> Enum.map(fn name -> "index/#{name}" end)
  #   |> async_stream(&__MODULE__.import_doc/1, ordered: false, max_concurrency: 100)
  #   |> Stream.run()
  # end

  # def import_doc(file) do
  #   Logger.debug("importing #{file}")
  #   ["index", package] = String.split(file, "/")
  #   package = String.trim_trailing(package, ".json")
  #   import_items(package, read_docs_items(file))
  # end

  def read_docs_items("index/" <> _ = file) do
    json = File.read!(file)

    docs =
      case Jason.decode(json) do
        {:ok, docs} ->
          docs

        {:error, %Jason.DecodeError{}} ->
          fixed_json = fix_json(json)

          case Jason.decode(fixed_json) do
            {:ok, docs} ->
              docs

            {:error, %Jason.DecodeError{position: position} = error} ->
              error(inspect(file: file, section: binary_slice(fixed_json, position - 10, 20)))
              raise error
          end
      end

    case docs do
      %{"items" => items} -> items
      items when is_list(items) -> items
    end
  end

  def read_docs_items(file), do: read_docs_items("index/" <> file)

  # def ensure_all_json do
  #   File.ls!("index")
  #   |> Enum.each(fn name ->
  #     json = File.read!("index/#{name}")

  #     case Jason.decode(json) do
  #       {:ok, _} ->
  #         :ok

  #       {:error, %Jason.DecodeError{}} ->
  #         fixed_json = fix_json(json)

  #         case Jason.decode(fixed_json) do
  #           {:ok, _} ->
  #             :ok

  #           {:error, %Jason.DecodeError{position: position} = error} ->
  #             Logger.error(file: name, section: binary_slice(fixed_json, position - 10, 20))
  #             raise error
  #         end
  #     end
  #   end)
  # end

  # https://github.com/elixir-lang/ex_doc/commit/60dfb4537549e551750bc9cd84610fb475f66acd
  defp fix_json(json) do
    json
    # |> String.replace("\\#\{", "\#{")
    |> to_json_string(<<>>)
  end

  # [file: "monad_cps.json", section: "gt;&gt;= \\a -&gt; Mo"]
  defp to_json_string(<<" \\a", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "a">>)

  # [file: "figlet.json", section: "en: flf2a\\d 4 3 8 15"]
  defp to_json_string(<<"\\d", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "d">>)

  # [file: "phoenix.json", section: "lo_dev=# \\d List of "]
  defp to_json_string(<<"\\\\d", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "d">>)

  # [file: "puid.json", section: "VWXYZ[]^_\\abcdefghij"]
  defp to_json_string(<<"_\\a", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "_a">>)

  # [file: "fluminus.json", section: "of nusstu\\e0123456)."]

  defp to_json_string(<<"u\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "ue">>)

  # [file: "boxen.json", section: "t; &quot;\\e[31m&quot"]
  defp to_json_string(<<";\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, ";e">>)

  # [file: "boxen.json", section: "4mhello, \\e[36melixi"]
  defp to_json_string(<<", \\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, ", e">>)

  # [file: "boxen.json", section: "36melixir\\e[0m&quot;"]
  defp to_json_string(<<"r\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "re">>)

  # [file: "chi2fit.json", section: "2fit.Fit \\e [ 0 m \\e"]
  defp to_json_string(<<" \\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, " e">>)

  # [file: "chi2fit.json", section: "ic Errors\\e[0m e [ 0"]
  defp to_json_string(<<"s\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "se">>)

  #  [file: "chi2fit.json", section: "formation\\e[0m e [ 0"]
  defp to_json_string(<<"n\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "ne">>)

  # [file: "owl.json", section: "36m┌─\\e[31mRed!\\"]
  defp to_json_string(<<"┌─\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "┌─e">>)

  # [file: "ex_unit_release.json", section: "ot;e[32m.\\e[0m Finis"]
  defp to_json_string(<<".\\e", rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, ".e">>)

  # [file: "cassandrax.json", section: "\"},{\"doc\":<<65, 32, "]
  defp to_json_string(<<"\"doc\":<<", rest::bytes>>, acc),
    do: to_json_string(rest, <<acc::bytes, "\"doc\":\"<<">>)

  # [file: "cassandrax.json", section: "2, ...>>,\"ref\":\"Cass"]
  defp to_json_string(<<">>,\"", rest::bytes>>, acc),
    do: to_json_string(rest, <<acc::bytes, ">>\",\"">>)

  # [file: "ecto.json", section: "ength, \\\"\\\#{Keyword."]
  defp to_json_string(<<"\\\#{", rest::bytes>>, acc),
    do: to_json_string(rest, <<acc::bytes, "\#{">>)

  defp to_json_string(<<?\b, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\b">>)

  defp to_json_string(<<?\t, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\t">>)

  defp to_json_string(<<?\n, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\n">>)

  defp to_json_string(<<?\f, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\f">>)

  defp to_json_string(<<?\r, rest::binary>>, acc),
    do: to_json_string(rest, <<acc::binary, "\\r">>)

  defp to_json_string(<<x, rest::binary>>, acc) when x <= 0x000F,
    do: to_json_string(rest, <<acc::binary, "\\u000#{Integer.to_string(x, 16)}">>)

  defp to_json_string(<<x, rest::binary>>, acc) when x <= 0x001F,
    do: to_json_string(rest, <<acc::binary, "\\u00#{Integer.to_string(x, 16)}">>)

  defp to_json_string(<<x, rest::binary>>, acc), do: to_json_string(rest, <<acc::binary, x>>)
  defp to_json_string(<<>>, acc), do: acc

  defp import_items(_collection, []), do: :ok

  defp import_items(collection, items) do
    payload =
      items
      |> Enum.map(&Jason.encode_to_iodata!/1)
      |> Enum.intersperse("\n")

    req =
      Finch.build(
        :post,
        "http://localhost:8108/collections/#{collection}/documents/import",
        @headers,
        payload
      )

    %Finch.Response{status: 200, body: body} = Finch.request!(req, Doku.Finch)

    body
    |> String.split("\n")
    |> Enum.map(&Jason.decode!/1)
    |> Enum.zip(items)
    |> Enum.reject(fn {%{"success" => success}, _item} -> success end)
    |> case do
      [] -> :ok
      failed -> raise "failed to import docs: #{inspect(failed)}"
    end
  end

  def search(collection, query) do
    get("/collections/#{collection}/documents/search?" <> URI.encode_query(query))
  end

  def get(path), do: req(:get, path)
  def delete(path), do: req(:delete, path)
  def post(path, body), do: req(:post, path, Jason.encode_to_iodata!(body))

  defp req(verb, path, body \\ nil) do
    Finch.build(verb, Path.join("http://localhost:8108", path), @headers, body)
    |> Finch.request!(Doku.Finch)
    |> Map.update!(:body, &Jason.decode!/1)
  end

  def join_query(in_package \\ "ecto", text) do
    %{"vec" => vec} = Jason.decode!(File.read!("vectors/#{in_package}.json"))

    post("multi_search", %{
      "searches" => [
        %{
          "query_by" => "title",
          "q" => text,
          "vector_query" => "$packages(vec:(#{Jason.encode!(vec)}, k:64))",
          "filter_by" => "$packages(name:=package)",
          "sort_by" =>
            "_text_match(buckets: 3):desc,_vector_distance:asc,$packages(recent_downloads:desc)",
          "infix" => "always",
          "collection" => "docs"
        }
      ]
    })
  end

  def package_similarity(a, b) do
    %{"vec" => vec_a} = Jason.decode!(File.read!("vectors/#{a}.json"))
    %{"vec" => vec_b} = Jason.decode!(File.read!("vectors/#{b}.json"))
    cosine_similarity(vec_a, vec_b)
  end

  def cosine_similarity(a, b), do: cosine_similarity(a, b, 0, 0, 0)

  def cosine_similarity([x1 | rest1], [x2 | rest2], s1, s2, s12) do
    cosine_similarity(rest1, rest2, x1 * x1 + s1, x2 * x2 + s2, x1 * x2 + s12)
  end

  def cosine_similarity([], [], s1, s2, s12) do
    s12 / (:math.sqrt(s1) * :math.sqrt(s2))
  end

  defp error(msg), do: colored_io_puts(IO.ANSI.red(), msg)
  defp warning(msg), do: colored_io_puts(IO.ANSI.yellow(), msg)
  defp info(msg), do: IO.puts(msg)
  defp debug(msg), do: colored_io_puts(IO.ANSI.cyan(), msg)

  defp colored_io_puts(color, msg) do
    IO.puts(color <> msg <> IO.ANSI.reset())
  end
end
