defmodule ConCache.Operations do
  @moduledoc false
  def ets(%ConCache{ets: ets}), do: ets

  def isolated(cache, key, timeout \\ nil, fun) do
    ConCache.BalancedLock.exec(cache_key(cache, key), timeout || cache.acquire_lock_timeout, fun)
  end

  def try_isolated(cache, key, timeout \\ nil, on_success) do
    case ConCache.BalancedLock.try_exec(cache_key(cache, key), timeout || cache.acquire_lock_timeout, on_success) do
      {:lock, :not_acquired} -> {:error, :locked}
      response -> {:ok, response}
    end
  end

  defp cache_key(%ConCache{owner_pid: pid}, key) do
    {pid, key}
  end

  def get(%ConCache{ets: ets} = cache, key) do
    case :ets.lookup(ets, key) do
      [{^key, value}] ->
        read_touch(cache, key)
        value
      _ -> nil
    end
  end

  defp read_touch(%ConCache{touch_on_read: false}, _), do: :ok
  defp read_touch(%ConCache{touch_on_read: true} = cache, key) do
    touch(cache, key)
  end

  def put(cache, key, value) do
    isolated(cache, key, fn() ->
      dirty_put(cache, key, value)
    end)
  end

  def size(%ConCache{ets: ets}) do
    :ets.info(ets) |> Keyword.get(:size)
  end

  def insert_new(cache, key, value) do
    update(cache, key, &do_insert_new(value, &1))
  end

  def dirty_insert_new(cache, key, value) do
    dirty_update(cache, key, &do_insert_new(value, &1))
  end

  defp do_insert_new(value, nil), do: {:ok, value}
  defp do_insert_new(_, _), do: {:error, :already_exists}

  def update(cache, key, fun) do
    isolated(cache, key, fn() ->
      do_update(cache, key, fun.(get(cache, key)))
    end)
  end

  def dirty_update(cache, key, fun) do
    do_update(cache, key, fun.(get(cache, key)))
  end

  def update_existing(cache, key, fun) do
    isolated(cache, key, fn() ->
      dirty_update_existing(cache, key, fun)
    end)
  end

  def dirty_update_existing(cache, key, fun) do
    with_existing(cache, key, fn(existing) ->
      do_update(cache, key, fun.(existing))
    end) || {:error, :not_existing}
  end

  defp do_update(_, _, {:error, _} = error), do: error

  defp do_update(cache, key, {:ok, %ConCache.Item{} = new_value}) do
    dirty_put(cache, key, new_value)
  end

  defp do_update(cache, key, {:ok, new_value}) do
    dirty_put(cache, key, %ConCache.Item{value: new_value, ttl: :renew})
  end

  def dirty_put(
    %ConCache{ets: ets, owner_pid: owner_pid} = cache,
    key,
    %ConCache.Item{ttl: ttl, value: value}
  ) do
    set_ttl(cache, key, ttl)
    :ets.insert(ets, {key, value})
    invoke_callback(cache, {:update, owner_pid, key, value})
    :ok
  end

  def dirty_put(%ConCache{ttl: ttl} = cache, key, value) do
    dirty_put(cache, key, %ConCache.Item{value: value, ttl: ttl})
  end

  defp set_ttl(%ConCache{ttl_manager: nil}, _, _), do: :ok
  defp set_ttl(%ConCache{ttl_manager: ttl_manager}, key, ttl) do
    ConCache.Owner.set_ttl(ttl_manager, key, ttl)
  end

  defp clear_ttl(%ConCache{ttl_manager: nil}, _), do: :ok
  defp clear_ttl(%ConCache{ttl_manager: ttl_manager}, key) do
    ConCache.Owner.clear_ttl(ttl_manager, key)
  end


  defp invoke_callback(%ConCache{callback: nil}, _), do: :ok
  defp invoke_callback(%ConCache{callback: fun}, data) when is_function(fun) do
    fun.(data)
  end

  def get_or_store(cache, key, fun) do
    case get(cache, key) do
      nil -> isolated_get_or_store(cache, key, fun)
      value -> value
    end
  end

  defp isolated_get_or_store(cache, key, fun) do
    isolated(cache, key, fn() ->
      dirty_get_or_store(cache, key, fun)
    end)
  end

  def dirty_get_or_store(cache, key, fun) do
    case get(cache, key) do
      nil ->
        new_value = fun.()
        dirty_put(cache, key, new_value)
        value(new_value)

      existing -> existing
    end
  end

  defp value(%ConCache.Item{value: value}), do: value
  defp value(value), do: value

  def delete(cache, key) do
    isolated(cache, key, fn() -> dirty_delete(cache, key) end)
  end

  def dirty_delete(cache, key) do
    clear_ttl(cache, key)
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
