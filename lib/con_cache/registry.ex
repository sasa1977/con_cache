defmodule ConCache.Registry do
  @moduledoc false

  use ExActor.Tolerant, export: :con_cache_registry

  defstart start_link do
    _ = :ets.new(:con_cache_registry, [:set, :named_table, {:read_concurrency, true}, :protected])
    initial_state(nil)
  end

  defcall register(cache) do
    :ets.insert(:con_cache_registry, {cache.owner_pid, cache})
    Process.monitor(cache.owner_pid)
    reply(:ok)
  end

  def get(pid) do
    [{^pid, cache}] = :ets.lookup(:con_cache_registry, pid)
    cache
  end

  defhandleinfo {:DOWN, _, :process, pid, _} do
    :ets.delete(:con_cache_registry, pid)
    noreply
  end

  defhandleinfo _, do: noreply
end