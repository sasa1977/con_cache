defmodule ConCache.Lock.Monitors do
  @moduledoc false

  defstruct processes: HashDict.new

  def new, do: %__MODULE__{}

  def inc_ref(%__MODULE__{processes: processes} = monitors, pid) do
    process_info = case HashDict.fetch(processes, pid) do
      :error -> %{count: 1, monitor: Process.monitor(pid)}
      {:ok, process_info} -> %{process_info | count: process_info.count + 1}
    end

    %__MODULE__{monitors | processes: HashDict.put(processes, pid, process_info)}
  end

  def dec_ref(%__MODULE__{processes: processes} = monitors, pid) do
    case HashDict.fetch(processes, pid) do
      :error -> monitors

      {:ok, %{count: 1, monitor: monitor}} ->
        Process.demonitor(monitor)
        %__MODULE__{monitors | processes: HashDict.delete(processes, pid)}

      {:ok, %{count: count} = process_info} ->
        %__MODULE__{monitors | processes: HashDict.put(processes, pid, %{process_info | count: count - 1})}
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