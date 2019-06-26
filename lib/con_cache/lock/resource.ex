defmodule ConCache.Lock.Resource do
  @moduledoc false

  defstruct(
    owner: nil,
    count: 0,
    pending_owners: :queue.new(),
    pending_values: Map.new(),
    lock_instances: MapSet.new()
  )

  def new, do: %__MODULE__{}

  def owner(%__MODULE__{owner: owner}), do: owner

  def empty?(%__MODULE__{owner: nil, pending_values: pending_values}) do
    map_size(pending_values) == 0
  end

  def empty?(_), do: false

  def can_lock?(%__MODULE__{owner: pid}, pid), do: true
  def can_lock?(resource, _), do: empty?(resource)

  def inc_lock(
        %__MODULE__{owner: pid, count: count, lock_instances: lock_instances} = resource,
        lock_instance,
        pid,
        value
      ) do
    {
      {:acquired, value},
      %__MODULE__{
        resource
        | count: count + 1,
          lock_instances: MapSet.put(lock_instances, lock_instance)
      }
    }
  end

  def inc_lock(
        %__MODULE__{
          pending_owners: pending_owners,
          pending_values: pending_values,
          lock_instances: lock_instances
        } = resource,
        lock_instance,
        pid,
        value
      ) do
    acquire_next(%__MODULE__{
      resource
      | pending_owners: :queue.in(pid, pending_owners),
        pending_values: Map.put(pending_values, pid, value),
        lock_instances: MapSet.put(lock_instances, lock_instance)
    })
  end

  defp acquire_next(
         %__MODULE__{owner: nil, pending_owners: pending_owners, pending_values: pending_values} =
           resource
       ) do
    case :queue.out(pending_owners) do
      {:empty, _} ->
        {:not_acquired, resource}

      {{:value, pid}, pending_owners} ->
        {value, pending_values} = Map.pop(pending_values, pid)

        {{:acquired, value},
         %__MODULE__{
           resource
           | owner: pid,
             count: 1,
             pending_owners: pending_owners,
             pending_values: pending_values
         }}
    end
  end

  defp acquire_next(%__MODULE__{} = resource) do
    {:not_acquired, resource}
  end

  def dec_lock(%__MODULE__{lock_instances: lock_instances} = resource, lock_instance, pid) do
    if MapSet.member?(lock_instances, lock_instance) do
      %{resource | lock_instances: MapSet.delete(lock_instances, lock_instance)}
      |> dec_owner_lock(pid)
      |> release_pending(pid)
      |> acquire_next
    else
      {:not_acquired, resource}
    end
  end

  defp dec_owner_lock(%__MODULE__{owner: pid, count: 1} = resource, pid) do
    %__MODULE__{resource | owner: nil, count: 0}
  end

  defp dec_owner_lock(%__MODULE__{owner: pid, count: count} = resource, pid)
       when count > 1 do
    %__MODULE__{resource | owner: pid, count: count - 1}
  end

  defp dec_owner_lock(resource, _), do: resource

  def remove_caller(resource, pid) do
    resource
    |> release_owner(pid)
    |> release_pending(pid)
    |> acquire_next
  end

  defp release_owner(%__MODULE__{owner: pid} = resource, pid) do
    %__MODULE__{resource | owner: nil, count: 0}
  end

  defp release_owner(resource, _), do: resource

  defp release_pending(
         %__MODULE__{pending_owners: pending_owners, pending_values: pending_values} = resource,
         pid
       ) do
    if Map.has_key?(pending_values, pid) do
      %__MODULE__{
        resource
        | pending_owners: :queue.filter(&(&1 !== pid), pending_owners),
          pending_values: Map.delete(pending_values, pid)
      }
    else
      resource
    end
  end
end
