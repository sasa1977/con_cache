defmodule ConCache.Application do
  use Application
  import Supervisor.Spec

  def start(_, _) do
    ConCache.Registry.create
    Supervisor.start_link(
      [supervisor(ConCache.BalancedLock, [])], strategy: :one_for_one
    )
  end
end