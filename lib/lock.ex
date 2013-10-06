defmodule Lock do
  @type key :: any
  @type result :: any
  @type job :: (() -> result)
  
  defrecord Item, pending: :gb_trees.empty, locked: nil  
  defrecord State, items: HashDict.new

  use ExActor

  @spec start :: {:ok, pid}
  @spec start_link :: {:ok, pid}

  def init(_) do
    initial_state(State.new)
  end

  @spec exec(pid | atom, key, timeout, job) :: result
  @spec exec(pid | atom, key, job) :: result
  def exec(server, id, timeout // 5000, fun) do
    lock(server, self, id)
    try do
      wait_for_lock(server, id, timeout, fun)
    after
      unlock(server, self, id)
    end
  end

  defp wait_for_lock(server, id, timeout, fun) do
    receive do
      {:lock, ^id, ^server, :acquired} -> fun.()
    after timeout ->
      throw(:timeout)
    end
  end

  @spec try_exec(pid | atom, key, job) :: result | {:lock, :not_acquired}
  @spec try_exec(pid | atom, key, timeout, job) :: result | {:lock, :not_acquired}
  def try_exec(server, id, timeout // 5000, fun) do
    try_lock(server, self, id)
    try_wait_for_lock(server, id, timeout, fun)
  end

  defp try_wait_for_lock(server, id, timeout, fun) do
    receive do
      {:lock, ^id, ^server, :acquired} -> 
        try do
          fun.()
        after
          unlock(server, self, id)
        end
      {:lock, ^id, ^server, :not_acquired} -> {:lock, :not_acquired}
    after timeout ->
      unlock(server, self, id)
      {:lock, :not_acquired}
    end
  end

  defcast lock(caller, id), state: state do
    do_lock(state, caller, id) |>
    new_state
  end

  defp do_lock(state, caller, id) do
    state |>
    register_to_item(caller, id)
  end

  defcast try_lock(caller, id), state: state do
    can_lock?(state, caller, id) |>
    maybe_lock(state, caller, id) |>
    new_state
  end

  defp maybe_lock(true, state, caller, id), do: do_lock(state, caller, id)
  defp maybe_lock(false, state, caller, id) do
    caller <- {:lock, id, self, :not_acquired}
    state
  end

  defp can_lock?(State[items: items], caller, id) do
    can_lock?(caller, items[id] || Item.new)
  end

  defp can_lock?(_, Item[locked: nil]), do: true
  defp can_lock?(caller, Item[locked: {caller, _}]), do: true
  defp can_lock?(_, _), do: false

  defp register_to_item(State[items: items] = state, caller, id) do
    add_process_to_item(caller, id, items[id] || Item.new) |>
    store_item(id, state)
  end

  defp add_process_to_item(caller, id, Item[locked: nil] = item) do
    caller <- {:lock, id, self, :acquired}
    item.locked({caller, 1})
  end
  
  defp add_process_to_item(caller, id, Item[locked: {caller, count}] = item) do
    caller <- {:lock, id, self, :acquired}
    item.locked({caller, count + 1})
  end

  defp add_process_to_item(caller, _, Item[locked: {locked, _}, pending: pending] = item)  when is_pid(locked) do
    key = case :gb_trees.size(pending) do
      0 -> 1
      _ -> (:gb_trees.largest(pending) |> elem(0)) + 1
    end

    item.pending(:gb_trees.insert(key, caller, pending))
  end

  defp store_item(Item[locked: locked, pending: pending] = item, id, State[] = state) do
    case locked == nil and :gb_trees.size(pending) do
      0 -> state.update_items(&Dict.delete(&1, id))
      _ -> state.update_items(&Dict.put(&1, id, item))
    end
  end

  defcast unlock(caller, id), state: State[items: items] = state do
    remove_process_from_item(state, caller, id, items[id]) |>
    new_state
  end
  
  defp remove_process_from_item(
    state, caller, {:force, id}, Item[locked: {caller, _}] = item
  ) do
    remove_process_from_item(state, caller, id, item.locked({caller, 1}))
  end

  defp remove_process_from_item(state, caller, {:force, id}, item) do
    remove_process_from_item(state, caller, id, item)
  end

  defp remove_process_from_item(
    state, caller, id, Item[pending: pending, locked: {caller, 1}] = item
  ) do
    case :gb_trees.size(pending) do
      0 -> item.locked(nil)
      _ ->
        {_, next, remaining} = :gb_trees.take_smallest(pending)
        add_process_to_item(next, id, item.locked(nil).pending(remaining))
    end |>
    store_item(id, state)
  end
  
  defp remove_process_from_item(state, caller, id, Item[locked: {caller, count}] = item) do
    item.locked({caller, count - 1}) |>
    store_item(id, state)
  end

  defp remove_process_from_item(state, caller, id, Item[pending: pending] = item) do
    item.pending(
      Enum.filter(:gb_trees.to_list(pending), fn(pid) -> pid != caller end) |>
      :gb_trees.from_orddict
    ) |>
    store_item(id, state)
  end
end