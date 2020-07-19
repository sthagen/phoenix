defmodule Phoenix.Digester do
  @digested_file_regex ~r/(-[a-fA-F\d]{32})/
  @manifest_version 1
  @empty_manifest %{
    "version" => @manifest_version,
    "digests" => %{},
    "latest" => %{}
  }

  defp now() do
    :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
  end

  @moduledoc false

  @doc """
  Digests and compresses the static files in the given `input_path`
  and saves them in the given `output_path`.
  """
  @spec compile(String.t(), String.t()) :: :ok | {:error, :invalid_path}
  def compile(input_path, output_path) do
    if File.exists?(input_path) do
      File.mkdir_p!(output_path)

      files = filter_files(input_path)
      latest = generate_latest(files)
      digests = load_compile_digests(output_path)
      digested_files = Enum.map(files, &digested_contents(&1, latest))

      save_manifest(digested_files, latest, digests, output_path)
      Enum.each(digested_files, &write_to_disk(&1, output_path))
    else
      {:error, :invalid_path}
    end
  end

  defp filter_files(input_path) do
    input_path
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&(not (File.dir?(&1) or compiled_file?(&1))))
    |> Enum.map(&map_file(&1, input_path))
  end

  defp generate_latest(files) do
    Map.new(
      files,
      &{
        manifest_join(&1.relative_path, &1.filename),
        manifest_join(&1.relative_path, &1.digested_filename)
      }
    )
  end

  defp load_compile_digests(output_path) do
    manifest = load_manifest(output_path)
    manifest["digests"]
  end

  defp load_manifest(output_path) do
    manifest_path = Path.join(output_path, "cache_manifest.json")

    if File.exists?(manifest_path) do
      manifest_path
      |> File.read!()
      |> Phoenix.json_library().decode!()
      |> migrate_manifest(output_path)
    else
      @empty_manifest
    end
  end

  defp migrate_manifest(%{"version" => @manifest_version} = manifest, _output_path), do: manifest
  defp migrate_manifest(_latest, _output_path), do: @empty_manifest

  defp save_manifest(files, latest, old_digests, output_path) do
    old_digests_that_still_exist =
      old_digests
      |> Enum.filter(fn {file, _} -> File.exists?(Path.join(output_path, file)) end)
      |> Map.new()

    digests = Map.merge(old_digests_that_still_exist, generate_digests(files))
    write_manifest(latest, digests, output_path)
  end

  defp write_manifest(latest, digests, output_path) do
    json = %{
      "latest" => latest,
      "version" => @manifest_version,
      "digests" => digests
    }

    manifest_content = Phoenix.json_library().encode!(json)
    File.write!(Path.join(output_path, "cache_manifest.json"), manifest_content)
  end

  defp generate_digests(files) do
    Map.new(
      files,
      &{
        manifest_join(&1.relative_path, &1.digested_filename),
        build_digest(&1)
      }
    )
  end

  defp build_digest(file) do
    %{
      logical_path: manifest_join(file.relative_path, file.filename),
      mtime: now(),
      size: file.size,
      digest: file.digest,
      sha512: Base.encode64(:crypto.hash(:sha512, file.digested_content))
    }
  end

  defp manifest_join(".", filename), do: filename
  defp manifest_join(path, filename), do: Path.join(path, filename)

  defp compiled_file?(file_path) do
    compressors = Application.fetch_env!(:phoenix, :static_compressors)
    compressed_extensions = Enum.flat_map(compressors, &(&1.file_extensions))

    Regex.match?(@digested_file_regex, Path.basename(file_path)) ||
      Path.extname(file_path) in compressed_extensions ||
      Path.basename(file_path) == "cache_manifest.json"
  end

  defp map_file(file_path, input_path) do
    stats = File.stat!(file_path)
    content = File.read!(file_path)

    basename = Path.basename(file_path)
    rootname = Path.rootname(basename)
    extension = Path.extname(basename)
    digest = Base.encode16(:erlang.md5(content), case: :lower)

    %{
      absolute_path: file_path,
      relative_path: file_path |> Path.relative_to(input_path) |> Path.dirname(),
      filename: basename,
      size: stats.size,
      content: content,
      digest: digest,
      digested_content: nil,
      digested_filename: "#{rootname}-#{digest}#{extension}"
    }
  end

  defp write_to_disk(file, output_path) do
    path = Path.join(output_path, file.relative_path)
    File.mkdir_p!(path)

    compressors = Application.fetch_env!(:phoenix, :static_compressors)

    Enum.each(compressors, fn(compressor) ->
      [file_extension | _] = compressor.file_extensions

      with {:ok, compressed_digested} <- compressor.compress_file(file.digested_filename, file.digested_content) do
        File.write!(
          Path.join(path, file.digested_filename <> file_extension),
          compressed_digested
        )
      end

      with {:ok, compressed} <- compressor.compress_file(file.filename, file.content) do
        File.write!(
          Path.join(path, file.filename <> file_extension),
          compressed
        )
      end
    end)

    # uncompressed files
    File.write!(Path.join(path, file.digested_filename), file.digested_content)
    File.write!(Path.join(path, file.filename), file.content)

    file
  end

  defp digested_contents(file, latest) do
    ext = Path.extname(file.filename)

    digested_content =
      case ext do
        ".css" -> digest_stylesheet_asset_references(file, latest)
        ".js" -> digest_javascript_asset_references(file, latest)
        ".map" -> digest_javascript_map_asset_references(file, latest)
        _ -> file.content
      end

    %{file | digested_content: digested_content}
  end

  @stylesheet_url_regex ~r{(url\(\s*)(\S+?)(\s*\))}
  @quoted_text_regex ~r{\A(['"])(.+)\1\z}

  defp digest_stylesheet_asset_references(file, latest) do
    Regex.replace(@stylesheet_url_regex, file.content, fn _, open, url, close ->
      case Regex.run(@quoted_text_regex, url) do
        [_, quote_symbol, url] ->
          open <> quote_symbol <> digested_url(url, file, latest, true) <> quote_symbol <> close

        nil ->
          open <> digested_url(url, file, latest, true) <> close
      end
    end)
  end

  @javascript_source_map_regex ~r{(//#\s*sourceMappingURL=\s*)(\S+)}

  defp digest_javascript_asset_references(file, latest) do
    Regex.replace(@javascript_source_map_regex, file.content, fn _, source_map_text, url ->
      source_map_text <> digested_url(url, file, latest, false)
    end)
  end

  @javascript_map_file_regex ~r{(['"]file['"]:['"])([^,"']+)(['"])}

  defp digest_javascript_map_asset_references(file, latest) do
    Regex.replace(@javascript_map_file_regex, file.content, fn _, open_text, url, close_text ->
      open_text <> digested_url(url, file, latest, false) <> close_text
    end)
  end

  defp digested_url("/" <> relative_path, _file, latest, with_vsn?) do
    case Map.fetch(latest, relative_path) do
      {:ok, digested_path} -> relative_digested_path(digested_path, with_vsn?)
      :error -> "/" <> relative_path
    end
  end

  defp digested_url(url, file, latest, with_vsn?) do
    case URI.parse(url) do
      %URI{scheme: nil, host: nil} ->
        manifest_path =
          file.relative_path
          |> Path.join(url)
          |> Path.expand()
          |> Path.relative_to_cwd()

        case Map.fetch(latest, manifest_path) do
          {:ok, digested_path} ->
            absolute_digested_url(url, digested_path, with_vsn?)

          :error ->
            url
        end

      _ ->
        url
    end
  end

  defp relative_digested_path(digested_path, true),
    do: relative_digested_path(digested_path) <> "?vsn=d"

  defp relative_digested_path(digested_path, false),
    do: relative_digested_path(digested_path)

  defp relative_digested_path(digested_path),
    do: "/" <> digested_path

  defp absolute_digested_url(url, digested_path, true),
    do: absolute_digested_url(url, digested_path) <> "?vsn=d"

  defp absolute_digested_url(url, digested_path, false),
    do: absolute_digested_url(url, digested_path)

  defp absolute_digested_url(url, digested_path),
    do: url |> Path.dirname() |> Path.join(Path.basename(digested_path))

  @doc """
  Deletes compiled/compressed asset files that are no longer in use based on
  the specified criteria.

  ## Arguments

    * `path` - The path where the compiled/compressed files are saved
    * `age` - The max age of assets to keep in seconds
    * `keep` - The number of old versions to keep

  """
  @spec clean(String.t(), integer, integer, integer) :: :ok | {:error, :invalid_path}
  def clean(path, age, keep, now \\ now()) do
    if File.exists?(path) do
      %{"latest" => latest, "digests" => digests} = load_manifest(path)
      files = files_to_clean(latest, digests, now - age, keep)
      remove_files(files, path)
      write_manifest(latest, Map.drop(digests, files), path)
      :ok
    else
      {:error, :invalid_path}
    end
  end

  defp files_to_clean(latest, digests, max_age, keep) do
    digests = Map.drop(digests, Map.values(latest))

    for {_, versions} <- group_by_logical_path(digests),
        file <- versions_to_clean(versions, max_age, keep),
        do: file
  end

  defp versions_to_clean(versions, max_age, keep) do
    versions
    |> Enum.map(fn {path, attrs} -> Map.put(attrs, "path", path) end)
    |> Enum.sort_by(& &1["mtime"], &>/2)
    |> Enum.with_index(1)
    |> Enum.filter(fn {version, index} -> max_age > version["mtime"] || index > keep end)
    |> Enum.map(fn {version, _index} -> version["path"] end)
  end

  defp group_by_logical_path(digests) do
    Enum.group_by(digests, fn {_, attrs} -> attrs["logical_path"] end)
  end

  defp remove_files(files, output_path) do
    for file <- files do
      output_path
      |> Path.join(file)
      |> File.rm()

      output_path
      |> Path.join("#{file}.gz")
      |> File.rm()
    end
  end
end
