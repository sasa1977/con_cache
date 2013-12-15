defmodule BalancedLock do
  @type t :: KeyBalancer.t
  @type key :: KeyBalancer.key
  @type result :: any
  @type job :: (() -> result)
  
  @spec start_link(pos_integer) :: t
  def start_link(size) do
    KeyBalancer.new(size, fn() -> 
      {:ok, lock} = Lock.start_link
      lock 
    end)
  end

  def stop(balancer) do
    KeyBalancer.each(balancer, &Lock.stop/1)
  end

  @spec exec(t, key, job) :: result
  @spec exec(t, key, timeout, job) :: result
  def exec(balancer, id, timeout // 5000, fun) do
    KeyBalancer.exec(balancer, id, fn(server) ->
      Lock.exec(server, id, timeout, fun)
    end)
  end

  @spec try_exec(t, key, job) :: result
  @spec try_exec(t, key, timeout, job) :: result
  def try_exec(balancer, id, timeout // 5000, fun) do
    KeyBalancer.exec(balancer, id, fn(server) ->
      Lock.try_exec(server, id, timeout, fun)
    end)
  end
end