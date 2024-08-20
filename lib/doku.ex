defmodule Doku do
  @moduledoc """
  Documentation for `Doku`.
  """

  defmodule HTTP do
    @moduledoc false
    @behaviour :hex_http

    @impl true
    def request(method, uri, headers, body, adapter_config) do
      body = with :undefined <- body, do: []
      req = Finch.build(method, uri, Map.to_list(headers), body)

      case Finch.request(req, Doku.Finch, receive_timeout: :timer.seconds(60)) do
        {:ok, %Finch.Response{status: status, headers: headers, body: body}} ->
          {:ok, {status, Map.new(headers), body}}

        {:error, reason} ->
          IO.puts(IO.ANSI.red() <> inspect(uri: uri, reason: reason) <> IO.ANSI.reset())
          request(method, uri, headers, body, adapter_config)
      end
    end
  end

  def hex_config do
    config = :hex_core.default_config()
    %{config | http_adapter: {Doku.HTTP, %{}}}
  end

  def scrape_tarballs do
    File.mkdir("tarballs")

    config = hex_config()
    # TODO
    stdlib = [
      %{name: "elixir", versions: ["1.17.2"], retired: []},
      %{name: "eex", versions: ["1.17.2"], retired: []},
      %{name: "ex_unit", versions: ["1.17.2"], retired: []},
      %{name: "iex", versions: ["1.17.2"], retired: []},
      %{name: "logger", versions: ["1.17.2"], retired: []},
      %{name: "mix", versions: ["1.17.2"], retired: []}
    ]

    packages = stdlib ++ versions(config)

    Enum.shuffle(packages)
    |> async_stream(fn package -> maybe_download_tarball(config, package) end,
      timeout: :infinity,
      ordered: false,
      max_concurrency: 100
    )
    |> Stream.run()
  end

  def extract_docs do
    Path.wildcard("tarballs/*.tar.gz")
    |> async_stream(
      fn tarball ->
        debug("extracting #{tarball}...")
        {:ok, files} = :erl_tar.extract(String.to_charlist(tarball), [:memory, :compressed])
        package = tarball |> Path.basename() |> Path.rootname(".tar.gz")

        json =
          Enum.find_value(files, fn {name, content} ->
            case name do
              ~c"dist/search_data-" ++ _ ->
                "searchData=" <> json = content
                json

              ~c"dist/search_items-" ++ _ ->
                "searchNodes=" <> json = content
                json

              _other ->
                nil
            end
          end)

        docs =
          if json do
            try do
              :json.decode(json)
            rescue
              _e ->
                fixed_json = fix_json(json)
                :json.decode(fixed_json)
            end
          else
            []
          end

        items =
          case docs do
            %{"items" => items} -> items
            items when is_list(items) -> items
          end

        Enum.map(items, fn item ->
          json =
            Map.take(item, ["type", "ref", "title", "doc"])
            |> Map.put("package", package)
            |> :json.encode()

          [json, ?\n]
        end)
      end,
      ordered: false
    )
    |> Stream.map(fn {:ok, jsonl} -> jsonl end)
    |> Stream.into(File.stream!("docs.jsonl.tmp", [:write, :raw]))
    |> Stream.run()

    if File.exists?("docs.jsonl") do
      File.rm!("docs.jsonl")
    end

    File.rename!("docs.jsonl.tmp", "docs.jsonl")
  end

  # don't need
  # def scrape_releasess do
  #   File.mkdir("releases")

  #   config = :hex_core.default_config()
  #   config = %{config | http_adapter: {Doku.HTTP, []}}

  #   packages(config)
  #   |> async_stream(fn package -> maybe_download_release(config, package) end,
  #     ordered: false,
  #     max_concurrency: 100
  #   )
  #   |> Stream.run()
  # end

  def async_stream(enumerable, fun, opts \\ []) do
    Task.Supervisor.async_stream(Doku.TaskSupervisor, enumerable, fun, opts)
  end

  def packages(config \\ hex_config()) do
    {:ok, {200, _headers, %{packages: packages}}} = :hex_repo.get_names(config)
    packages
  end

  def versions(config \\ hex_config()) do
    {:ok, {200, _headers, %{packages: packages}}} = :hex_repo.get_versions(config)
    packages
  end

  # def maybe_download_release(config, package) do
  #   %{name: name} = package

  #   if File.exists?("releases/" <> name <> ".json") do
  #     warning("#{name} already exists")
  #   else
  #     debug("starting #{name}...")

  #     case :hex_repo.get_package(config, name) do
  #       {:ok, {200, _headers, package}} ->
  #         %{releases: releases} = package
  #         releases = Enum.reject(releases, & &1[:retired])
  #         latest_release = List.last(releases)

  #         if latest_release do
  #           json =
  #             latest_release
  #             |> Map.take([:version, :dependencies])
  #             |> Jason.encode_to_iodata!()

  #           File.write!("releases/" <> name <> ".json", json)
  #           info("downloaded #{name}")
  #         else
  #           warning("#{inspect(package)} doesn't have a valid release")
  #         end

  #       {:ok, {429, headers, _body}} ->
  #         reset_at = Map.fetch!(headers, "x-ratelimit-reset")
  #         sleep_for = String.to_integer(reset_at) - :os.system_time(:second)

  #         if sleep_for > 0 do
  #           debug("sleeping for #{sleep_for} seconds")
  #           :timer.sleep(:timer.seconds(sleep_for))
  #         end

  #         maybe_download_release(config, package)
  #     end
  #   end
  # end

  def maybe_download_tarball(config \\ hex_config(), package) do
    %{name: name} = package

    if File.exists?("tarballs/" <> name <> ".tar.gz") do
      warning("#{name} already downloaded")
    else
      debug("starting #{name}...")

      if version = latest_version(package) do
        case :hex_repo.get_docs(config, name, version) do
          {:ok, {200, _headers, tarball}} ->
            File.write!("tarballs/" <> name <> ".tar.gz", tarball)
            info("downloaded #{name}")

          {:ok, {404, _headers, _body}} ->
            warning("#{inspect(package)} not found (404) for docs #{name}.tar.gz")
        end
      else
        warning("#{inspect(package)} doesn't have a valid version")
      end
    end
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

  defp latest_version(package) do
    %{versions: versions, retired: retired} = package

    with {version, _index} <-
           versions
           |> Enum.with_index()
           |> Enum.reject(fn {_version, index} -> index in retired end)
           |> List.last(),
         do: version
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

  # def import_functions_and_modules_collection do
  #   File.ls!("index")
  #   |> async_stream(
  #     fn file ->
  #       package = String.trim_trailing(file, ".json")
  #       debug("importing #{package}")
  #       items = read_docs_items(file)
  #       stats = Jason.decode!(File.read!("stats/" <> file))
  #       recent_downloads = get_in(stats, ["downloads", "recent"]) || 0

  #       package_vec =
  #         case File.read("vectors/" <> file) do
  #           {:ok, json} -> json |> Jason.decode!() |> Map.fetch!("vec")
  #           {:error, :enoent} -> nil
  #         end

  #       items =
  #         items
  #         # |> Enum.filter(fn %{"type" => type} ->
  #         #   cond do
  #         #     type in ["function", "module", "type"] ->
  #         #       true

  #         #     true ->
  #         #       IO.inspect(type)
  #         #       false
  #         #   end
  #         # end)
  #         |> Enum.map(fn item ->
  #           # TODO use separate collection + join
  #           Map.take(item, ["ref", "title", "type"])
  #           |> Map.update!("type", fn type -> type || "extra" end)
  #           |> Map.put("package", package)
  #           |> Map.put("package_vec", package_vec)
  #           |> Map.put("recent_downloads", recent_downloads)
  #         end)

  #       import_items(_collection = "eh", items)
  #     end,
  #     ordered: false,
  #     max_concurrency: 3,
  #     timeout: :infinity
  #   )
  #   |> Stream.run()
  # end

  # def everything_schema do
  #   %{
  #     "name" => "docs",
  #     "default_sorting_field" => "recent_downloads",
  #     "fields" => [
  #       %{"name" => "doc", "type" => "string"},
  #       %{"name" => "ref", "type" => "string", "index" => false},
  #       %{"name" => "title", "type" => "string"},
  #       %{"name" => "module", "type" => "string", "optional" => true},
  #       %{"name" => "function", "type" => "string", "optional" => true},
  #       %{"name" => "package", "type" => "string"},
  #       %{"name" => "type", "type" => "string", "facet" => true},
  #       %{"name" => "recent_downloads", "type" => "int32"}
  #     ]
  #   }
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

  defp error(msg), do: colored_io_puts(IO.ANSI.red(), msg)
  defp warning(msg), do: colored_io_puts(IO.ANSI.yellow(), msg)
  defp info(msg), do: IO.puts(msg)
  defp debug(msg), do: colored_io_puts(IO.ANSI.cyan(), msg)

  defp colored_io_puts(color, msg) do
    IO.puts(color <> msg <> IO.ANSI.reset())
  end
end
