defmodule ConCache.Item do
  @moduledoc """
  This struct can be used in place of naked values to set per-item TTL values.
  """
  defstruct value: nil, ttl: 0
  @type t :: %ConCache.Item{value: ConCache.value, ttl: pos_integer}
end

defmodule ConCache do
  @moduledoc """
  Implements an ETS based key/value storage with following additional features:

  - row level synchronized writes (inserts, read/modify/write updates, deletes)
  - TTL support
  - modification callbacks

  Example usage:

      ConCache.start_link([], name: :my_cache)
      ConCache.put(:my_cache, :foo, 1)
      ConCache.get(:my_cache, :foo)  # 1

  The following rules apply:

  - Modifications are by isolated per row. Two processes can't modify the same
    row at the same time. Dirty operations are available through `dirty_` equivalents.
  - Reads are dirty by default. You can use `isolated/4` to perform isolated custom
    operations.
  - Operations are always performed in the caller process. Custom lock implementation
    is used to ensure synchronism. See `README.md` for more details.
  - By default, items don't expire. You can change this with `:ttl` and `:ttl_check`
    options.
  - Expiry of an item is by default extended only on modifications. This can be changed
    while starting the cache.
  - In all store operations, you can use `ConCache.Item` struct instead of naked values,
    if you need fine-grained control of item's TTL.

  See `start_link/2` for more details.
  """

  import ConCache.Helper

  defstruct [
    :owner_pid, :ets, :ttl_manager, :ttl, :acquire_lock_timeout, :callback, :touch_on_read
  ]

  @type t :: pid | atom | {:global, any} | {:via, atom, any}

  @type key :: any
  @type value :: any
  @type store_value :: value | ConCache.Item.t

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
  @type update_fun :: ((value) -> store_value | {:cancel_update, cancel_reason})

  @type store_fun :: (() -> store_value)

  @doc """
  Starts the server and creates an ETS table.

  Options:
    - `:set` - An ETS table will be of the `:set` type (default).
    - `:ordered_set` - An ETS table will be of the `:ordered_set` type.
    - `{:ttl_check, time_ms}` - A check interval for TTL expiry. This value is
      by default `nil` and you need to provide a positive integer for TTL to work.
      See below for more details on inner workings of TTL.
    - `{:ttl, time_ms}` - The default time after which an item expires.
      When an item expires, it is removed from the cache. Updating the item
      extends its expiry time. By default, items never expire.
    - `{:touch_on_read, true | false}` - Controls whether read operation extends
      expiry of items. False by default.
    - `{:callback, callback_fun}` - If provided, this function is invoked __after__
      an item is inserted or updated, or __before__ it is deleted.
    - `{:acquire_lock_timeout, timeout_ms}` - The time a client process waits for
      the lock. Default is 5000.

  In addition, following ETS options are supported:
    - `:named_table`
    - `:name`
    - `:heir`
    - `:write_concurrency`
    - `:read_concurrency`

  ## Choosing ttl_check time

  When TTL is configured, the owner process works in discrete steps, doing
  cleanups every `ttl_check_time` milliseconds. This approach allows the owner
  process to do fairly small amount of work in each discrete step.

  Assuming there's no huge system overload, an item's max lifetime is thus
  `ttl_time + ttl_check_time` [ms], after the last item's update.

  Thus, lower value of ttl_check time means more frequent purging which may
  reduce your memory consumption, but could also cause performance penalties.
  Higher values put less pressure on processing, but item expiry is less precise.
  """
  @spec start_link(options, GenServer.options) :: GenServer.on_start
  def start_link(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start_link(options, gen_server_options)
  end

  @doc """
  Starts the server.

  See `start_link/2` for more details.
  """
  @spec start(options, GenServer.options) :: GenServer.on_start
  def start(options \\ [], gen_server_options \\ []) do
    ConCache.Owner.start(options, gen_server_options)
  end

  @doc """
  Returns the ets table managed by the cache.
  """
  @spec ets(t) :: :ets.tab
  defcacheop ets(cache)

  @doc """
  Reads the item from the cache.

  A read is always "dirty", meaning it doesn't block while someone is updating
  the item under the same key. A read doesn't expire TTL of the item, unless
  `touch_on_read` option is set while starting the cache.
  """
  @spec get(t, key) :: value
  defcacheop get(cache, key)

  @doc """
  Stores the item into the cache.
  """
  @spec put(t, key, store_value) :: :ok
  defcacheop put(cache, key, value)

  @doc """
  Dirty equivalent of `put/3`.
  """
  @spec dirty_put(t, key, store_value) :: :ok
  defcacheop dirty_put(cache, key, value)

  @doc """
  Inserts the item into the cache unless it exists.
  """
  @spec insert_new(t, key, store_value) :: :ok | {:error, :already_exists}
  defcacheop insert_new(cache, key, value)

  @doc """
  Dirty equivalent of `insert_new/3`.
  """
  @spec dirty_insert_new(t, key, store_value) :: :ok | {:error, :already_exists}
  defcacheop dirty_insert_new(cache, key, value)

  @doc """
  Updates the item, or stores new item if it doesn't exist.

  The `update_fun` is invoked after the item is locked. Here, you can be certain
  that no other process will update this item, unless they are doing dirty updates
  or writing directly to the underlying ETS table.

  The result of the updated lambda is stored into the table, unless it is in form of
  `{:cancel_update, cancel_reason}`.
  """
  @spec update(t, key, update_fun) :: :ok | cancel_reason
  defcacheop update(cache, key, update_fun)

  @doc """
  Dirty equivalent of `update/3`.
  """
  @spec dirty_update(t, key, update_fun) :: :ok | cancel_reason
  defcacheop dirty_update(cache, key, update_fun)

  @doc """
  Updates the item only if it exists. Otherwise works just like `update/3`.
  """
  @spec update_existing(t, key, update_fun) :: :ok | {:error, :not_existing} | cancel_reason
  defcacheop update_existing(cache, key, update_fun)

  @doc """
  Dirty equivalent of `update_existing/3`.
  """
  @spec dirty_update_existing(t, key, update_fun) :: :ok | {:error, :not_existing} | cancel_reason
  defcacheop dirty_update_existing(cache, key, update_fun)

  @doc """
  Deletes the item from the cache.
  """
  @spec delete(t, key) :: :ok
  defcacheop delete(cache, key)

  @doc """
  Dirty equivalent of `delete/2`.
  """
  @spec dirty_delete(t, key) :: :ok
  defcacheop dirty_delete(cache, key)

  @doc """
  Retrieves the item from the cache, or inserts the new item.

  If the item exists in the cache, it is retrieved. Otherwise, the lambda
  function is executed and its result is stored under the given key.

  Note: if the item is already in the cache, this function amounts to a simple get
  without any locking, so you can expect it to be fairly fast.
  """
  @spec get_or_store(t, key, store_fun) :: value
  defcacheop get_or_store(cache, key, store_fun)

  @doc """
  Dirty equivalent of `get_or_store/3`.
  """
  @spec dirty_get_or_store(t, key, store_fun) :: value
  defcacheop dirty_get_or_store(cache, key, store_fun)

  @doc """
  Manually touches the item to prolongate its expiry.
  """
  @spec touch(t, key) :: :ok
  defcacheop touch(cache, key)

  @doc """
  Isolated execution over arbitrary lock in the cache.

  You can do whatever you want in the function, not necessarily related to the
  cache. The return value is the result of the provided lambda.

  This allows you to perform flexible isolation. If you use the key
  of your item as a `key`, then this operation will be exclusive to
  updates. This can be used e.g. to perform isolated reads:

      # Process A:
      ConCache.isolated(:my_cache, :my_item_key, fn() -> ... end)

      # Process B:
      ConCache.update(:my_cache, :my_item, fn(old_value) -> ... end)

  These two operations are mutually exclusive.
  """
  @spec isolated(t, key, nil | pos_integer, (() -> any)) :: any
  defcacheop isolated(cache, key, timeout \\ nil, fun)

  @doc """
  Similar to `isolated/4` except it doesn't wait for the lock to be available.

  If the lock can be acquired immediately, it will be acquired and the function
  will be invoked. Otherwise, an error is returned immediately.
  """
  @spec try_isolated(t, key, nil | pos_integer, (() -> any)) :: {:error, :locked} | any
  defcacheop try_isolated(cache, key, timeout \\ nil, on_success)
end