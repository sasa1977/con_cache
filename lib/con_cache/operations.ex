defmodule ConCache.Operations do
  @moduledoc false
  def ets(%ConCache{ets: ets}), do: ets

  def isolated(cache, key, timeout \\ nil, fun),
    do: ConCache.Lock.exec(lock_pid(cache, key), key, timeout || cache.acquire_lock_timeout, fun)

  def try_isolated(cache, key, timeout \\ nil, on_success) do
    case ConCache.Lock.try_exec(
           lock_pid(cache, key),
           key,
           timeout || cache.acquire_lock_timeout,
           on_success
         ) do
      {:lock, :not_acquired} -> {:error, :locked}
      response -> {:ok, response}
    end
  end

  defp lock_pid(cache, key),
    do: elem(cache.lock_pids, :erlang.phash2(key, tuple_size(cache.lock_pids)))

  def get(cache, key) do
    case fetch(cache, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch(%ConCache{ets: ets} = cache, key) do
    case :ets.lookup(ets, key) do
      [] ->
        :error

      [{^key, value}] ->
        read_touch(cache, key)
        {:ok, value}

      values when is_list(values) ->
        values =
          values
          |> Enum.map(fn {^key, value} -> value end)

        read_touch(cache, key)
        {:ok, values}
    end
  end

  defp valid_ets_type?(%ConCache{ets: ets}) do
    case :ets.info(ets, :type) do
      :set -> true
      :ordered_set -> true
      :bag -> false
      :duplicate_bag -> false
    end
  end

  defp raise_ets_type(%ConCache{ets: ets}) do
    type = :ets.info(ets, :type)

    raise ArgumentError, """
    This function is not supported by ets tables of #{type} type.
    update/3, dirty_update/3, update_existing/3, dirty_update_existing/3,
    get_or_store/3, dirty_get_or_store/3, fetch_or_store/3
    and dirty_fetch_or_store/3 are only supported by :set and
    :ordered_set types of ets tables.
    """
  end

  defp read_touch(%ConCache{touch_on_read: false}, _), do: :ok

  defp read_touch(%ConCache{touch_on_read: true} = cache, key) do
    touch(cache, key)
  end

  def put(cache, key, value) do
    isolated(cache, key, fn ->
      dirty_put(cache, key, value)
    end)
  end

  def size(%ConCache{ets: ets}) do
    :ets.info(ets) |> Keyword.get(:size)
  end

  def insert_new(cache, key, value) do
    isolated(cache, key, fn ->
      dirty_insert_new(cache, key, value)
    end)
  end

  def dirty_insert_new(%ConCache{ets: ets, owner_pid: owner_pid, ttl: ttl} = cache, key, value) do
    if :ets.insert_new(ets, {key, value}) do
      set_ttl(cache, key, ttl)
      invoke_callback(cache, {:update, owner_pid, key, value})
      :ok
    else
      {:error, :already_exists}
    end
  end

  def update(cache, key, fun) do
    isolated(cache, key, fn ->
      dirty_update(cache, key, fun)
    end)
  end

  def dirty_update(cache, key, fun) do
    if valid_ets_type?(cache) do
      case fetch(cache, key) do
        {:ok, value} -> do_update(cache, key, fun.(value), true)
        :error -> do_update(cache, key, fun.(nil), false)
      end
    else
      raise_ets_type(cache)
    end
  end

  def update_existing(cache, key, fun) do
    isolated(cache, key, fn ->
      dirty_update_existing(cache, key, fun)
    end)
  end

  def dirty_update_existing(cache, key, fun) do
    if valid_ets_type?(cache) do
      with_existing(cache, key, fn existing ->
        do_update(cache, key, fun.(existing), true)
      end) || {:error, :not_existing}
    else
      raise_ets_type(cache)
    end
  end

  defp do_update(_, _, {:error, _} = error, _), do: error

  defp do_update(cache, key, {:ok, %ConCache.Item{ttl: ttl, value: new_value}}, _),
    do: perform_put(cache, key, new_value, ttl)

  defp do_update(cache, key, {:ok, new_value}, true),
    do: perform_put(cache, key, new_value, :renew)

  defp do_update(cache, key, {:ok, new_value}, false),
    do: perform_put(cache, key, new_value, cache.ttl)

  defp do_update(_cache, _key, invalid_return_value, _exists) do
    raise(
      "Invalid return value: #{inspect(invalid_return_value)}\n" <>
        "Update lambda should return {:ok, new_value} or {:error, reason}."
    )
  end

  def dirty_put(cache, key, %ConCache.Item{ttl: ttl, value: value}),
    do: perform_put(cache, key, value, ttl)

  def dirty_put(cache, key, value), do: perform_put(cache, key, value, cache.ttl)

  defp perform_put(%ConCache{ets: ets, owner_pid: owner_pid} = cache, key, value, ttl) do
    set_ttl(cache, key, ttl)
    :ets.insert(ets, {key, value})
    invoke_callback(cache, {:update, owner_pid, key, value})
    :ok
  end

  defp set_ttl(_, _, :no_update), do: :ok
  defp set_ttl(%ConCache{ttl_manager: nil}, _, _), do: :ok

  defp set_ttl(%ConCache{ttl_manager: ttl_manager}, key, ttl) do
    ConCache.Owner.set_ttl(ttl_manager, key, ttl)
  end

  defp invoke_callback(%ConCache{callback: nil}, _), do: :ok

  defp invoke_callback(%ConCache{callback: fun}, data) when is_function(fun) do
    fun.(data)
  end

  def get_or_store(cache, key, fun) do
    if valid_ets_type?(cache) do
      case get(cache, key) do
        nil -> isolated_get_or_store(cache, key, fun)
        value -> value
      end
    else
      raise_ets_type(cache)
    end
  end

  defp isolated_get_or_store(cache, key, fun) do
    isolated(cache, key, fn ->
      dirty_get_or_store(cache, key, fun)
    end)
  end

  def dirty_get_or_store(cache, key, fun) do
    if valid_ets_type?(cache) do
      case get(cache, key) do
        nil ->
          new_value = fun.()
          dirty_put(cache, key, new_value)
          value(new_value)

        existing ->
          existing
      end
    else
      raise_ets_type(cache)
    end
  end

  def fetch_or_store(cache, key, fun) do
    if valid_ets_type?(cache) do
      case fetch(cache, key) do
        :error -> isolated_fetch_or_store(cache, key, fun)
        {:ok, existing} -> {:ok, existing}
      end
    else
      raise_ets_type(cache)
    end
  end

  defp isolated_fetch_or_store(cache, key, fun) do
    isolated(cache, key, fn ->
      dirty_fetch_or_store(cache, key, fun)
    end)
  end

  def dirty_fetch_or_store(cache, key, fun) do
    if valid_ets_type?(cache) do
      case fetch(cache, key) do
        :error ->
          case fun.() do
            {:ok, new_value} ->
              dirty_put(cache, key, new_value)
              {:ok, value(new_value)}

            {:error, _reason} = error ->
              error

            _ ->
              raise RuntimeError, """
              The supplied fetch_or_store_fun must return an :ok or :error tuple."
              """
          end

        {:ok, _value} = existing ->
          existing
      end
    else
      raise_ets_type(cache)
    end
  end

  defp value(%ConCache.Item{value: value}), do: value
  defp value(value), do: value

  def delete(cache, key) do
    isolated(cache, key, fn -> dirty_delete(cache, key) end)
  end

  def dirty_delete(cache, key) do
    do_delete(cache, key)
  end

  defp do_delete(%ConCache{ets: ets, owner_pid: owner_pid} = cache, key) do
    try do
      invoke_callback(cache, {:delete, owner_pid, key})
    after
      :ets.delete(ets, key)
    end

    :ok
  end

  defp with_existing(cache, key, fun) do
    case get(cache, key) do
      nil -> nil
      existing -> fun.(existing)
    end
  end

  def touch(cache, key) do
    set_ttl(cache, key, :renew)
  end
end
