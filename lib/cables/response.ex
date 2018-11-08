defmodule Cables.Response do
  @moduledoc """
  A `Cables.Handler` that consumes the response body and returns a
  `Cables.Response` with `:status`, `:headers`, and `:body`
  """
  defstruct [:status, :headers, :body]

  use Cables.Handler
  alias Cables.Response


  def init(_gun_pid, _stream, _init_arg) do
    nil
  end

  def handle_headers(status, headers, nil) do
    {status, headers, []}
  end

  def handle_data(data, {status, headers, pieces}) do
    {status, headers, [data | pieces]}
  end

  def handle_finish({status, headers, pieces}) do
    {:ok, %Response{status: status, headers: headers, body: IO.iodata_to_binary(Enum.reverse(pieces))}}
  end
end