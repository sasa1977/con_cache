defmodule ConCache.Application do
  @moduledoc false

  use Application
  import Supervisor.Spec

  def start(_, _) do
    Supervisor.start_link(
      [
        supervisor(Registry, [:unique, ConCache])
      ],
      strategy: :one_for_all
    )
  end
end
