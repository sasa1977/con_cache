defmodule ConCache.BalancedLock do
  @moduledoc false
  import Supervisor.Spec

  def start_link do
    Supervisor.start_link(
      Enum.map(1..size, &lock_worker_spec/1),
      name: :con_cache_balanced_lock,
      strategy: :one_for_one
    )
  end

  def exec(id, timeout \\ 5000, fun) do
    ConCache.Lock.exec(lock_pid(id), id, timeout, fun)
  end

  def try_exec(id, timeout \\ 5000, fun) do
    ConCache.Lock.try_exec(lock_pid(id), id, timeout, fun)
  end


  defp lock_worker_spec(index) do
    worker(ConCache.Lock, [nil, [name: worker_alias(index)]], id: worker_alias(index))
  end

  defp worker_alias(index), do: :"con_cache_lock_worker_#{index}"

  defp lock_pid(id), do: Process.whereis(worker_alias(:erlang.phash2(id, size) + 1))

  defp size, do: :erlang.system_info(:schedulers)
end