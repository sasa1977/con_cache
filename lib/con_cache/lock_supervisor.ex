defmodule ConCache.LockSupervisor do
  @moduledoc false

  def child_spec(n_partitions) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [n_partitions]},
      type: :supervisor
    }
  end

  def start_link(n_partitions) do
    Supervisor.start_link(
      Enum.map(
        1..n_partitions,
        &Supervisor.child_spec(ConCache.Lock, id: &1)
      ),
      strategy: :one_for_all,
      max_restarts: 1,
      name: {:via, Registry, {ConCache, {self(), __MODULE__}}}
    )
  end

  def lock_pids(parent_pid) do
    [{pid, _}] = Registry.lookup(ConCache, {parent_pid, __MODULE__})
    Enum.map(Supervisor.which_children(pid), fn {_, lock_pid, _, _} -> lock_pid end)
  end
end
