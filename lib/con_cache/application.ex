defmodule ConCache.Application do
  @moduledoc false

  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {Registry, [keys: :unique, name: ConCache]}
      ],
      strategy: :one_for_all
    )
  end
end
