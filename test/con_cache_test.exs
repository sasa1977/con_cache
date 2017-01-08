defmodule ConCacheTest do
  use ExUnit.Case, async: false

  test "initial" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.get(cache, :a) == nil
  end

  test "put" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.put(cache, :a, 1) == :ok
    assert ConCache.get(cache, :a) == 1
  end

  test "multiple put on bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 2)
    assert ConCache.get(cache, :a) == [1,2]
  end

  test "multiple put on duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 1)
    assert ConCache.get(cache, :a) == [1,1]
  end

  test "insert_new" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.insert_new(cache, :b, 2) == :ok
    assert ConCache.get(cache, :b) == 2
    assert ConCache.insert_new(cache, :b, 3) == {:error, :already_exists}
    assert ConCache.get(cache, :b) == 2
  end

  test "insert_new after multiple put on bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 2)
    ConCache.insert_new(cache, :a, 3)
    assert ConCache.get(cache, :a) == [1,2]
  end

  test "insert_new after multiple put on duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 1)
    ConCache.insert_new(cache, :a, 2)
    assert ConCache.get(cache, :a) == [1,1]
  end

  test "delete" do
    {:ok, cache} = ConCache.start_link()
    ConCache.put(cache, :a, 1)
    assert ConCache.delete(cache, :a) == :ok
    assert ConCache.get(cache, :a) == nil
  end

  test "delete on bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 2)
    assert ConCache.delete(cache, :a) == :ok
    assert ConCache.get(cache, :a) == nil
  end

  test "delete on duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    ConCache.put(cache, :a, 1)
    ConCache.put(cache, :a, 1)
    assert ConCache.delete(cache, :a) == :ok
    assert ConCache.get(cache, :a) == nil
  end

  test "update" do
    {:ok, cache} = ConCache.start_link()
    ConCache.put(cache, :a, 1)
    assert ConCache.update(cache, :a, &({:ok, &1 + 1})) == :ok
    assert ConCache.get(cache, :a) == 2

    assert ConCache.update(cache, :a, fn(_) -> {:error, false} end) == {:error, false}
  end

  test "raise when update bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    ConCache.put(cache, :a, 1)
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.update(cache, :a,&({:ok, &1 + 1})) end
    )
  end

  test "raise when update duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    ConCache.put(cache, :a, 1)
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.update(cache, :a,&({:ok, &1 + 1})) end
    )
  end

  test "update_existing" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.update_existing(cache, :a, &({:ok, &1 + 1})) == {:error, :not_existing}
    ConCache.put(cache, :a, 1)
    assert ConCache.update_existing(cache, :a, &({:ok, &1 + 1})) == :ok
    assert ConCache.get(cache, :a) == 2
  end

  test "raise when update_existing bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    ConCache.put(cache, :a, 1)
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.update_existing(cache, :a,&({:ok, &1 + 1})) end
    )
  end

  test "raise when update_existing duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    ConCache.put(cache, :a, 1)
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.update_existing(cache, :a,&({:ok, &1 + 1})) end
    )
  end

  test "invalid update" do
    {:ok, cache} = ConCache.start_link()
    ConCache.put(cache, :a, 1)
    assert_raise(
      RuntimeError,
      ~r/^Invalid return value.*/,
      fn -> ConCache.update(cache, :a, fn(_) -> :invalid_return_value end) end
    )
  end

  test "get_or_store" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.get_or_store(cache, :a, fn() -> 1 end) == 1
    assert ConCache.get_or_store(cache, :a, fn() -> 2 end) == 1
    assert ConCache.get_or_store(cache, :b, fn() -> 4 end) == 4
  end

  test "raise when get_or_store bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:bag])
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.get_or_store(cache, :a,fn -> 2 end) end
    )
  end

  test "raise when get_or_store duplicate_bag" do
    {:ok, cache} = ConCache.start_link(ets_options: [:duplicate_bag])
    assert_raise(
      ArgumentError,
      ~r/^This function is.*/,
      fn -> ConCache.get_or_store(cache, :a,fn -> 2 end) end
    )
  end

  test "size" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.size(cache) == 0
    ConCache.put(cache, :a, "foo")
    assert ConCache.size(cache) == 1
  end

  test "dirty" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.dirty_put(cache, :a, 1) == :ok
    assert ConCache.get(cache, :a) == 1

    assert ConCache.dirty_insert_new(cache, :b, 2) == :ok
    assert ConCache.get(cache, :b) == 2
    assert ConCache.dirty_insert_new(cache, :b, 3) == {:error, :already_exists}
    assert ConCache.get(cache, :b) == 2
    assert ConCache.dirty_delete(cache, :b) == :ok
    assert ConCache.get(cache, :b) == nil

    assert ConCache.dirty_update(cache, :a, &({:ok, &1 + 1})) == :ok
    assert ConCache.get(cache, :a) == 2

    assert ConCache.dirty_update_existing(cache, :a, &({:ok, &1 + 1})) == :ok
    assert ConCache.get(cache, :a) == 3

    assert ConCache.dirty_update_existing(cache, :b, &({:ok, &1 + 1})) == {:error, :not_existing}
    assert ConCache.get(cache, :b) == nil

    assert ConCache.dirty_get_or_store(cache, :a, fn() -> :dummy end) == 3
    assert ConCache.dirty_get_or_store(cache, :b, fn() -> 4 end) == 4
    assert ConCache.get(cache, :b) == 4
  end

  test "ets_options" do
    {:ok, cache} = ConCache.start_link(ets_options: [:named_table, name: :test_name])
    assert :ets.info(ConCache.ets(cache), :named_table) == true
    assert :ets.info(ConCache.ets(cache), :name) == :test_name
  end

  test "callback" do
    me = self()
    {:ok, cache} = ConCache.start_link(callback: &send(me, &1))

    ConCache.put(cache, :a, 1)
    assert_receive {:update, ^cache, :a, 1}

    ConCache.update(cache, :a, fn(_) -> {:ok, 2} end)
    assert_receive {:update, ^cache, :a, 2}

    ConCache.update_existing(cache, :a, fn(_) -> {:ok, 3} end)
    assert_receive {:update, ^cache, :a, 3}

    ConCache.delete(cache, :a)
    assert_receive {:delete, ^cache, :a}
  end

  Enum.each([1, 2, 4, 8], fn(time_size) ->
    test "ttl #{time_size}" do
      {:ok, cache} = ConCache.start_link(ttl_check: 10, ttl: 50, time_size: unquote(time_size))

      ConCache.put(cache, :a, 1)
      :timer.sleep(40)
      assert ConCache.get(cache, :a) == 1
      :timer.sleep(40)
      assert ConCache.get(cache, :a) == nil

      test_renew_ttl(cache, fn() -> ConCache.put(cache, :a, 1) end)
      test_renew_ttl(cache, fn() -> ConCache.update(cache, :a, &({:ok, &1 + 1})) end)
      test_renew_ttl(cache, fn() -> ConCache.update_existing(cache, :a, &({:ok, &1 + 1})) end)
      test_renew_ttl(cache, fn() -> ConCache.touch(cache, :a) end)

      ConCache.put(cache, :a, %ConCache.Item{value: 1, ttl: 20})
      :timer.sleep(40)
      assert ConCache.get(cache, :a) == nil

      ConCache.put(cache, :a, %ConCache.Item{value: 1, ttl: 0})
      :timer.sleep(100)
      assert ConCache.get(cache, :a) == 1

      ConCache.put(cache, :a, 2)
      ConCache.delete(cache, :a)
      :timer.sleep(60)
      assert ConCache.get(cache, :a) == nil
    end
  end)

  test "no_update" do
    {:ok, cache} = ConCache.start_link(ttl_check: 10, ttl: 50)
    ConCache.put(cache, :a, 1)
    :timer.sleep(40)
    ConCache.put(cache, :a, %ConCache.Item{value: 2, ttl: :no_update})
    ConCache.update(cache, :a, fn(_old) -> {:ok, %ConCache.Item{value: 3, ttl: :no_update}} end)
    assert ConCache.get(cache, :a) == 3
    :timer.sleep(40)
    assert ConCache.get(cache, :a) == nil
  end

  test "created key with update should have default ttl" do
    {:ok, cache} = ConCache.start_link(ttl_check: 10, ttl: 10)
    ConCache.update(cache, :a, fn(_) -> {:ok, 1} end)
    assert ConCache.get(cache, :a) == 1
    :timer.sleep(50)
    refute ConCache.get(cache, :a) == 1
  end

  defp test_renew_ttl(cache, fun) do
    ConCache.put(cache, :a, 1)
    :timer.sleep(50)
    assert ConCache.get(cache, :a) == 1
    fun.()
    :timer.sleep(50)
    assert ConCache.get(cache, :a) != nil
    :timer.sleep(70)
    assert ConCache.get(cache, :a) == nil
  end

  test "touch_on_read" do
    {:ok, cache} = ConCache.start_link(ttl_check: 10, ttl: 50, touch_on_read: true)
    ConCache.put(cache, :a, 1)
    :timer.sleep(40)
    assert ConCache.get(cache, :a) == 1
    :timer.sleep(40)
    assert ConCache.get(cache, :a) == 1
    :timer.sleep(100)
    assert ConCache.get(cache, :a) == nil
  end

  test "try_isolated" do
    {:ok, cache} = ConCache.start_link()
    spawn(fn() ->
      ConCache.isolated(cache, :a, fn() -> :timer.sleep(100) end)
    end)

    :timer.sleep(20)
    assert ConCache.try_isolated(cache, :a, fn() -> flunk "error" end) == {:error, :locked}

    :timer.sleep(100)
    assert ConCache.try_isolated(cache, :a, fn() -> :isolated end) == {:ok, :isolated}
  end

  test "nested" do
    {:ok, cache} = ConCache.start_link()
    assert ConCache.isolated(cache, :a, fn() ->
      ConCache.isolated(cache, :b, fn() ->
        ConCache.isolated(cache, :c, fn() -> 1 end)
      end)
    end) == 1

    assert ConCache.isolated(cache, :a, fn() -> 2 end) == 2
  end

  test "multiple" do
    {:ok, cache1} = ConCache.start_link()
    {:ok, cache2} = ConCache.start_link()
    ConCache.put(cache1, :a, 1)
    ConCache.put(cache2, :b, 2)
    assert ConCache.get(cache1, :a) == 1
    assert ConCache.get(cache1, :b) == nil
    assert ConCache.get(cache2, :a) == nil
    assert ConCache.get(cache2, :b) == 2

    spawn(fn -> ConCache.isolated(cache1, :a, fn -> :timer.sleep(:infinity) end) end)
    assert ConCache.isolated(cache2, :a, fn -> :foo end) == :foo
    assert {:timeout, _} = catch_exit(ConCache.isolated(cache1, :a, 50, fn -> :bar end))
  end

  for name <- [:cache, {:global, :cache}, {:via, :global, :cache2}] do
    test "registration #{inspect name}" do
      name = unquote(Macro.escape(name))
      {:ok, _} = ConCache.start_link([], name: name)
      ConCache.put(name, :a, 1)
      assert ConCache.get(name, :a) == 1
    end
  end
end
