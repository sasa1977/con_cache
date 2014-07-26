defmodule ConCache.Item do
  defstruct value: nil, ttl: 0
end

defmodule ConCache do
  defstruct [
    :owner_pid, :ets, :ttl_manager, :ttl, :acquire_lock_timeout, :callback, :touch_on_read
  ]

  def start_link(options \\ []) do
    ConCache.Owner.start_link(options)
  end

  def start(options \\ []) do
    ConCache.Owner.start(options)
  end

  operations = [
    ets: 1,
    isolated: 3,
    isolated: 4,
    try_isolated: 3,
    try_isolated: 4,
    get: 2,
    get_all: 1,
    put: 3,
    insert_new: 3,
    dirty_insert_new: 3,
    update: 3,
    dirty_update: 3,
    update_existing: 3,
    dirty_update_existing: 3,
    dirty_put: 3,
    get_or_store: 3,
    dirty_get_or_store: 3,
    delete: 2,
    dirty_delete: 2,
    with_existing: 3,
    touch: 2,
    size: 1,
    memory: 1,
    memory_bytes: 1
  ]

  for {name, arity} <- operations do
    [cache | rest] = args = Enum.map(1..arity, &Macro.var(:"arg#{&1}", __MODULE__))
    def unquote(name)(unquote_splicing(args)) do
      ConCache.Operations.unquote(name)(unquote_splicing([quote(do: ConCache.Owner.cache(unquote(cache))) | rest]))
    end
  end
end