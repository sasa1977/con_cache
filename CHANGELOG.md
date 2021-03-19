# Changelog

## 1.0

- no new changes from 0.14.0

## 0.14.0

- Requires Elixir 1.7 or newer
- Added `fetch_or_store/3` and `dirty_fetch_or_store/3`

## 0.13.1

- removed a few compiler warnings

## 0.13.0

### Breaking changes

- Requires Elixir 1.5 or newer
- The `ConCache.start_link` function takes only one argument. Previously, you needed to pass two keyword lists, which have now been unified in a single kw list. See `ConCache.start_link/1` for details.
- The `ConCache.start_link` parameters `:ttl_check` and `:ttl` are renamed to `:ttl_check_interval` and `:global_ttl`.
- The `:ttl_check_interval` parameter is now required. If you don't want expiry in your cache, you need to explicitly pass `ttl_check_interval: false`.
- If the `:ttl_check_interval` option is set to a positive integer, you also need to pass the `:global_ttl` option.
- If a cache is configured for expiry, but you want some item to not expire, you need to pass the atom `:infinity` as its TTL value (previously, it was 0).

### Improvements

- Added `child_spec/1`. A `ConCache` child can now be specified as `{ConCache, [name: :my_cache, ttl_check_interval: false]}`.

## 0.12.1

- Relaxed version requirement for Elixir
- Proper early exit when the cache doesn't exist

## 0.12.0

### Breaking changes

- Elixir 1.4 is now required.
- The process started through `ConCache.start_link` is a supervisor (previously it was a worker). Make sure to adapt your supervisor specifications accordingly.
- `ConCache.start` has been removed.

### Improvements

- You can now use `bag`, and `duplicate_bag` (thanks to [fcevado](https://github.com/fcevado) for implementing it).
- Lock processes are now specific for each cache instance (previously they were shared between all of them). Multiple cache instances in the same system will not block each other.

## 0.11.1

- Fix warnings on 1.3.0

## 0.11.0

### Improvements
- Support the avoiding prolongation of ttls when updated items through the `:no_update` ttl value in `%ConCache.Item{}`

### Fixes

- New items inserted with `ConCache.update/3` and `ConCache.dirty_update/3` never expired.

## 0.10.0

### Improvements
- add `ConCache.size/1`

## 0.9.0

### Fixes
- Support for Elixir 1.1

## 0.8.1

### Fixes
- Proper unlocking of an item. Previously it was possible that a process keeps the resource locked forever if the lock attempt timed out.

## 0.8.0

### Breaking changes
- Removed following `ConCache` functions: `size/1`, `memory/1`, `memory_bytes/1`, `get_all/1`, `with_existing/3`
- Changed `ConCache` update functions: `update/3`, `dirty_update/3`, `update_existing/3` and `dirty_update_existing/3`. The provided lambda now must return either `{:ok, new_value}` or `{:error, reason}`.
- Changed `ConCache.try_isolated/4` - the function returns `{:ok, result}` or `{:error, reason}`
- Upgraded to the most recent ExActor

### Fixes
- Fixed possible race-conditions on client process crash
- Fixed mutual exclusion of independent caches

## 0.6.1
- Elixir v1.0.0

## 0.5.1
- bugfix: balanced lock wasn't working properly

## 0.5.0
- upgrade to Elixir v1.0.0-rc1

## 0.4.0
- upgrade to Elixir v0.15.0

## 0.3.0

With this version, ConCache is turned into a proper application that obeys OTP principles. This required some changes to the way ConCache is used.

First, ConCache is now an OTP application. Consequently, you should add it as an **application dependency** in your `mix.exs`:

```elixir
  ...

  def application do
    [applications: [:con_cache, ...], ...]
  end

  ...
```

This will make sure that before your app is started, ConCache required processes are started as well.

To create a cache, you can use `ConCache.start_link/0,1,2` or `ConCache.start/0,1,2`. These functions now return result in the form of `{:ok, pid}` where `pid` identifies the owner process of the underlying ETS table. You can use that pid as the first argument to exported functions from `ConCache` module.

The first argument to both functions must contain ConCache options (unchanged), while the second argument contains [`GenServer` start options](http://elixir-lang.org/docs/stable/elixir/GenServer.html#t:options/0). Both are by default empty lists.

The cache owner process **is not** inserted into the supervision tree of the ConCache OTP application. It is your responsibility to place it in your own tree at the desired place.

Of course, when using supervision, you can't use the ETS owner process pid to interface the cache, since this process can be restarted. Instead, you must rely on some registration facility. For example, this is how you can locally register the owner process, and use the alias to interface with the cache:

```elixir
# Specifying the alias of the ETS owner process
iex(1)> ConCache.start_link([], name: :my_cache)

# Interfacing the cache via the registered alias
iex(2)> ConCache.put(:my_cache, :some_key, :some_value)
iex(3)> ConCache.get(:my_cache, :some_key)
:some_value
```

When creating the cache from the supervision tree, use something like this in your specification:

```elixir
worker(ConCache, [con_cache_options, [name: ...]])
```

And then interface the cache via the corresponding alias.

Besides this simple local registration, you can also use `{:global, some_alias}`, and `{:via, module, some_alias}` format. For example, to register the process with [gproc](https://github.com/uwiger/gproc), you can do something like this:

```elixir
ConCache.start_link([], name: {:via, :gproc, :my_cache})
...
ConCache.put({:via, :gproc, :my_cache}, :some_key, :some_value)
```
