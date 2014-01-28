defrecord ConCacheItem, value: nil, ttl: 0

defrecord ConCache, [
  :ets, :lock, :ttl_manager, :ttl, :acquire_lock_timeout, :callback, :touch_on_read
] do
  @type options :: Keyword.t
  @type key :: any
  @type value :: any
  @type in_value :: ConCacheItem.t | value
  @type result :: any
  @type job :: (() -> result)
  @type updater :: ((value) -> {:cancel_update, result} | in_value)

  
  @spec start_link :: t
  @spec start_link(options) :: t
  def start_link(options // []) do
    ets = options[:ets] || create_ets(options[:ets_options] || [])
    check_ets(ets)

    new(
      ets: ets,
      lock: BalancedLock.start_link(options[:lock_balancers] || 10),
      ttl: options[:ttl] || 0,
      acquire_lock_timeout: options[:acquire_lock_timeout] || 5000,
      callback: options[:callback],
      touch_on_read: options[:touch_on_read] || false
    ) 
    |> create_ttl_manager(options)
  end

  @spec stop(t) :: :ok
  def stop(ConCache[] = cache) do
    :ets.delete(cache.ets)
    BalancedLock.stop(cache.lock)
    if cache.ttl_manager do
      TtlManager.stop(cache.ttl_manager)
    end

    :ok
  end

  defp check_ets(ets) do
    if (:ets.info(ets, :keypos) > 1), do: throw({:error, :invalid_keypos})
    if (:ets.info(ets, :protection) != :public), do: throw({:error, :invalid_protection})
    if (not (:ets.info(ets, :type) in [:set, :ordered_set])), do: throw({:error, :invalid_type})
  end
  
  defp create_ets(ets_options) do
    parsed_options = parse_ets_options(ets_options)
    :ets.new(parsed_options.name, [parsed_options.type | parsed_options.options])
  end
  
  defrecord EtsOptions, name: :con_cache, type: :set, options: [:public] do
    def append_option(option, __MODULE__[options: options] = this) do
      this.options([option | options])
    end
  end
  
  defp parse_ets_options(ets_options) do
    Enum.reduce(
      ets_options,
      EtsOptions.new,
        fn
          (:named_table, acc) -> acc.append_option(:named_table)
          (:compressed, acc) -> acc.append_option(:compressed)
          ({:heir, _} = opt, acc) -> acc.append_option(opt)
          ({:write_concurrency, _} = opt, acc) -> acc.append_option(opt)
          ({:read_concurrency, _} = opt, acc) -> acc.append_option(opt)
          (:ordered_set, acc) -> acc.type(:ordered_set)
          (:set, acc) -> acc.type(:set)
          ({:name, name}, acc) -> acc.name(name)
          (other, _) -> throw({:invalid_ets_option, other})
        end
    )
  end
  
  defp create_ttl_manager(ConCache[] = cache, options) do
    case options[:ttl_check] do
      ttl_check when is_integer(ttl_check) and ttl_check > 0 -> 
        {:ok, ttl_manager} = TtlManager.start_link(
          ttl_check: ttl_check,
          time_size: options[:time_size],
          on_expire: fn(key) ->
            isolated(cache, key, fn() -> do_delete(cache, key) end)
          end
        )
        cache.ttl_manager(ttl_manager)

      nil -> cache
    end
  end
  

  @spec isolated(t, key, job) :: result
  def isolated(ConCache[acquire_lock_timeout: acquire_lock_timeout] = cache, key, fun) do
    isolated(cache, key, acquire_lock_timeout, fun)
  end

  @spec isolated(t, key, timeout, job) :: result
  def isolated(ConCache[lock: lock], key, acquire_lock_timeout, fun) do
    BalancedLock.exec(lock, key, acquire_lock_timeout, fun)
  end
  
  @spec try_isolated(t, key, job) :: {:error, :locked} | result
  def try_isolated(ConCache[acquire_lock_timeout: acquire_lock_timeout] = cache, 
    key, on_success
  ) do
    try_isolated(cache, key, acquire_lock_timeout, on_success)
  end
  
  @spec try_isolated(t, key, timeout, job) :: {:error, :locked} | result
  def try_isolated(ConCache[lock: lock], key, acquire_lock_timeout, on_success) do
    case BalancedLock.try_exec(lock, key, acquire_lock_timeout, on_success) do
      {:lock, :not_acquired} -> {:error, :locked}
      response -> response
    end
  end

  
  @spec get(t, key) :: value
  def get(ConCache[ets: ets] = cache, key) do
    case :ets.lookup(ets, key) do
      [{^key, value}] -> 
        read_touch(cache, key)
        value
      _ -> nil
    end
  end

  defp read_touch(ConCache[touch_on_read: false], _), do: :ok
  defp read_touch(ConCache[touch_on_read: true] = cache, key) do
    touch(cache, key)
  end
  
  @spec get_all(t) :: [value]
  def get_all(ConCache[ets: ets]) do
    :ets.tab2list(ets)
  end

  @spec put(t, key, in_value) :: :ok
  def put(cache, key, value) do
    isolated(cache, key, fn() ->
      dirty_put(cache, key, value)
    end)
  end
  
  
  @spec insert_new(t, key, in_value) :: :ok | {:error, :already_exists}
  def insert_new(cache, key, value) do
    update(cache, key, &do_insert_new(value, &1))
  end
  
  @spec dirty_insert_new(t, key, in_value) :: :ok | {:error, :already_exists}
  def dirty_insert_new(cache, key, value) do
    dirty_update(cache, key, &do_insert_new(value, &1))
  end
  
  defp do_insert_new(value, nil), do: value
  defp do_insert_new(_, _), do: {:cancel_update, {:error, :already_exists}}

  @spec update(t, key, updater) :: :ok
  def update(cache, key, fun) do
    isolated(cache, key, fn() ->
      do_update(cache, key, fun.(get(cache, key)))
    end)
  end
  
  @spec dirty_update(t, key, updater) :: :ok
  def dirty_update(cache, key, fun) do
    do_update(cache, key, fun.(get(cache, key)))
  end
  
  @spec update_existing(t, key, updater) :: :ok | {:error, :not_existing}
  def update_existing(cache, key, fun) do
    isolated(cache, key, fn() ->
      dirty_update_existing(cache, key, fun)
    end)
  end
  
  @spec dirty_update_existing(t, key, updater) :: :ok | {:error, :not_existing}
  def dirty_update_existing(cache, key, fun) do
    with_existing(cache, key, fn(existing) ->
      do_update(cache, key, fun.(existing))
    end) || {:error, :not_existing}
  end

  defp do_update(_, _, {:cancel_update, return_value}) do
    return_value
  end

  defp do_update(cache, key, ConCacheItem[] = new_value) do
    dirty_put(cache, key, new_value)
  end
  
  defp do_update(cache, key, new_value) do
    do_update(cache, key, ConCacheItem.new(value: new_value, ttl: :renew))
  end
  
  @spec dirty_put(t, key, in_value) :: :ok
  def dirty_put(ConCache[ets: ets] = cache, key, ConCacheItem[ttl: ttl, value: value]) do
    set_ttl(cache, key, ttl)
    :ets.insert(ets, {key, value})
    invoke_callback(cache, {:update, cache, key, value})
    :ok
  end

  def dirty_put(ConCache[ttl: ttl] = cache, key, value) do
    dirty_put(cache, key, ConCacheItem.new(value: value, ttl: ttl))
  end
  
  defp set_ttl(ConCache[ttl_manager: nil], _, _), do: :ok
  defp set_ttl(ConCache[ttl_manager: ttl_manager], key, ttl) do
    TtlManager.set_ttl(ttl_manager, key, ttl)
  end
  
  defp clear_ttl(ConCache[ttl_manager: nil], _), do: :ok
  defp clear_ttl(ConCache[ttl_manager: ttl_manager], key) do
    TtlManager.clear_ttl(ttl_manager, key)
  end
  

  defp invoke_callback(ConCache[callback: nil], _), do: :ok
  defp invoke_callback(ConCache[callback: fun], data) when is_function(fun) do
    fun.(data)
  end

  @spec get_or_store(t, key, (() -> in_value)) :: value
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
  
  @spec dirty_get_or_store(t, key, (() -> in_value)) :: value
  def dirty_get_or_store(cache, key, fun) do
    case get(cache, key) do
      nil ->
        new_value = fun.()
        dirty_put(cache, key, new_value) 
        value(new_value)

      existing -> existing
    end
  end

  defp value(ConCacheItem[value: value]), do: value
  defp value(value), do: value

  @spec delete(t, key) :: :ok
  def delete(cache, key) do
    isolated(cache, key, fn() -> dirty_delete(cache, key) end)
  end
  
  @spec dirty_delete(t, key) :: :ok
  def dirty_delete(cache, key) do
    clear_ttl(cache, key)
    do_delete(cache, key)
  end
  
  defp do_delete(ConCache[ets: ets] = cache, key) do
    try do
      invoke_callback(cache, {:delete, cache, key})
    after
      :ets.delete(ets, key)
    end
    
    :ok
  end

  @spec with_existing(t, key, ((value) -> result)) :: nil | result
  def with_existing(cache, key, fun) do
    case get(cache, key) do
      nil -> nil
      existing -> fun.(existing)
    end
  end
  
  @spec touch(t, key) :: :ok
  def touch(cache, key) do
    set_ttl(cache, key, :renew)
  end

  @spec size(t) :: integer
  def size(ConCache[ets: ets]) do
    :ets.info(ets, :size)
  end

  @spec memory(t) :: integer
  def memory(ConCache[ets: ets]) do
    :ets.info(ets, :memory)
  end

  @spec memory_bytes(t) :: integer
  def memory_bytes(cache), do: :erlang.system_info(:wordsize) * memory(cache)
end
