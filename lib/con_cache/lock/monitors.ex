defmodule ConCache.Lock.Monitors do
  @moduledoc false

  defstruct processes: HashDict.new

  def new, do: %__MODULE__{}

  def inc_ref(%__MODULE__{processes: processes} = monitors, pid, lock_instance) do
    process_info = case HashDict.fetch(processes, pid) do
      :error ->
        %{
          count: 1,
          monitor: Process.monitor(pid),
          lock_instances: Enum.into([lock_instance], HashSet.new)
        }

      {:ok, process_info} ->
        %{process_info |
          count: process_info.count + 1,
          lock_instances: HashSet.put(process_info.lock_instances, lock_instance)
        }
    end

    %__MODULE__{monitors | processes: HashDict.put(processes, pid, process_info)}
  end

  def dec_ref(%__MODULE__{processes: processes} = monitors, pid, lock_instance) do
    case HashDict.fetch(processes, pid) do
      :error -> monitors

      {:ok, %{lock_instances: lock_instances} = process_info} ->
        if HashSet.member?(lock_instances, lock_instance) do
          case process_info do
            %{count: 1, monitor: monitor} ->
              Process.demonitor(monitor)
              %__MODULE__{monitors | processes: HashDict.delete(processes, pid)}

            %{count: count} ->
              %__MODULE__{monitors |
                processes: HashDict.put(processes, pid,
                  %{process_info |
                    count: count - 1,
                    lock_instances: HashSet.delete(lock_instances, lock_instance)
                  }
                )
              }
          end
        else
          monitors
        end
    end
  end

  def remove(%__MODULE__{processes: processes} = monitors, pid) do
    case HashDict.fetch(processes, pid) do
      :error -> monitors

      {:ok, %{monitor: monitor}} ->
        Process.demonitor(monitor)
        %__MODULE__{monitors | processes: HashDict.delete(processes, pid)}
    end
  end
end