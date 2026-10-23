defmodule Storehouse.Analyzer.Warm do
  @moduledoc """
  A step (`Storehouse.Analyzer`) that makes an image's sizes before a
  visitor asks for them (`Storehouse.Responsive.warm/3`), under `"warm"`:
  for an app that runs its steps out of the request already
  (`Storehouse.analyze_later/3`), on a queue of their own.

      steps = [
        Storehouse.Analyzer.Placeholder,
        {Storehouse.Analyzer.Warm, warm: [:photo], up_to: 3840}
      ]

      Storehouse.analyze_later(file, steps,
        then: {MyApp.Photos, :analyzed, [photo.id]},
        runner: {Storehouse.Runner.Oban, queue: :media}
      )

  It needs no download of the original: alone, it reads nothing. Skipped
  when warming is off (`Storehouse.Responsive.enabled?/1`), and for a file
  that is not an image. `Storehouse.Responsive.warm_later/3` does the same
  with no other steps.

  ## Options

    * `:warm` - the presets to warm (required): a name, or a list.
    * `Storehouse.Responsive.warm/3`'s, and `:enabled`.
  """

  @behaviour Storehouse.Analyzer

  @impl true
  def name, do: "warm"

  # It asks for the variants; the original is read by what makes them.
  @impl true
  def needs_file?, do: false

  @impl true
  def analyze(%Storehouse.File{content_type: "image/" <> _} = file, _path, opts) do
    if Storehouse.Responsive.enabled?(opts) do
      {presets, opts} = Keyword.pop!(opts, :warm)

      with {:ok, count} <-
             Storehouse.Responsive.warm(file, presets, Keyword.delete(opts, :enabled)),
           do: {:ok, %{"sizes" => count}}
    else
      :skip
    end
  end

  def analyze(_file, _path, _opts), do: :skip
end
