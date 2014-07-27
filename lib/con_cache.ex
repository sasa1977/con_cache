defmodule ConCache.Item do
  defstruct value: nil, ttl: 0
end

defmodule ConCache do
  import ConCache.Helper

  defstruct [
    :owner_pid, :ets, :ttl_manager, :ttl, :acquire_lock_timeout, :callback, :touch_on_read
  ]

  def start_link(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start_link(options, gen_server_options)
  end

  def start(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start(options, gen_server_options)
  end

  defcacheop ets(cache)
  defcacheop size(cache)
  defcacheop memory(cache)
  defcacheop memory_bytes(cache)
  defcacheop get(cache, key)
  defcacheop get_all(cache)
  defcacheop put(cache, key, value)
  defcacheop dirty_put(cache, key, value)
  defcacheop insert_new(cache, key, value)
  defcacheop dirty_insert_new(cache, key, value)
  defcacheop update(cache, key, update_fun)
  defcacheop dirty_update(cache, key, update_fun)
  defcacheop update_existing(cache, key, update_fun)
  defcacheop dirty_update_existing(cache, key, update_fun)
  defcacheop delete(cache, key)
  defcacheop dirty_delete(cache, key)
  defcacheop get_or_store(cache, key, store_fun)
  defcacheop dirty_get_or_store(cache, key, store_fun)
  defcacheop with_existing(cache, key, fun)
  defcacheop touch(cache, key)
  defcacheop isolated(cache, key, timeout \\ nil, fun)
  defcacheop try_isolated(cache, key, timeout \\ nil, on_success)
end