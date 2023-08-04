defmodule Doku do
  @moduledoc """
  Documentation for `Doku`.
  """

  require Logger

  def scrape do
    File.mkdir("index")

    packages()
    |> async_stream(&__MODULE__.maybe_download_index/1, ordered: false, max_concurrency: 100)
    |> Stream.run()
  end

  def scrape_stats do
    File.mkdir("stats")

    config = :hex_core.default_config()

    packages(config)
    |> async_stream(fn package -> maybe_download_stats(config, package) end,
      ordered: false,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Stream.run()
  end

  def scrape_tarballs do
    File.mkdir("tarballs")

    config = :hex_core.default_config()

    versions(config)
    |> async_stream(fn package -> maybe_download_tarball(config, package) end,
      ordered: false,
      max_concurrency: 100
    )
    |> Stream.run()
  end

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
      Logger.warning("#{name} already downloaded")
    else
      Logger.debug("starting #{name}...")

      case Finch.request!(Finch.build(:get, "https://hexdocs.pm/#{name}/search.html"), Doku.Finch) do
        %Finch.Response{status: 200, body: body} ->
          html = Floki.parse_document!(body)
          scripts = Floki.find(html, "script")

          if index_url =
               find_script(scripts, "dist/search_data") ||
                 find_script(scripts, "dist/search_items") do
            %Finch.Response{status: 200, body: body} =
              Finch.request!(
                Finch.build(:get, "https://hexdocs.pm/#{name}/" <> index_url),
                Doku.Finch
              )

            json =
              case body do
                "searchNodes=" <> json -> json
                "searchData=" <> json -> json
              end

            File.write!("index/" <> name <> ".json", json)
            Logger.info("downloaded #{name}")
          end

        %Finch.Response{status: 404} ->
          Logger.error("no search page for #{name}")
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
      Logger.warning("#{name} already downloaded")
    else
      Logger.debug("starting #{name}...")

      case :hex_api.get(config, ["packages", name]) do
        {:ok, {200, _headers, stats}} ->
          json = Jason.encode_to_iodata!(stats)
          File.write!("stats/" <> name <> ".json", json)
          Logger.info("downloaded #{name}")

        {:ok, {429, headers, _body}} ->
          reset_at = Map.fetch!(headers, "x-ratelimit-reset")
          sleep_for = String.to_integer(reset_at) - :os.system_time(:second)

          if sleep_for > 0 do
            Logger.debug("sleeping for #{sleep_for} seconds")
            :timer.sleep(:timer.seconds(sleep_for))
          end

          maybe_download_stats(config, package)
      end
    end
  end

  def maybe_download_release(config, package) do
    %{name: name} = package

    if File.exists?("releases/" <> name <> ".json") do
      Logger.warning("#{name} already exists")
    else
      Logger.debug("starting #{name}...")

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
            Logger.info("downloaded #{name}")
          else
            Logger.warning("#{inspect(package)} doesn't have a valid release")
          end

        {:ok, {429, headers, _body}} ->
          reset_at = Map.fetch!(headers, "x-ratelimit-reset")
          sleep_for = String.to_integer(reset_at) - :os.system_time(:second)

          if sleep_for > 0 do
            Logger.debug("sleeping for #{sleep_for} seconds")
            :timer.sleep(:timer.seconds(sleep_for))
          end

          maybe_download_release(config, package)
      end
    end
  end

  def maybe_download_tarball(config, package) do
    %{name: name} = package

    if File.exists?("tarballs/" <> name <> ".tar.gz") do
      Logger.warning("#{name} already downloaded")
    else
      Logger.debug("starting #{name}...")

      if version = latest_version(package) do
        {:ok, {200, _headers, tarball}} =
          :hex_repo.get_tarball(config, name, version)

        File.write!("tarballs/" <> name <> ".tar.gz", tarball)
        Logger.info("downloaded #{name}")
      else
        Logger.warning("#{inspect(package)} doesn't have a valid version")
      end
    end
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
    Finch.request!(
      Finch.build(:delete, "http://localhost:8108/collections/docs", @headers),
      Doku.Finch
    )
  end

  def collection_info do
    Finch.request!(
      Finch.build(:get, "http://localhost:8108/collections/docs", @headers),
      Doku.Finch
    )
  end

  def import_collection do
    body =
      Jason.encode_to_iodata!(%{
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
      })

    req = Finch.build(:post, "http://localhost:8108/collections", @headers, body)

    case Finch.request!(req, Doku.Finch) do
      %Finch.Response{status: status} when status in [201, 409] -> :ok
      resp -> raise "failed to create `docs` collection: " <> inspect(resp)
    end

    File.ls!("index")
    |> Enum.map(fn name -> "index/#{name}" end)
    |> async_stream(&__MODULE__.import_doc/1, ordered: false, max_concurrency: 100)
    |> Stream.run()
  end

  def import_doc(file) do
    Logger.debug("importing #{file}")
    ["index", package] = String.split(file, "/")
    package = String.trim_trailing(package, ".json")
    json = ensure_json(File.read!(file), "")

    try do
      case Jason.decode!(json) do
        items when is_list(items) -> import_items(package, items)
        %{"items" => items} -> import_items(package, items)
      end
    rescue
      e ->
        Logger.error("failed to import #{file}: " <> Exception.message(e))
    end
  end

  defp ensure_json(<<"\\#", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "#">>)
  defp ensure_json(<<"\\\\#", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "#">>)

  defp ensure_json(<<"\\a", rest::binary>>, acc),
    do: ensure_json(rest, <<acc::binary, "\\u0007">>)

  # defp ensure_json(<<"\\\\d", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "\d">>)
  defp ensure_json(<<"\\\\d", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "\d">>)
  # defp ensure_json(<<"\\s", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "\s">>)
  # defp ensure_json(<<"\\\\", rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, "\\">>)
  defp ensure_json(<<x, rest::binary>>, acc), do: ensure_json(rest, <<acc::binary, x>>)
  defp ensure_json(<<>>, acc), do: acc

  defp import_items(_package, []), do: :ok

  defp import_items(package, items) do
    payload =
      items
      |> Enum.map(fn item ->
        item = Map.put(item, "package", package)

        item =
          case item do
            %{"type" => "function", "title" => title} ->
              segments = String.split(title, ".")
              function = List.last(segments)
              Map.put(item, "function", function)

            _ ->
              item
          end

        Jason.encode_to_iodata!(item)
      end)
      |> Enum.intersperse("\n")

    req =
      Finch.build(
        :post,
        "http://localhost:8108/collections/docs/documents/import",
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
      failed -> {:error, failed}
    end
  end

  def search(query) do
    url = "http://localhost:8108/collections/docs/documents/search?" <> URI.encode_query(query)

    Finch.build(:get, url, @headers)
    |> Finch.request!(Doku.Finch)
    |> Map.update!(:body, &Jason.decode!/1)
  end
end
