# ConCache

ConCache (Concurrent Cache) is an ETS based key/value storage with following additional features:
* row level isolated writes (inserts, read/modify/write updates, deletes)
* TTL support
* modification callbacks

## Usage

### Basic

```elixir
cache = ConCache.start_link
ConCache.put(cache, key, value)         # inserts value or overwrites the old one
ConCache.insert_new(cache, key, value)  # inserts value or returns {:error, :already_exists}
ConCache.get(cache, key)
ConCache.delete(cache, key)

ConCache.update(cache, key, fn(old_value) ->
  # This function is isolated on a row level. Modifications such as update, put, delete, 
  # on this key will wait for this function to finish. 
  # Modifications on other items are not affected.
  # Reads are always dirty.

  new_value
end)

# Similar to update, but executes provided function only if item exists. 
# Otherwise returns {:error, :not_existing}
ConCache.update_existing(cache, key, fn(old_value) ->
  new_value
end)


# Returns existing value, or calls function and stores the result. 
# If many processes simultaneously invoke this function for the same key, the function will be
# executed only once, with all others reading the value from cache.
ConCache.get_or_store(cache, key, fn() ->
  initial_value
end)


# Executes function only if item exists. The result is either the function's return value, or nil.
ConCache.with_existing(cache, key, fn() ->
  ...
end)
```

Dirty modifiers operate directly on ets record without trying to acquire the row lock:

```elixir
ConCache.dirty_put(cache, key, value)
ConCache.dirty_insert_new(cache, key, value)
ConCache.dirty_delete(cache, key)
ConCache.dirty_update(cache, key, fn(old_value) -> ... end)
ConCache.dirty_update_existing(cache, key, fn(old_value) -> ... end)
ConCache.dirty_get_or_store(cache, key, fn() -> ... end)
```

### Callback

You can register your own function which will be invoked after an element is stored or deleted:

```elixir
cache = ConCache.start_link(callback: fn(data) -> ... end)
    
ConCache.put(cache, key, value)         # fun will be called with {:update, cache, key, value}
ConCache.delete(cache, key)             # fun will be called with {:delete, cache, key}
```

The delete callback is invoked before the item is deleted, so you still have the chance to fetch the value from the cache and do something with it.

### TTL

```elixir
cache = ConCache.start_link(
  ttl_check: :timer.seconds(1), 
  ttl: :timer.seconds(5)
)
```

This example creates separate linked process which will check item expiry every second The default ttl for all cache items is 5 seconds. Since ttl_check is 1 second, the item lifetime might be at most 6 seconds.

The item lifetime is renewed on every modification. Reads don't extend ttl, but this can be changed when starting cache:

```elixir
cache = ConCache.start_link(
  ttl_check: :timer.seconds(1), 
  ttl: :timer.seconds(5),
  touch_on_read: true
)
```

In addition, you can manually renew item's ttl:

```elixir
ConCache.touch(cache, key)
```

And you can override ttl for each item:

```elixir
ConCache.put(cache, key, ConCacheItem.new(value: value, ttl: ttl))

ConCache.update(cache, key, fn(old_value) ->
  ConCacheItem.new(value: new_value, ttl: ttl)
end)
```

If you use ttl value of 0 the item never expires.
In addition, unless you set ttl_check interval, the ttl check process will not be started, and items will never expire.

TTL check __is not__ based on brute force table scan, and should work reasonably fast assuming the check interval is not too small. I generally recommend ttl_check to be at least 1 second, possibly more, depending on the cache size and desired ttl.

## Inner workings

### ETS table
The ets table is always public, and by default it is of _set_ type. Some ets parameters can be changed:

```elixir
ConCache.start_link(ets_options: [
  :named_table, 
  {:name, :test_name},
  :ordered_set,
  {:read_concurrency, true},
  {:write_concurrency, true},
  {:heir, heir_pid}
])
```

The allowed types are set and ordered_set.

Additionally, you can override con\_cache, and access ets directly:

```elixir
:ets.insert(ConCache.ets(cache), {key, value})
```

Of course, this completely overrides additional con\_cache behavior, such as ttl, row locking and callbacks.

### Processes

ConCache creates a couple of linked processes and returns a tuple containing corresponding pids, and some additional data. To put the structure under supervisor, I suggest a supervised parent process which will create the ConCache instance.

In my production system, I have one such process very high in the supervision tree. The ConCache instance is stored in the protected ets table accessible to every other process.

### Locking

To provide isolation, custom implementation of mutex is developed. This enables that each update operation is executed in the caller process, without the need to send data to another sync process.

When a modification operation is called, the ConCache first acquires the lock and then performs the operation. The acquiring is done using the pool of lock processes which are spawn\_linked when the cache is started. By default, the pool contains 10 processes (can be altered with the _lock\_balancers_ parameter).

If the lock is not acquired in a predefined time (default = 5 seconds, alter with _acquire\_lock\_timeout_ parameter) an exception will be generated.

You can use explicit isolation to perform isolated reads if needed. In addition, you can use your own lock ids to implement bigger granularity:

```elixir
ConCache.isolated(cache, key, fn() ->
  ConCache.get(cache, key)    # isolated read
end)

# Operation isolated on an arbitrary id. The id doesn't have to correspond to a cache item.
ConCache.isolated(cache, my_lock_id, fn() ->
  ...
end)

# Same as above, but immediately returns {:error, :locked} if lock could not be acquired.
ConCache.try_isolated(cache, my_lock_id, fn() ->
  ...
end)
```

Keep in mind that these calls are isolated, but not transactional (atomic). Once something is modified, it is stored in ets regardless of whether the remaining calls succeed or fail.
The isolation operations can be arbitrarily nested, although I wouldn't recommend this approach.

### TTL

When ttl is configured, ttl\_manager process is spawn linked. It works in discrete steps using :erlang.send\_after to trigger the next step. 

When an item ttl is set, ttl\_manager receives a message and stores it in its pending hash structure without doing anything else. Therefore, repeated touching of items is not very expensive.

In the next discrete step, ttl\_manager first applies the pending ttl set requests to its internal state. Then it checks which items must expire at this step, purges them, and calls :erlang.send_after to trigger the next step.

This approach allows ttl manager to do fairly small amount of work in each discrete step.

### Consqeuences

Due to the locking and ttl algorithms just described, some additional processing will occur in ConCache internal processes. The work is fairly optimized, but I didn't invest too much time in it.
For example, lock processes currently use pure functional structures such as HashDict, :gb_trees and :sets. This could probably be replaced with internal ets table to make it work faster, but I didn't try it.

Due to lock and ttl inner workings, multiple copies of each key exist in memory. Therefore, I recommend avoiding complex keys.

## Components

The library contains three modules Lock, BalancedLock and TtlManager which are building blocks for ConCache facilities. These modules are fairly generic, and you can use them in different contexts, independent of ConCache.

## Status

I use ConCache in production to manage several thousands of entries served to up to 4000 concurrent clients, on the load of up to 2000 reqs/sec.
