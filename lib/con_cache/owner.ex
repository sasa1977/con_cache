defmodule ConCache.Owner do
  use ExActor.Tolerant

  require Record
  Record.defrecordp :ets_options, name: :con_cache, type: :set, options: [:public]

  def cache({:local, local}) when is_atom(local), do: cache(local)
  def cache(local) when is_atom(local), do: ConCache.Registry.get(Process.whereis(local))
  def cache({:global, name}), do: cache({:via, :global, name})
  def cache({:via, module, name}), do: cache(module.whereis_name(name))
  def cache(pid) when is_pid(pid), do: ConCache.Registry.get(pid)

  definit options do
    ets = create_ets(options[:ets_options] || [])
    check_ets(ets)

    cache =
      %ConCache{
        owner_pid: self,
        ets: ets,
        ttl: options[:ttl] || 0,
        acquire_lock_timeout: options[:acquire_lock_timeout] || 5000,
        callback: options[:callback],
        touch_on_read: options[:touch_on_read] || false
      }
      |> create_ttl_manager(options)

    ConCache.Registry.register(cache)
    initial_state(cache)
  end

  defp create_ets(input_options) do
    ets_options(name: name, type: type, options: options) = parse_ets_options(input_options)
    :ets.new(name, [type | options])
  end

  defp parse_ets_options(input_options) do
    Enum.reduce(
      input_options,
      ets_options(),
        fn
          (:named_table, acc) -> append_option(acc, :named_table)
          (:compressed, acc) -> append_option(acc, :compressed)
          ({:heir, _} = opt, acc) -> append_option(acc, opt)
          ({:write_concurrency, _} = opt, acc) -> append_option(acc, opt)
          ({:read_concurrency, _} = opt, acc) -> append_option(acc, opt)
          (:ordered_set, acc) -> ets_options(acc, type: :ordered_set)
          (:set, acc) -> ets_options(acc, type: :set)
          ({:name, name}, acc) -> ets_options(acc, name: name)
          (other, _) -> throw({:invalid_ets_option, other})
        end
    )
  end

  defp append_option(ets_options(options: options) = ets_options, option) do
    ets_options(ets_options, options: [option | options])
  end

  defp check_ets(ets) do
    if (:ets.info(ets, :keypos) > 1), do: throw({:error, :invalid_keypos})
    if (:ets.info(ets, :protection) != :public), do: throw({:error, :invalid_protection})
    if (not (:ets.info(ets, :type) in [:set, :ordered_set])), do: throw({:error, :invalid_type})
  end

  defp create_ttl_manager(cache, options) do
    me = self
    case options[:ttl_check] do
      ttl_check when is_integer(ttl_check) and ttl_check > 0 ->
        {:ok, ttl_manager} = ConCache.TtlManager.start_link(
          ttl_check: ttl_check,
          time_size: options[:time_size],
          on_expire: &ConCache.delete(me, &1)
        )
        %ConCache{cache | ttl_manager: ttl_manager}

      nil -> cache
    end
  end
end