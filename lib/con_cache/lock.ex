defmodule ConCache.Lock do
  @moduledoc false

  alias ConCache.Lock.Resource
  alias ConCache.Lock.Monitors

  @type key :: any
  @type result :: any
  @type job :: (() -> result)

  defstruct resources: Map.new, monitors: Monitors.new

  use ExActor.Tolerant

  @spec start :: {:ok, pid}
  @spec start_link :: {:ok, pid}

  defstart start(initial_state \\ nil), gen_server_opts: :runtime
  defstart start_link(initial_state \\ nil), gen_server_opts: :runtime do
    initial_state(initial_state || %__MODULE__{})
  end

  defcast stop, do: stop_server(:normal)

  @spec exec(pid | atom, key, timeout, job) :: result
  @spec exec(pid | atom, key, job) :: result
  def exec(server, id, timeout \\ 5000, fun) do
    lock_instance = make_ref()
    try do
      :acquired = lock(server, id, lock_instance, timeout)
      fun.()
    after
      unlock(server, id, lock_instance, self())
    end
  end

  @spec try_exec(pid | atom, key, job) :: result | {:lock, :not_acquired}
  @spec try_exec(pid | atom, key, timeout, job) :: result | {:lock, :not_acquired}
  def try_exec(server, id, timeout \\ 5000, fun) do
    lock_instance = make_ref()
    try do
      case try_lock(server, id, lock_instance, timeout) do
        :acquired -> fun.()
        :not_acquired -> {:lock, :not_acquired}
      end
    after
      unlock(server, id, lock_instance, self())
    end
  end

  defcallp try_lock(id, lock_instance), from: {caller_pid, _} = from, state: state, timeout: timeout do
    resource = resource(state, id)
    if Resource.can_lock?(resource, caller_pid) do
      add_resource_owner(state, id, lock_instance, resource, from)
    else
      reply(:not_acquired)
    end
  end

  defcallp lock(id, lock_instance), from: from, state: state, timeout: timeout do
    add_resource_owner(state, id, lock_instance, resource(state, id), from)
  end

  defp add_resource_owner(state, id, lock_instance, resource, {caller_pid, _} = from) do
    state
    |> inc_monitor_ref(caller_pid, lock_instance)
    |> handle_resource_change(id, Resource.inc_lock(resource, lock_instance, caller_pid, from))
    |> new_state
  end


  defcastp unlock(id, lock_instance, caller_pid), state: state do
    state
    |> dec_monitor_ref(caller_pid, lock_instance)
    |> handle_resource_change(id, Resource.dec_lock(resource(state, id), lock_instance, caller_pid))
    |> new_state
  end


  defp handle_resource_change(state, id, resource_change_result) do
    resource = maybe_notify_caller(resource_change_result)
    store_resource(state, id, resource)
  end

  defp maybe_notify_caller({:not_acquired, resource}), do: resource
  defp maybe_notify_caller({{:acquired, from}, resource}) do
    if Process.alive?(Resource.owner(resource)) do
      GenServer.reply(from, :acquired)
      resource
    else
      remove_caller_from_resource(resource, Resource.owner(resource))
    end
  end

  defp remove_caller_from_resource(resource, caller_pid) do
    resource
    |> Resource.remove_caller(caller_pid)
    |> maybe_notify_caller
  end

  defp remove_caller_from_all_resources(%__MODULE__{resources: resources} = state, caller_pid) do
    Enum.reduce(resources, state,
      fn({id, resource}, state_acc) ->
        store_resource(
          state_acc,
          id,
          remove_caller_from_resource(resource, caller_pid)
        )
      end
    )
  end

  defp resource(%__MODULE__{resources: resources}, id) do
    case Map.fetch(resources, id) do
      {:ok, resource} -> resource
      :error -> Resource.new
    end
  end

  defp store_resource(%__MODULE__{resources: resources} = state, id, resource) do
    if Resource.empty?(resource) do
      %__MODULE__{state | resources: Map.delete(resources, id)}
    else
      %__MODULE__{state | resources: Map.put(resources, id, resource)}
    end
  end


  defp inc_monitor_ref(%__MODULE__{monitors: monitors} = state, caller_pid, lock_instance) do
    %__MODULE__{state | monitors: Monitors.inc_ref(monitors, caller_pid, lock_instance)}
  end

  defp dec_monitor_ref(%__MODULE__{monitors: monitors} = state, caller_pid, lock_instance) do
    %__MODULE__{state | monitors: Monitors.dec_ref(monitors, caller_pid, lock_instance)}
  end

  defp unmonitor(%__MODULE__{monitors: monitors} = state, caller_pid) do
    %__MODULE__{state | monitors: Monitors.remove(monitors, caller_pid)}
  end

  defhandleinfo {:DOWN, _, _, caller_pid, _}, state: state do
    state
    |> unmonitor(caller_pid)
    |> remove_caller_from_all_resources(caller_pid)
    |> new_state
  end

  defhandleinfo _, do: noreply()
end
