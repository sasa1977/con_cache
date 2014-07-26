defmodule CacheRegistry do
  def create do
    :ets.new(:con_cache_registry, [:set, :named_table, {:read_concurrency, true}, :public])
  end

  def register(cache) do
    :ets.insert(:con_cache_registry, {self, cache})
  end

  def get(pid) do
    [{^pid, cache}] = :ets.lookup(:con_cache_registry, pid)
    cache
  end
end