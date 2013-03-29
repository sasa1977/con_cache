defmodule KeyBalancer do
  @type t :: tuple
  @type key :: any
  @type element :: any
  @type result :: any
  @type job :: ((element) -> result)
  
  @spec new(pos_integer, (() -> element)) :: t
  def new(size, initializer) when size >= 1 do
    [__MODULE__ | [size | Enum.map(1..size, fn(_) -> initializer.() end)]] |>
    list_to_tuple
  end

  @spec exec(t, key, job) :: result
  def exec(balancer, id, fun) do
    index = :erlang.phash2(id, elem(balancer, 1)) + 2
    fun.(elem(balancer, index))
  end
end