defmodule ConCache.Helper do
  defmacro defcacheop({name, _, [cache_arg | rest_args] = all_args}) do
    forward_args = [
      quote(do: ConCache.Owner.cache(unquote(cache_arg))) |
      Enum.map(rest_args, &arg_name/1)
    ]

    quote do
      def unquote(name)(unquote_splicing(all_args)) do
        ConCache.Operations.unquote(name)(unquote_splicing(forward_args))
      end
    end
  end

  defp arg_name({:\\, _, [name, _default]}), do: name
  defp arg_name(other), do: other
end