# LiveView

`Storehouse.Live.consume/3` stores the files of a LiveView upload: each
entry that is done, once, checked by its bytes and stored under a new
key; and those the upload refused, cancelled. It gives a result for
each, so that the LiveView shows the file, or says why it is not there.

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:photos, [])
   |> allow_upload(:photos,
     accept: ~w(.png .jpg .jpeg .gif .webp),
     max_file_size: 10_000_000,
     max_entries: 10,
     auto_upload: true,
     progress: &handle_progress/3
   )}
end

defp handle_progress(:photos, _entry, socket), do: {:noreply, store_photos(socket)}

# The form's phx-change: a file that fails validation (too large, a type
# that is not accepted) is cancelled here.
def handle_event("validate", _params, socket), do: {:noreply, store_photos(socket)}

defp store_photos(socket) do
  {socket, results} =
    Storehouse.Live.consume(socket, :photos,
      accept: Storehouse.Check.images(),
      max_pixels: 50_000_000
    )

  Enum.reduce(results, socket, fn
    {_entry, {:ok, file}}, socket ->
      update(socket, :photos, &[file | &1])

    {entry, {:error, reason}}, socket ->
      put_flash(socket, :error, "#{entry.client_name} was not added: #{inspect(reason)}")
  end)
end
```

```heex
<form id="photos" phx-change="validate">
  <.live_file_input upload={@uploads.photos} />
</form>
```

## What is checked

The size limit and the accepted extensions are the upload's
(`Phoenix.LiveView.allow_upload/3`): the browser checks them first, and
the server again. Then Storehouse reads the first bytes of each file. It
keeps a content type only when the bytes prove it (`Storehouse.Check`);
the type the browser sends is not trusted. `:accept` refuses the checked
types you do not take: a page renamed `.png` is not an image, and gives
`{:error, :not_accepted}`.

## Once each

LiveView drops a consumed entry a message after it is consumed. Two
calls in that time (the progress of the next file, a form change) would
consume it twice, and the second would crash the LiveView: `consume/3`
keeps the refs it consumed, and leaves those entries alone. Call it from
the progress callback, from the form's change handler, or both.

## The results

Each result is `{entry, {:ok, file}}` or `{entry, {:error, reason}}`, in
the entries' order: the entry's `ref` matches what the browser has (a
placeholder of yours for the file, say). The reasons are the upload's
(`:too_large`, `:not_accepted`, `:too_many_files`), the check's
(`:not_accepted` for `:accept`, `:too_large` for `:max_pixels`) and the
store's own.

## Direct and streamed uploads

`Storehouse.Live.allow/3`, in place of `allow_upload/3`, sends the files
straight from the browser to the store, when the store takes direct
uploads (`Storehouse.S3`, and `Storehouse.Local` in development), or, with
`mode: :stream`, through the LiveView and on to the store as they come,
with no file on the app's disk: `consume/3` gives them stored and
checked. See [Direct uploads](direct_uploads.md), and [Ecto](ecto.md)
for files in records.

## What happens to files, live

A photo's analysis may finish after the LiveView that uploaded it has
moved on, and other people may have the page open. Tell your app what
happens to files (`Storehouse.Notify`), and broadcast it on your PubSub,
on a topic of each account:

```elixir
# config/config.exs
config :storehouse,
  notify: {Storehouse.Notify.PubSub, :broadcast, [MyApp.PubSub, {MyApp.Files, :topic, []}]}
```

```elixir
defmodule MyApp.Files do
  # Keys made with a prefix per account (`key:`): "accounts/42/…".
  def topic(%{file: %{key: key}}), do: topic_of(key)
  def topic(%{key: key}), do: topic_of(key)
  def topic(_info), do: nil

  defp topic_of("accounts/" <> rest), do: "files:" <> hd(String.split(rest, "/"))
  defp topic_of(_key), do: nil
end
```

```elixir
def mount(_params, _session, socket) do
  if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "files:#{socket.assigns.account.id}")
  {:ok, socket}
end

def handle_info({:storehouse, :analyzed, %{file: file}}, socket),
  do: {:noreply, update_photo(socket, file)}

def handle_info({:storehouse, _event, _info}, socket), do: {:noreply, socket}
```

`:analyzed` from `Storehouse.analyze_later/3` comes once its `:then` has
the results, so a LiveView that reloads the record finds them saved. A
JavaScript client follows the same topic through a Phoenix Channel.
