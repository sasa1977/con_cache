# ConCache

![Build Status](https://github.com/sasa1977/con_cache/workflows/con_cache/badge.svg?branch=master)
[![Module Version](https://img.shields.io/hexpm/v/con_cache.svg)](https://hex.pm/packages/con_cache)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/con_cache/)
[![Total Download](https://img.shields.io/hexpm/dt/con_cache.svg)](https://hex.pm/packages/con_cache)
[![License](https://img.shields.io/hexpm/l/con_cache.svg)](https://github.com/sasa1977/con_cache/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/sasa1977/con_cache.svg)](https://github.com/sasa1977/con_cache/commits/master)

ConCache (Concurrent Cache) is an ETS based key/value storage with following additional features:

- row level synchronized writes (inserts, read/modify/write updates, deletes)
- TTL support
- modification callbacks

## Usage in OTP applications

Setup project and app dependency in your `mix.exs`:

```elixir
  ...

  defp deps do
    [{:con_cache, "~> 0.13"}, ...]
  end

  def application do
    [applications: [:con_cache, ...], ...]
  end

  ...
```

A cache can be started using `ConCache.start` or `ConCache.start_link` functions. Both functions take two arguments - the first one being a list of ConCache options, and the second one a list of GenServer options for the process being started.

Typically you want to start the cache from a supervisor:

```elixir
Supervisor.start_link(
  [
    ...
    {ConCache, [name: :my_cache, ttl_check_interval: false]}
    ...
  ],
  ...
)
```

For OTP apps, you can generally find this in `lib/<myapp>.ex`. In the Phoenix web framework, look in the `start` function and add the worker to the `children` list.

Notice the `name: :my_cache` option. The resulting process will be registered under this alias. Now you can use the cache as follows:

```elixir
# Note: all of these requests run in the caller process, without going through
# the started process.

ConCache.put(:my_cache, key, value)         # inserts value or overwrites the old one
ConCache.insert_new(:my_cache, key, value)  # inserts value or returns {:error, :already_exists}
ConCache.get(:my_cache, key)
ConCache.delete(:my_cache, key)
ConCache.size(:my_cache)

ConCache.update(:my_cache, key, fn(old_value) ->
  # This function is isolated on a row level. Modifications such as update, put, delete,
  # on this key will wait for this function to finish.
  # Modifications on other items are not affected.
  # Reads are always dirty.

  {:ok, new_value}
end)

# Similar to update, but executes provided function only if item exists.
# Otherwise returns {:error, :not_existing}
ConCache.update_existing(:my_cache, key, fn(old_value) ->
  {:ok, new_value}
end)

# Returns existing value, or calls function and stores the result.
# If many processes simultaneously invoke this function for the same key, the function will be
# executed only once, with all others reading the value from cache.
ConCache.get_or_store(:my_cache, key, fn() ->
  initial_value
end)

# Similar to get_or_store/3 but works with :ok/:error tuples.
# The value is cached only if the function returns an :ok tuple.
ConCache.fetch_or_store(:my_cache, key, fn ->
  case call_api() do
    # The processed value will be cached and returned as an :ok tuple.
    {:ok, data} -> {:ok, process_data(data)}
    # The error tuple is propagated to the caller.
    {:error, _reason} = error -> error
  end
end)
```

Dirty modifiers operate directly on ETS record without trying to acquire the row lock:

```elixir
ConCache.dirty_put(:my_cache, key, value)
ConCache.dirty_insert_new(:my_cache, key, value)
ConCache.dirty_delete(:my_cache, key)
ConCache.dirty_update(:my_cache, key, fn(old_value) -> ... end)
ConCache.dirty_update_existing(:my_cache, key, fn(old_value) -> ... end)
ConCache.dirty_get_or_store(:my_cache, key, fn() -> ... end)
ConCache.dirty_fetch_or_store(:my_cache, key, fn() -> ... end)
```

### Callback

You can register your own function which will be invoked after an element is stored or deleted:

```elixir
{ConCache, [name: :my_cache, callback: fn(data) -> ... end]}

ConCache.put(:my_cache, key, value)         # fun will be called with {:update, cache_pid, key, value}
ConCache.delete(:my_cache, key)             # fun will be called with {:delete, cache_pid, key}
```

The delete callback is invoked before the item is deleted, so you still have the chance to fetch the value from the cache and do something with it.

### TTL

```elixir
{ConCache, [
  name: :my_cache,
  ttl_check_interval: :timer.seconds(1),
  global_ttl: :timer.seconds(5)
]}
```

This example sets up item expiry check every second, and sets the global expiry for all cache items to 5 seconds. Since ttl_check_interval is 1 second, the item lifetime might be at most 6 seconds.

However, the item lifetime is renewed on every modification. Reads don't extend global_ttl, but this can be changed when starting cache:

```elixir
{ConCache, [
  name: :my_cache,
  ttl_check_interval: :timer.seconds(1),
  global_ttl: :timer.seconds(5),
  touch_on_read: true
]}
```

In addition, you can manually renew item's ttl:

```elixir
ConCache.touch(:my_cache, key)
```

And you can override ttl for each item:

```elixir
ConCache.put(:my_cache, key, %ConCache.Item{value: value, ttl: ttl})

ConCache.update(:my_cache, key, fn(old_value) ->
  {:ok, %ConCache.Item{value: new_value, ttl: ttl}}
end)
```

And you can update an item without resetting the item's ttl:

```elixir
ConCache.put(:my_cache, key, %ConCache.Item{value: value, ttl: :no_update})

ConCache.update(:my_cache, key, fn(old_value) ->
  {:ok, %ConCache.Item{value: new_value, ttl: :no_update}}
end)
```

If you use ttl value of `:infinity` the item never expires.

TTL check **is not** based on brute force table scan, and should work reasonably fast assuming the check interval is not too small. I broadly recommend `ttl_check_interval` to be at least 1 second, possibly more, depending on the cache size and desired ttl.

If needed, you may also pass false to `ttl_check_interval`. This effectively stops `con_cache` from checking the ttl of your items:

```elixir
{ConCache, [
  name: :my_cache,
  ttl_check_interval: false
]}
```

## Supervision

A call to `ConCache.start_link` (or `start`) creates the so called _cache owner process_. This is the process that is the owner of the underlying ETS table and also the process where TTL checks are performed. No other operation (such as get or put) runs in this process.

As you've seen from the examples above, it's your responsibility to place the cache owner process into your own supervision tree. This gives you the control of cache cleanup when some subtree terminates (since a termination of the owner process will release the ETS table).

If for some reason `:con_cache` application is terminated, all cache owner processes will be terminated as well, regardless of the fact that they do not reside in the `:con_cache` supervision tree.

### Multiple caches

Sometimes it can be useful to run multiple caches - say, if you need 2 caches with different global expiry values. Even though you can override ttl for each
item individually, it might get tedious very quickly.

By default it's not possible to run multiple caches under the same supervisor because child specification of each cache owner process has `id` equal to `ConCache`.

However you can override default child specification and provide unique `id`:

```elixir
def start(_type, _args) do
  Supervisor.start_link(
    [
      ...
      con_cache_child_spec(:my_cache_1, 100),
      con_cache_child_spec(:my_cache_2, 200)
      ...
    ],
    ...
  )
end

defp con_cache_child_spec(name, global_ttl) do
  Supervisor.child_spec(
    {
      ConCache,
      [
        name: name,
        ttl_check_interval: :timer.seconds(1),
        global_ttl: :timer.seconds(global_ttl)
      ]
    },
    id: {ConCache, name}
  )
end
```

See [Supervisor.child_spec/2](https://hexdocs.pm/elixir/Supervisor.html#child_spec/2-examples) for details of this technique.

## Process alias

Functions `ConCache.start` and `ConCache.start_link` return standard `{:ok, pid}` result. You can interface with the cache using this pid. As mentioned, cache operations are not running through this process - the pid is just used to discover the corresponding ETS table.

Most of the time using pid to interface the cache is not appropriate. Just like in examples above, you usually want to give some alias to your cache, and then access it via this alias. In the examples above, we used `name: :some_alias` to provide local alias. Alternatively, you can use following formats for `name` option:

```elixir
{:global, some_alias}         # globally registered alias
{:via, module, some_alias}    # registered through some module (e.g. gproc)
```

In this case, you can just pass the same tuple to other `ConCache` functions. For example, to use the cache with [gproc](https://github.com/uwiger/gproc), you can do something like this:

```elixir
ConCache.start_link([], name: {:via, :gproc, :my_cache})
...
ConCache.put({:via, :gproc, :my_cache}, :some_key, :some_value)
```

## Testing in your application

Keep in mind that `ConCache` introduces a state to your system. Thus, when you're testing your application, some tests might accidentally compromise the execution of other tests. There are a couple of options to work around that:

1. Use different keys in each test. This could help avoiding tests compromising each other.
1. Before each test, force restart the `ConCache` process. This will ensure each test runs with the empty cache.

  ```elixir
  setup do
    Supervisor.terminate_child(con_cache_supervisor, ConCache)
    Supervisor.restart_child(con_cache_supervisor, ConCache)
    :ok
  end
  ```

  Where `con_cache_supervisor` is the supervisor from which the `ConCache` process is started.

3. Fetch all keys from the `ets` table, and delete each entry:

  ```elixir
  setup do
    :my_cache
    |> ConCache.ets
    |> :ets.tab2list
    |> Enum.each(fn({key, _}) -> ConCache.delete(:my_cache, key) end)

    :ok
  end
  ```

## Inner workings

### ETS table

The ETS table is always public, and by default it is of _set_ type. Some ETS parameters can be changed:

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

Additionally, you can override ConCache, and access ETS directly:

```elixir
:ets.insert(ConCache.ets(cache), {key, value})
```

Of course, this completely overrides additional ConCache behavior, such as ttl, row locking and callbacks.

#### Bag and Duplicate Bag

Those types are now supported by ConCache but like ETS, some functions are not supported by those types. Here are the list of functions **not** supported by bag and duplicate bag type tables:

- `update/3`
- `dirty_update/3`
- `update_existing/3`
- `dirty_update_existing/3`
- `get_or_store/3`
- `dirty_get_or_store/3`
- `fetch_or_store/3`
- `dirty_fetch_or_store/3`

### Locking

To provide isolation, custom implementation of mutex is developed. This enables that each update operation is executed in the caller process, without the need to send data to another sync process.

When a modification operation is called, the ConCache first acquires the lock and then performs the operation. The acquiring is done using the pool of lock processes that reside in the ConCache supervision tree. The pool contains as many processes as there are schedulers.

If the lock is not acquired in a predefined time (default = 5 seconds, alter with _acquire_lock_timeout_ ConCache parameter) an exception will be generated.

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

Keep in mind that these calls are isolated, but not transactional (atomic). Once something is modified, it is stored in ETS regardless of whether the remaining calls succeed or fail.
The isolation operations can be arbitrarily nested, although I wouldn't recommend this approach.

### TTL

When ttl is configured, the owner process works in discrete steps using `:erlang.send_after` to trigger the next step.

When an item ttl is set, the owner process receives a message and stores it in its internal structure without doing anything else. Therefore, repeated touching of items is not very expensive.

In the next discrete step, the owner process first applies the pending ttl set requests to its internal state. Then it checks which items must expire at this step, purges them, and calls `:erlang.send_after` to trigger the next step.

This approach allows the owner process to do fairly small amount of work in each discrete step.

### Consequences

Due to the locking and ttl algorithms just described, some additional processing will occur in the owner processes. The work is fairly optimized, but I didn't invest too much time in it.
For example, lock processes currently use pure functional structures such as `HashDict` and `:gb_trees`. This could probably be replaced with internal ETS table to make it work faster, but I didn't try it.

Due to locking and ttl inner workings, multiple copies of each key exist in memory. Therefore, I recommend avoiding complex keys.

## Status

ConCache has been used in production to manage several thousands of entries served to up to 4000 concurrent clients, on the load of up to 2000 reqs/sec. I don't maintain that project anymore, so I'm not aware of its current status.

## Copyright and License

Copyright (c) 2013 Saša Jurić

Released under the MIT License, which can be found in the repository in [`LICENSE`](https://github.com/sasa1977/con_cache/blob/master/LICENSE).
