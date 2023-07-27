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

  def packages do
    {:ok, {200, _headers, %{packages: packages}}} =
      :hex_repo.get_names(:hex_core.default_config())

    packages
  end

  @headers [{"x-typesense-api-key", "kex"}]

  def import_collection do
    body =
      Jason.encode_to_iodata!(%{
        "name" => "docs",
        "fields" => [
          %{"name" => "doc", "type" => "string"},
          %{"name" => "ref", "type" => "string"},
          %{"name" => "title", "type" => "string"},
          # %{"name" => "type", "type" => "string", "facet" => true}
          %{"name" => "type", "type" => "string"}
        ]
      })

    req = Finch.build(:post, "http://localhost:8108/collections", @headers, body)

    case Finch.request!(req, Doku.Finch) do
      %Finch.Response{status: status} when status in [201, 409] -> :ok
      resp -> raise "failed to create `docs` collection: " <> inspect(resp)
    end

    File.ls!("index")
    |> Enum.map(fn name -> "index/#{name}" end)
    |> async_stream(&__MODULE__.import_doc/1, ordered: false, max_concurrency: 1)
    |> Stream.run()
  end

  def import_doc(file) do
    Logger.debug("importing #{file}")
    json = file |> File.read!() |> String.replace(["\\\\#", "\\\#"], "#")

    case Jason.decode!(json) do
      items when is_list(items) -> import_items(items)
      %{"items" => items} -> import_items(items)
    end
  end

  defp import_items([]), do: :ok

  defp import_items(items) do
    payload =
      items
      |> Enum.map(&Jason.encode_to_iodata!/1)
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
