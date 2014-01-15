defmodule ConCacheTest do
  use ExUnit.Case, async: false

  defp with_cache(opts // [], fun) do
    cache = ConCache.start_link(opts)
    fun.(cache)
    ConCache.stop(cache)
  end


  test "initial" do
    with_cache(fn(cache) ->
      assert ConCache.size(cache) == 0
      assert ConCache.memory(cache) > 0
      assert ConCache.memory_bytes(cache) > 0
      assert ConCache.get(cache, :a) == nil
    end)
  end

  test "put" do
    with_cache(fn(cache) ->
      assert ConCache.put(cache, :a, 1) == :ok
      assert ConCache.get(cache, :a) == 1
      assert ConCache.size(cache) == 1
    end)
  end

  test "insert_new" do
    with_cache(fn(cache) ->
      assert ConCache.insert_new(cache, :b, 2) == :ok
      assert ConCache.get(cache, :b) == 2
      assert ConCache.insert_new(cache, :b, 3) == {:error, :already_exists}
      assert ConCache.get(cache, :b) == 2
    end)
  end

  test "delete" do
    with_cache(fn(cache) ->
      ConCache.put(cache, :a, 1)
      assert ConCache.delete(cache, :a) == :ok
      assert ConCache.get(cache, :a) == nil
    end)
  end

  test "with_existing" do
    with_cache(fn(cache) ->
      ConCache.put(cache, :a, 1)
      assert ConCache.with_existing(cache, :a, &({:ok, &1})) == {:ok, 1}
      assert ConCache.with_existing(cache, :b, &({:ok, &1})) == nil
    end)
  end

  test "update" do
    with_cache(fn(cache) ->
      ConCache.put(cache, :a, 1)
      assert ConCache.update(cache, :a, &(&1 + 1)) == :ok
      assert ConCache.get(cache, :a) == 2

      assert ConCache.update(cache, :a, fn(_) -> {:cancel_update, false} end) == false
    end)
  end

  test "update_existing" do
    with_cache(fn(cache) ->
      assert ConCache.update_existing(cache, :a, &(&1 + 1)) == {:error, :not_existing}
      ConCache.put(cache, :a, 1)
      assert ConCache.update_existing(cache, :a, &(&1 + 1)) == :ok
      assert ConCache.get(cache, :a) == 2
    end)
  end

  test "get_or_store" do
    with_cache(fn(cache) ->
      assert ConCache.get_or_store(cache, :a, fn() -> 1 end) == 1
      assert ConCache.get_or_store(cache, :a, fn() -> 2 end) == 1
      assert ConCache.get_or_store(cache, :b, fn() -> 4 end) == 4
    end)
  end

  test "get_all" do
    with_cache(fn(cache) ->
      ConCache.put(cache, :a, 1)
      ConCache.put(cache, :b, 2)
      assert ConCache.get_all(cache) |> Enum.sort == [a: 1, b: 2]
    end)
  end
  
  test "dirty" do
    with_cache(fn(cache) ->
      assert ConCache.dirty_put(cache, :a, 1) == :ok
      assert ConCache.get(cache, :a) == 1
      
      assert ConCache.dirty_insert_new(cache, :b, 2) == :ok
      assert ConCache.get(cache, :b) == 2
      assert ConCache.dirty_insert_new(cache, :b, 3) == {:error, :already_exists}
      assert ConCache.get(cache, :b) == 2
      assert ConCache.dirty_delete(cache, :b) == :ok
      assert ConCache.get(cache, :b) == nil
          
      assert ConCache.dirty_update(cache, :a, &(&1 + 1)) == :ok
      assert ConCache.get(cache, :a) == 2

      assert ConCache.dirty_update_existing(cache, :a, &(&1 + 1)) == :ok
      assert ConCache.get(cache, :a) == 3
      
      assert ConCache.dirty_update_existing(cache, :b, &(&1 + 1)) == {:error, :not_existing}
      assert ConCache.get(cache, :b) == nil
          
      assert ConCache.dirty_get_or_store(cache, :a, fn() -> :dummy end) == 3
      assert ConCache.dirty_get_or_store(cache, :b, fn() -> 4 end) == 4
      assert ConCache.get(cache, :b) == 4
    end)
  end

  test "ets_options" do
    with_cache(
      [ets_options: [:named_table, {:name, :test_name}]], 
      fn(cache) ->
        assert :ets.info(cache.ets, :named_table) == true
        assert :ets.info(cache.ets, :name) == :test_name
      end
    )
  end

  test "from_ets" do
    with_cache(
      [ets: :ets.new(:custom_ets, [:public])], 
      fn(cache) ->
        assert ConCache.get(cache, :a) == nil
        assert ConCache.put(cache, :a, 1) == :ok
        assert ConCache.get(cache, :a) == 1

        assert catch_throw ConCache.start_link(ets: :ets.new(:custom_ets, [:protected]))
        assert catch_throw ConCache.start_link(ets: :ets.new(:custom_ets, [:private]))
        assert catch_throw ConCache.start_link(ets: :ets.new(:custom_ets, [:bag]))
      end
    )
  end

  test "callback" do
    with_cache(
      [callback: &send(self, &1)], 
      fn(cache) ->
        ConCache.put(cache, :a, 1)
        assert_receive {:update, ^cache, :a, 1}

        ConCache.update(cache, :a, fn(_) -> 2 end)
        assert_receive {:update, ^cache, :a, 2}

        ConCache.update_existing(cache, :a, fn(_) -> 3 end)
        assert_receive {:update, ^cache, :a, 3}

        ConCache.delete(cache, :a)
        assert_receive {:delete, ^cache, :a}
      end
    )
  end

  test "ttl" do
    Enum.each([1, 2, 4, 8], fn(time_size) ->
      with_cache(
        [ttl_check: 10, ttl: 50, time_size: time_size], 
        fn(cache) ->
          ConCache.put(cache, :a, 1)
          :timer.sleep(40)
          assert ConCache.get(cache, :a) == 1
          :timer.sleep(40)
          assert ConCache.get(cache, :a) == nil
          
          test_renew_ttl(cache, fn() -> ConCache.put(cache, :a, 1) end)
          test_renew_ttl(cache, fn() -> ConCache.update(cache, :a, &(&1 + 1)) end)
          test_renew_ttl(cache, fn() -> ConCache.update_existing(cache, :a, &(&1 + 1)) end)
          test_renew_ttl(cache, fn() -> ConCache.touch(cache, :a) end)
          
          ConCache.put(cache, :a, ConCacheItem.new(value: 1, ttl: 20))
          :timer.sleep(40)
          assert ConCache.get(cache, :a) == nil
          
          ConCache.put(cache, :a, ConCacheItem.new(value: 1, ttl: 0))
          :timer.sleep(100)
          assert ConCache.get(cache, :a) == 1
          
          ConCache.put(cache, :a, 2)
          ConCache.delete(cache, :a)
          :timer.sleep(60)
          assert ConCache.get(cache, :a) == nil
        end
      )
    end)
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
    with_cache(
      [ttl_check: 10, ttl: 50, touch_on_read: true], 
      fn(cache) ->
        ConCache.put(cache, :a, 1)
        :timer.sleep(40)
        assert ConCache.get(cache, :a) == 1
        :timer.sleep(40)
        assert ConCache.get(cache, :a) == 1
        :timer.sleep(70)
        assert ConCache.get(cache, :a) == nil
      end
    )
  end
  
  test "try_isolated" do
    with_cache(fn(cache) ->
      spawn(fn() ->
        ConCache.isolated(cache, :a, fn() -> :timer.sleep(100) end)
      end)

      :timer.sleep(20)
      assert ConCache.try_isolated(cache, :a, fn() -> flunk "error" end) == {:error, :locked}

      :timer.sleep(100)
      assert ConCache.try_isolated(cache, :a, fn() -> :isolated end) == :isolated
    end)
  end

  test "nested" do
    with_cache(fn(cache) ->
      assert ConCache.isolated(cache, :a, fn() ->
        ConCache.isolated(cache, :b, fn() ->
          ConCache.isolated(cache, :c, fn() -> 1 end)
        end)
      end) == 1

      assert ConCache.isolated(cache, :a, fn() -> 2 end) == 2
    end)
  end
end