defmodule ConCache.Owner do
  @moduledoc false

  use ExActor.Tolerant
  use Bitwise

  defstruct [
    ttl_check: nil,
    current_time: 1,
    pending: nil,
    ttls: nil,
    max_time: nil,
    on_expire: nil,
    pending_ttl_sets: HashDict.new,
    monitor_ref: nil
  ]

  def cache({:local, local}) when is_atom(local), do: cache(local)
  def cache(local) when is_atom(local), do: ConCache.Registry.get(Process.whereis(local))
  def cache({:global, name}), do: cache({:via, :global, name})
  def cache({:via, module, name}), do: cache(module.whereis_name(name))
  def cache(pid) when is_pid(pid), do: ConCache.Registry.get(pid)

  defstart start_link(options \\ []), gen_server_opts: :runtime
  defstart start(options \\ []), gen_server_opts: :runtime do
    ets = create_ets(options[:ets_options] || [])
    check_ets(ets)

    cache = %ConCache{
      owner_pid: self,
      ets: ets,
      ttl: options[:ttl] || 0,
      acquire_lock_timeout: options[:acquire_lock_timeout] || 5000,
      callback: options[:callback],
      touch_on_read: options[:touch_on_read] || false
    }

    state = start_ttl_loop(options)
    if Map.get(state, :ttl_check) != nil do
      cache = %ConCache{cache | ttl_manager: self}
    end

    state = %__MODULE__{state | monitor_ref: Process.monitor(Process.whereis(:con_cache_registry))}
    ConCache.Registry.register(cache)

    initial_state(state)
  end

  defp create_ets(input_options) do
    %{name: name, type: type, options: options} = parse_ets_options(input_options)
    :ets.new(name, [type | options])
  end

  defp parse_ets_options(input_options) do
    Enum.reduce(
      input_options,
      %{name: :con_cache, type: :set, options: [:public]},
        fn
          (:named_table, acc) -> append_option(acc, :named_table)
          (:compressed, acc) -> append_option(acc, :compressed)
          ({:heir, _} = opt, acc) -> append_option(acc, opt)
          ({:write_concurrency, _} = opt, acc) -> append_option(acc, opt)
          ({:read_concurrency, _} = opt, acc) -> append_option(acc, opt)
          (:ordered_set, acc) -> %{acc | type: :ordered_set}
          (:set, acc) -> %{acc | type: :set}
          ({:name, name}, acc) -> %{acc | name: name}
          (other, _) -> throw({:invalid_ets_option, other})
        end
    )
  end

  defp append_option(%{options: options} = ets_options, option) do
    %{ets_options | options: [option | options]}
  end

  defp check_ets(ets) do
    if (:ets.info(ets, :keypos) > 1), do: throw({:error, :invalid_keypos})
    if (:ets.info(ets, :protection) != :public), do: throw({:error, :invalid_protection})
    if (not (:ets.info(ets, :type) in [:set, :ordered_set])), do: throw({:error, :invalid_type})
  end

  defp start_ttl_loop(options) do
    me = self
    case options[:ttl_check] do
      ttl_check when is_integer(ttl_check) and ttl_check > 0 ->
        %__MODULE__{
          ttl_check: ttl_check,
          on_expire: &ConCache.delete(me, &1),
          pending: :ets.new(:ttl_manager_pending, [:private, :bag]),
          ttls: :ets.new(:ttl_manager_ttls, [:private, :set]),
          max_time: (1 <<< (options[:time_size] || 16)) - 1
        }
        |> queue_check

      _ -> %__MODULE__{ttl_check: nil}
    end
  end


  def clear_ttl(server, key) do
    set_ttl(server, key, 0)
  end

  defcast set_ttl(key, ttl), state: %__MODULE__{pending_ttl_sets: pending_ttl_sets} = state do
    %__MODULE__{state | pending_ttl_sets: Dict.update(pending_ttl_sets, key, ttl, &queue_ttl_set(&1, ttl))}
    |> new_state
  end

  defp queue_ttl_set(existing, :renew), do: existing
  defp queue_ttl_set(_, new_ttl), do: new_ttl

  defp apply_pending_ttls(%__MODULE__{pending_ttl_sets: pending_ttl_sets} = state) do
    Enum.each(pending_ttl_sets, fn({key, ttl}) ->
      do_set_ttl(state, key, ttl)
    end)

    %__MODULE__{state | pending_ttl_sets: HashDict.new}
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

  defp item_ttl(%__MODULE__{ttls: ttls}, key) do
    case :ets.lookup(ttls, key) do
      [{^key, {_, ttl}}] -> ttl
      _ -> nil
    end
  end

  defp item_expiry_time(%__MODULE__{ttls: ttls}, key) do
    case :ets.lookup(ttls, key) do
      [{^key, {item_expiry_time, _}}] -> item_expiry_time
      _ -> nil
    end
  end

  defp remove_pending(%__MODULE__{pending: pending} = state, key) do
    case item_expiry_time(state, key) do
      nil -> :ok
      item_expiry_time -> :ets.delete_object(pending, {item_expiry_time, key})
    end
  end

  defp store_ttl(state, _, 0), do: state

  defp store_ttl(%__MODULE__{pending: pending, ttls: ttls} = state, key, ttl) when(
    is_integer(ttl) and ttl > 0
  ) do
    expiry_time = expiry_time(state, ttl)
    :ets.insert(ttls, {key, {expiry_time, ttl}})
    :ets.insert(pending, {expiry_time, key})
  end

  defp expiry_time(%__MODULE__{current_time: current_time, ttl_check: ttl_check}, ttl) do
    steps = ttl / ttl_check
    isteps = trunc(steps)
    isteps = if steps > isteps do
      isteps + 1
    else
      isteps
    end

    current_time + 1 + isteps
  end

  defp queue_check(%__MODULE__{ttl_check: ttl_check} = state) do
    :erlang.send_after(ttl_check, self, :check_purge)
    state
  end

  defhandleinfo :check_purge, state: state do
    state
    |> apply_pending_ttls
    |> increase_time
    |> purge
    |> queue_check
    |> new_state
  end

  defhandleinfo {:DOWN, ref1, _, _, reason},
    state: %__MODULE__{monitor_ref: ref2},
    when: ref1 == ref2,
    do: stop_server(reason)

  defhandleinfo _, do: noreply

  defp increase_time(%__MODULE__{current_time: max, max_time: max} = state) do
    normalize_pending(state)
    normalize_ttls(state)
    %__MODULE__{state | current_time: 0}
  end

  defp increase_time(%__MODULE__{current_time: current_time} = state) do
    %__MODULE__{state | current_time: current_time + 1}
  end

  defp normalize_pending(%__MODULE__{current_time: current_time, pending: pending}) do
    all_pending = :ets.tab2list(pending)
    :ets.delete_all_objects(pending)
    Enum.each(all_pending, fn({time, value}) ->
      :ets.insert(pending, {time - current_time - 1, value})
    end)
  end

  defp normalize_ttls(%__MODULE__{current_time: current_time, ttls: ttls}) do
    all_ttls = :ets.tab2list(ttls)
    :ets.delete_all_objects(ttls)
    Enum.each(all_ttls, fn({key, {expiry_time, ttl}}) ->
      :ets.insert(ttls, {key, {expiry_time - current_time - 1, ttl}})
    end)
  end

  defp purge(%__MODULE__{current_time: current_time, pending: pending, ttls: ttls, on_expire: on_expire} = state) do
    Enum.each(currently_pending(state), fn(key) ->
      on_expire.(key)
      :ets.delete(ttls, key)
    end)
    :ets.delete(pending, current_time)
    state
  end

  defp currently_pending(%__MODULE__{pending: pending, current_time: current_time}) do
    :ets.lookup(pending, current_time)
    |> Enum.map(&elem(&1, 1))
  end
end