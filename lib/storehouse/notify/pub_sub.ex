defmodule Storehouse.Notify.PubSub do
  @moduledoc """
  Broadcasts what happens to files (`Storehouse.Notify`) on the app's
  `Phoenix.PubSub`, as `{:storehouse, event, info}`.

      config :storehouse,
        notify: {Storehouse.Notify.PubSub, :broadcast, [MyApp.PubSub, {MyApp.Files, :topic, []}]}

      defmodule MyApp.Files do
        # Every file of an account under "accounts/<id>/": its topic.
        def topic(%{file: %{key: "accounts/" <> rest}}), do: "files:" <> hd(String.split(rest, "/"))
        def topic(%{key: "accounts/" <> rest}), do: "files:" <> hd(String.split(rest, "/"))
        def topic(_info), do: nil
      end

  The topic is a string, the same for every event, or `{module, function,
  args}` called with the event's map first, which gives the topic, or `nil`
  to broadcast nothing. In a LiveView:

      def mount(_params, _session, socket) do
        if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "files:42")
        {:ok, socket}
      end

      def handle_info({:storehouse, :analyzed, %{file: file}}, socket), do: ...
  """

  # Phoenix.PubSub comes with Phoenix; Storehouse does not need it.
  @compile {:no_warn_undefined, Phoenix.PubSub}

  @doc "Broadcasts the event on `pubsub`, on the topic (see the module doc)."
  @spec broadcast(atom(), map(), atom(), String.t() | {module(), atom(), list()}) :: :ok
  def broadcast(event, info, pubsub, topic) do
    case topic(topic, info) do
      nil -> :ok
      topic -> Phoenix.PubSub.broadcast(pubsub, topic, {:storehouse, event, info})
    end
  end

  defp topic(topic, _info) when is_binary(topic), do: topic
  defp topic({module, function, args}, info), do: apply(module, function, [info | args])
end
