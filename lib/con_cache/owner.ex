defmodule ConCache.Owner do
  @moduledoc false

  use GenServer
  use Bitwise

  defstruct ttl_check: nil,
            current_time: 1,
            pending: nil,
            ttls: nil,
            max_time: nil,
            on_expire: nil

  def cache(nil), do: exit(:noproc)
  def cache(:undefined), do: exit(:noproc)
  def cache({:local, local}) when is_atom(local), do: cache(local)
  def cache(local) when is_atom(local), do: cache(Process.whereis(local))
  def cache({:global, name}), do: cache({:via, :global, name})
  def cache({:via, module, name}), do: cache(module.whereis_name(name))

  def cache(pid) when is_pid(pid) do
    [{_, cache}] = Registry.lookup(ConCache, {pid, __MODULE__})
    cache
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def set_ttl(server, key, ttl), do: GenServer.cast(server, {:set_ttl, key, ttl})

  @impl GenServer
  def init(options) do
    ets = create_ets(options[:ets_options] || [])
    check_ets(ets)

    state = start_ttl_loop(options)
    ttl_manager = if Map.get(state, :ttl_check) != nil, do: self()

    cache = %ConCache{
      owner_pid: parent_process(),
      ets: ets,
      ttl_manager: ttl_manager,
      ttl: options[:ttl] || :infinity,
      acquire_lock_timeout: options[:acquire_lock_timeout] || 5000,
      callback: options[:callback],
      touch_on_read: options[:touch_on_read] || false,
      lock_pids: List.to_tuple(ConCache.LockSupervisor.lock_pids(parent_process()))
    }

    {:ok, _} = Registry.register(ConCache, {parent_process(), __MODULE__}, cache)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:set_ttl, key, ttl}, state) do
    handle_set_ttl(state, key, ttl)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:check_purge, state) do
    {:noreply,
     state
     |> increase_time
     |> purge
     |> queue_check}
  end

  defp create_ets(input_options) do
    %{name: name, type: type, options: options} = parse_ets_options(input_options)
    :ets.new(name, [type | options])
  end

  defp parse_ets_options(input_options) do
    Enum.reduce(input_options, %{name: :con_cache, type: :set, options: [:public]}, fn
      :named_table, acc -> append_option(acc, :named_table)
      :compressed, acc -> append_option(acc, :compressed)
      {:heir, _} = opt, acc -> append_option(acc, opt)
      {:write_concurrency, _} = opt, acc -> append_option(acc, opt)
      {:read_concurrency, _} = opt, acc -> append_option(acc, opt)
      :ordered_set, acc -> %{acc | type: :ordered_set}
      :set, acc -> %{acc | type: :set}
      :bag, acc -> %{acc | type: :bag}
      :duplicate_bag, acc -> %{acc | type: :duplicate_bag}
      {:name, name}, acc -> %{acc | name: name}
      other, _ -> throw({:invalid_ets_option, other})
    end)
  end

  defp append_option(%{options: options} = ets_options, option) do
    %{ets_options | options: [option | options]}
  end

  defp check_ets(ets) do
    if :ets.info(ets, :keypos) > 1, do: throw({:error, :invalid_keypos})
    if :ets.info(ets, :protection) != :public, do: throw({:error, :invalid_protection})

    if not (:ets.info(ets, :type) in [:set, :ordered_set, :bag, :duplicate_bag]),
      do: throw({:error, :invalid_type})
  end

  defp start_ttl_loop(options) do
    case options[:ttl_check] do
      ttl_check when is_integer(ttl_check) and ttl_check > 0 ->
        %__MODULE__{
          ttl_check: ttl_check,
          on_expire: &ConCache.delete(parent_process(), &1),
          pending: :ets.new(:ttl_manager_pending, [:private, :bag]),
          ttls: :ets.new(:ttl_manager_ttls, [:private, :set]),
          max_time: (1 <<< (options[:time_size] || 16)) - 1
        }
        |> queue_check

      _ ->
        %__MODULE__{ttl_check: nil}
    end
  end

  defp handle_set_ttl(state, key, :renew) do
    with ttl when not is_nil(ttl) <- item_ttl(state, key) do
      handle_set_ttl(state, key, ttl)
    end
  end

  defp handle_set_ttl(state, key, :infinity), do: remove_pending(state, key)

  defp handle_set_ttl(state, key, ttl) do
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

  defp store_ttl(%__MODULE__{pending: pending, ttls: ttls} = state, key, ttl)
       when is_integer(ttl) and ttl > 0 do
    expiry_time = expiry_time(state, ttl)
    :ets.insert(ttls, {key, {expiry_time, ttl}})
    :ets.insert(pending, {expiry_time, key})
  end

  defp expiry_time(%__MODULE__{current_time: current_time, ttl_check: ttl_check}, ttl) do
    steps = ttl / ttl_check
    isteps = trunc(steps)

    isteps =
      if steps > isteps do
        isteps + 1
      else
        isteps
      end

    current_time + 1 + isteps
  end

  defp queue_check(%__MODULE__{ttl_check: ttl_check} = state) do
    :erlang.send_after(ttl_check, self(), :check_purge)
    state
  end

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

    Enum.each(all_pending, fn {time, value} ->
      :ets.insert(pending, {time - current_time - 1, value})
    end)
  end

  defp normalize_ttls(%__MODULE__{current_time: current_time, ttls: ttls}) do
    all_ttls = :ets.tab2list(ttls)
    :ets.delete_all_objects(ttls)

    Enum.each(all_ttls, fn {key, {expiry_time, ttl}} ->
      :ets.insert(ttls, {key, {expiry_time - current_time - 1, ttl}})
    end)
  end

  defp purge(
         %__MODULE__{
           current_time: current_time,
           pending: pending,
           ttls: ttls,
           on_expire: on_expire
         } = state
       ) do
    Enum.each(currently_pending(state), fn key ->
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

  defp parent_process() do
    case hd(Process.get(:"$ancestors")) do
      pid when is_pid(pid) -> pid
      atom when is_atom(atom) -> Process.whereis(atom)
    end
  end
end
