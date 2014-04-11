defmodule TtlManager do
  @type options :: Keyword.t
  @type key :: any
  @type ttl :: non_neg_integer | :renew

  use ExActor.Tolerant
  use Bitwise
  
  defrecordp :ttl_state, [
    ttl_check: nil,
    current_time: 1,
    pending: nil,
    ttls: nil,
    max_time: nil,
    on_expire: nil,
    pending_ttl_sets: HashDict.new
  ]

  @spec start(options) :: {:ok, pid}
  @spec start_link(options) :: {:ok, pid}

  def init(options) do
    ttl_state([
      ttl_check: options[:ttl_check] || :timer.seconds(1),
      on_expire: options[:on_expire] || nil,
      pending: :ets.new(:ttl_manager_pending, [:private, :bag]),
      ttls: :ets.new(:ttl_manager_ttls, [:private, :set]),
      max_time: (1 <<< (options[:time_size] || 16)) - 1
    ])
    |> queue_check
    |> initial_state
  end

  defcast stop, state: state do
    {:stop, :normal, state}
  end

  @spec clear_ttl(pid | atom, key) :: :ok
  def clear_ttl(server, key) do
    set_ttl(server, key, 0)
  end

  @spec set_ttl(pid | atom, key, ttl) :: :ok
  defcast set_ttl(key, ttl), state: ttl_state(pending_ttl_sets: pending_ttl_sets) = state do
    state
    |> ttl_state(pending_ttl_sets: Dict.update(pending_ttl_sets, key, ttl, &queue_ttl_set(&1, ttl)))
    |> new_state
  end

  defp queue_ttl_set(existing, :renew), do: existing
  defp queue_ttl_set(_, new_ttl), do: new_ttl

  defp apply_pending_ttls(ttl_state(pending_ttl_sets: pending_ttl_sets) = state) do
    Enum.each(pending_ttl_sets, fn({key, ttl}) ->
      do_set_ttl(state, key, ttl)
    end)

    ttl_state(state, pending_ttl_sets: HashDict.new)
  end

  defp do_set_ttl(state, key, :renew) do
    case item_ttl(state, key) do
      nil -> state
      ttl -> do_set_ttl(state, key, ttl)
    end
  end

  defp do_set_ttl(state, key, ttl) do
    remove_pending(state, key)
    store_ttl(state, key, ttl)
  end

  defp item_ttl(ttl_state(ttls: ttls), key) do
    case :ets.lookup(ttls, key) do
      [{^key, {_, ttl}}] -> ttl
      _ -> nil
    end
  end

  defp item_expiry_time(ttl_state(ttls: ttls), key) do
    case :ets.lookup(ttls, key) do
      [{^key, {item_expiry_time, _}}] -> item_expiry_time
      _ -> nil
    end
  end

  defp remove_pending(ttl_state(pending: pending) = state, key) do
    case item_expiry_time(state, key) do
      nil -> :ok
      item_expiry_time -> :ets.delete_object(pending, {item_expiry_time, key})
    end
  end

  defp store_ttl(state, _, 0), do: state

  defp store_ttl(ttl_state(pending: pending, ttls: ttls) = state, key, ttl) when(
    is_integer(ttl) and ttl > 0
  ) do
    expiry_time = expiry_time(state, ttl)
    :ets.insert(ttls, {key, {expiry_time, ttl}})
    :ets.insert(pending, {expiry_time, key})
  end

  defp expiry_time(ttl_state(current_time: current_time, ttl_check: ttl_check), ttl) do
    steps = ttl / ttl_check
    isteps = trunc(steps)
    isteps = if steps > isteps do
      isteps + 1
    else
      isteps
    end

    current_time + 1 + isteps
  end

  defp queue_check(ttl_state(ttl_check: ttl_check) = state) do
    :erlang.send_after(ttl_check, self, :check_purge)
    state
  end

  definfo :check_purge, state: state do
    state
    |> apply_pending_ttls
    |> increase_time
    |> purge
    |> queue_check
    |> new_state
  end

  definfo _, do: noreply

  defp increase_time(ttl_state(current_time: max, max_time: max) = state) do
    normalize_pending(state)
    normalize_ttls(state)
    ttl_state(state, current_time: 0)
  end

  defp increase_time(ttl_state(current_time: current_time) = state) do
    ttl_state(state, current_time: current_time + 1)
  end

  defp normalize_pending(ttl_state(current_time: current_time, pending: pending)) do
    all_pending = :ets.tab2list(pending)
    :ets.delete_all_objects(pending)
    Enum.each(all_pending, fn({time, value}) ->
      :ets.insert(pending, {time - current_time - 1, value})
    end)
  end

  defp normalize_ttls(ttl_state(current_time: current_time, ttls: ttls)) do
    all_ttls = :ets.tab2list(ttls)
    :ets.delete_all_objects(ttls)
    Enum.each(all_ttls, fn({key, {expiry_time, ttl}}) ->
      :ets.insert(ttls, {key, {expiry_time - current_time - 1, ttl}})
    end)
  end

  defp purge(ttl_state(current_time: current_time, pending: pending, ttls: ttls, on_expire: on_expire) = state) do
    Enum.each(currently_pending(state), fn(key) ->
      on_expire.(key)
      :ets.delete(ttls, key)
    end)
    :ets.delete(pending, current_time)
    state
  end

  defp currently_pending(ttl_state(pending: pending, current_time: current_time)) do
    :ets.lookup(pending, current_time) 
    |> Enum.map(&elem(&1, 1))
  end
end