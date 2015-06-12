defmodule ConCache.Lock.Resource do
  @moduledoc false

  defstruct owner: nil, count: 0, pending_owners: :queue.new, pending_values: HashDict.new

  def new, do: %__MODULE__{}

  def owner(%__MODULE__{owner: owner}), do: owner

  def empty?(%__MODULE__{owner: nil, pending_values: pending_values}) do
    HashDict.size(pending_values) == 0
  end
  def empty?(_), do: false


  def can_lock?(%__MODULE__{owner: pid}, pid), do: true
  def can_lock?(resource, _), do: empty?(resource)

  def inc_lock(%__MODULE__{owner: pid, count: count} = resource, pid, value) do
    {{:acquired, value}, %__MODULE__{resource | count: count + 1}}
  end

  def inc_lock(
    %__MODULE__{pending_owners: pending_owners, pending_values: pending_values} = resource,
    pid,
    value
  ) do
    acquire_next(%__MODULE__{resource |
      pending_owners: :queue.in(pid, pending_owners),
      pending_values: HashDict.put(pending_values, pid, value)
    })
  end


  defp acquire_next(
    %__MODULE__{owner: nil, pending_owners: pending_owners, pending_values: pending_values} = resource
  ) do
    case :queue.out(pending_owners) do
      {:empty, _} -> {:not_acquired, resource}

      {{:value, pid}, pending_owners} ->
        {value, pending_values} = HashDict.pop(pending_values, pid)
        {{:acquired, value},
          %__MODULE__{resource |
            owner: pid,
            count: 1,
            pending_owners: pending_owners,
            pending_values: pending_values
          }
        }
    end
  end

  defp acquire_next(%__MODULE__{} = resource) do
    {:not_acquired, resource}
  end


  def dec_lock(resource, pid) do
    resource
    |> dec_owner_lock(pid)
    |> release_pending(pid)
    |> acquire_next
  end


  defp dec_owner_lock(%__MODULE__{owner: pid, count: n} = resource, pid) when n > 1 do
    %__MODULE__{resource | owner: pid, count: n - 1}
  end

  defp dec_owner_lock(%__MODULE__{owner: pid} = resource, pid) do
    %__MODULE__{resource | owner: nil, count: 0}
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
    if HashDict.has_key?(pending_values, pid) do
      %__MODULE__{resource |
        pending_owners: :queue.filter(&(&1 !== pid), pending_owners),
        pending_values: HashDict.delete(pending_values, pid)
      }
    else
      resource
    end
  end
end