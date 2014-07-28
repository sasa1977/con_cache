defmodule ConCache.Item do
  @moduledoc false
  defstruct value: nil, ttl: 0
end

defmodule ConCache do
  import ConCache.Helper

  defstruct [
    :owner_pid, :ets, :ttl_manager, :ttl, :acquire_lock_timeout, :callback, :touch_on_read
  ]

  @type t :: pid | atom | {:global, any} | {:via, atom, any}

  @type key :: any
  @type value :: any

  @type callback_fun :: (({:update, pid, key, value} | {:delete, pid, key}) -> any)

  @type ets_option ::
    :named_table | :compressed | {:heir, pid} |
    {:write_concurrency, boolean} | {:read_concurrency, boolean} |
    :ordered_set | :set | {:name, atom}

  @type options :: [
    {:ttl, non_neg_integer} |
    {:acquire_lock_timeout, pos_integer} |
    {:callback, callback_fun} |
    {:touch_on_read, boolean} |
    {:ttl_check, non_neg_integer} |
    {:time_size, pos_integer} |
    {:ets_options, [ets_option]}
  ]

  @type cancel_reason :: any
  @type update_fun :: ((value) -> value | {:cancel_update, cancel_reason})

  @type store_fun :: (() -> value)

  @spec start_link(options, GenServer.options) :: GenServer.on_start
  def start_link(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start_link(options, gen_server_options)
  end

  @spec start(options, GenServer.options) :: GenServer.on_start
  def start(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start(options, gen_server_options)
  end

  @spec ets(t) :: :ets.tab
  defcacheop ets(cache)

  @spec size(t) :: pos_integer
  defcacheop size(cache)

  @spec memory(t) :: pos_integer
  defcacheop memory(cache)

  @spec memory_bytes(t) :: pos_integer
  defcacheop memory_bytes(cache)

  @spec get(t, key) :: value
  defcacheop get(cache, key)

  @spec get_all(t) :: [{key, value}]
  defcacheop get_all(cache)

  @spec put(t, key, value) :: :ok
  defcacheop put(cache, key, value)

  @spec dirty_put(t, key, value) :: :ok
  defcacheop dirty_put(cache, key, value)

  @spec insert_new(t, key, value) :: :ok | {:error, :already_exists}
  defcacheop insert_new(cache, key, value)

  @spec dirty_insert_new(t, key, value) :: :ok | {:error, :already_exists}
  defcacheop dirty_insert_new(cache, key, value)

  @spec update(t, key, update_fun) :: :ok | cancel_reason
  defcacheop update(cache, key, update_fun)

  @spec dirty_update(t, key, update_fun) :: :ok | cancel_reason
  defcacheop dirty_update(cache, key, update_fun)

  @spec update_existing(t, key, update_fun) :: :ok | {:error, :not_existing} | cancel_reason
  defcacheop update_existing(cache, key, update_fun)

  @spec dirty_update_existing(t, key, update_fun) :: :ok | {:error, :not_existing} | cancel_reason
  defcacheop dirty_update_existing(cache, key, update_fun)

  @spec delete(t, key) :: :ok
  defcacheop delete(cache, key)

  @spec dirty_delete(t, key) :: :ok
  defcacheop dirty_delete(cache, key)

  @spec get_or_store(t, key, store_fun) :: value
  defcacheop get_or_store(cache, key, store_fun)

  @spec dirty_get_or_store(t, key, store_fun) :: value
  defcacheop dirty_get_or_store(cache, key, store_fun)

  @spec with_existing(t, key, ((value) -> any)) :: any
  defcacheop with_existing(cache, key, fun)

  @spec touch(t, key) :: :ok
  defcacheop touch(cache, key)

  @spec isolated(t, key, nil | pos_integer, (() -> any)) :: any
  defcacheop isolated(cache, key, timeout \\ nil, fun)

  @spec try_isolated(t, key, nil | pos_integer, (() -> any)) :: any
  defcacheop try_isolated(cache, key, timeout \\ nil, on_success)
end