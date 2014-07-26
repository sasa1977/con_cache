defmodule LockTest do
  use ExUnit.Case, async: true

  test "basic" do
    assert conduct_test({Lock, Lock.start_link}) == [{0,18},{1,22},{2,15}]
  end

  test "balancer" do
    assert conduct_test({BalancedLock, BalancedLock.start_link}) == [{0,18},{1,22},{2,15}]
  end

  test "timeout" do
    {:ok, lock} = Lock.start_link
    spawn(fn() -> Lock.exec(lock, :a, fn() -> :timer.sleep(100) end) end)
    :timer.sleep(10)
    assert catch_throw(Lock.exec(lock, :a, 1, fn() -> :ok end))
  end

  test "try" do
    {:ok, lock} = Lock.start_link
    assert Lock.try_exec(lock, :a, fn() -> 1 end) == 1
    spawn(fn() -> Lock.try_exec(lock, :a, fn() -> :timer.sleep(100) end) end)
    :timer.sleep(20)
    assert Lock.try_exec(lock, :a, fn() -> 2 end) == {:lock, :not_acquired}
    :timer.sleep(100)
    assert Lock.try_exec(lock, :a, fn() -> 3 end) == 3
  end

  test "double lock" do
    assert conduct_test(
      {Lock, Lock.start_link},
      nil,
      fn(ets, lock, _) ->
        exec_lock(lock, 1, fn() ->
          :ets.insert(ets, {0, 1})
          exec_lock(lock, 1, fn() ->
            :ets.insert(ets, {0, 2})
          end)
        end)
      end
    ) == [{0,2}]
  end

  test "multiple" do
    assert conduct_test(
      {Lock, Lock.start_link},
      nil,
      fn(ets, lock, custom) ->
        Enum.each(1..2, fn(_) ->
          start(ets, lock, custom)
          :timer.sleep(100)
        end)
      end
    ) == [{0,36},{1,44},{2,30}]
  end

  test "exception" do
    :error_logger.tty(false)

    assert conduct_test(
      {Lock, Lock.start_link},
      fn
        (3) -> throw(:exit)
        _ -> :ok
      end
    ) == [{0,15},{1,22},{2,15}]

    :error_logger.tty(true)
  end

  test "exit" do
    :error_logger.tty(false)

    assert conduct_test(
      {Lock, Lock.start_link},
      fn
        (4) -> exit(:kill)
        _ -> :ok
      end
    ) == [{0,18},{1,18},{2,15}]
  end

  defp conduct_test(lock, custom \\ fn(_) -> nil end, body \\ &default_body/3) do
    ets = :ets.new(:test, [:public, :set])

    body.(ets, lock, custom)

    :ets.tab2list(ets)
    |> Enum.sort
  end

  defp default_body(ets, lock, custom) do
    start(ets, lock, custom)
    :timer.sleep(100)
  end


  defp start(ets, lock, custom) do
    Enum.each(1..10, fn(x) ->
      key = rem(x, 3)
      spawn(fn() ->
        (custom || fn(_) -> end).(x)
        exec_lock(lock, key, fn() ->
          :timer.sleep(10)

          new_value = case :ets.lookup(ets, key) do
            [{_, old_value}] -> old_value + x
            _ -> x
          end

          :ets.insert(ets, {key, new_value})
        end)
      end)
    end)
  end

  defp exec_lock({BalancedLock, _}, key, fun) do
    BalancedLock.exec(key, fun)
  end

  defp exec_lock({Lock, {:ok, lock_pid}}, key, fun) do
    Lock.exec(lock_pid, key, fun)
  end
end