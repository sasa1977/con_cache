defmodule TtlManager do
  @type options :: Keyword.t
  @type key :: any
  @type ttl :: non_neg_integer | :renew
  
  use ExActor
  use Bitwise
  
  defrecord State, [
    ttl_check: :timer.seconds(1), 
    current_time: 1,
    pending: HashDict.new, 
    ttls: HashDict.new,
    on_expire: nil,
    pending_ttl_sets: HashDict.new
  ]
  
  @spec start(options) :: {:ok, pid}
  @spec start_link(options) :: {:ok, pid}

  def init(options) do
    State.new(options) |>
    queue_check |>
    initial_state
  end
  
  @spec set_ttl(pid | atom, key, ttl) :: :ok
  defcast set_ttl(key, ttl), state: State[pending_ttl_sets: pending_ttl_sets] = state do
    state.pending_ttl_sets(Dict.put(pending_ttl_sets, key, ttl)) |>
    new_state
  end
  
  defp apply_pending_ttls(State[pending_ttl_sets: pending_ttl_sets] = state) do
    state = Enum.reduce(pending_ttl_sets, state, fn({key, ttl}, state) ->
      do_set_ttl(state, key, ttl)
    end)
    
    State.pending_ttl_sets(HashDict.new, state)
  end
  
  defp do_set_ttl(state, key, :renew) do
    case item_ttl(state, key) do
      nil -> state
      ttl -> do_set_ttl(state, key, ttl)
    end
  end
  
  defp do_set_ttl(state, key, ttl) do
    remove_pending(state, key) |>
    store_ttl(key, ttl)
  end
  
  defp item_ttl(State[ttls: ttls], key) do
    case ttls[key] do
      {_, ttl} -> ttl
      _ -> nil
    end
  end

  defp remove_pending(State[pending: pending, ttls: ttls] = state, key) do
    case ttls[key] do
      nil -> state
      {expiry_time, _} ->
        case pending[expiry_time] do
          nil -> state
          items ->
            Dict.put(pending, expiry_time, :sets.del_element(key, items)) |>
            state.pending
        end
    end
  end

  defp store_ttl(state, _, 0), do: state

  defp store_ttl(State[pending: pending, ttls: ttls] = state, key, ttl) when(
    is_integer(ttl) and ttl > 0
  ) do
    expiry_time = expiry_time(state, ttl)

    state.
      ttls(Dict.put(ttls, key, {expiry_time, ttl})).
      pending(
        Dict.update(pending, expiry_time,
          :sets.from_list([key]),
          :sets.add_element(key, &1)
        )
      )
  end

  defp expiry_time(State[current_time: current_time, ttl_check: ttl_check], ttl) do
    steps = ttl / ttl_check
    isteps = trunc(steps)
    isteps = if steps > isteps do
      isteps + 1
    else
      isteps
    end
    
    current_time + 1 + isteps
  end
  
  defp queue_check(State[ttl_check: ttl_check] = state) do
    :erlang.send_after(ttl_check, self, :check_purge)
    state
  end

  def handle_info(:check_purge, state) do
    state |>
    apply_pending_ttls |>
    increase_time |>
    purge |>
    queue_check |>
    new_state
  end
  
  def handle_info(_, state) do
    new_state(state)
  end
  
  defp increase_time(State[current_time: (2 <<< 15) - 1] = state) do
    state |>
    normalize_pending |>
    normalize_ttls |>
    reset_time
  end
  
  defp increase_time(State[current_time: current_time] = state) do
    state.current_time(current_time + 1)
  end
  
  defp normalize_pending(State[current_time: current_time, pending: pending] = state) do
    Enum.reduce(pending, HashDict.new, fn({time, value}, pending_acc) ->
      Dict.put(pending_acc, time - current_time, value)
    end) |>
    state.pending
  end
  
  defp normalize_ttls(State[current_time: current_time, ttls: ttls] = state) do
    Enum.reduce(ttls, HashDict.new, fn({key, {expiry_time, ttl}}, ttl_acc) ->
      Dict.put(ttl_acc, key, {expiry_time - current_time, ttl})
    end) |>
    state.ttls
  end
  
  defp reset_time(State[] = state), do: state.current_time(0)

  defp purge(State[current_time: current_time, pending: pending] = state) do
    Enum.reduce(
      :sets.to_list(pending[current_time] || :sets.new),
      state.update_pending(Dict.delete(&1, current_time)),
      function(:do_purge, 2)
    )
  end

  defp do_purge(key, State[ttls: ttls, on_expire: on_expire] = state) do
    on_expire.(key)
    state.ttls(Dict.delete(ttls, key))
  end
end