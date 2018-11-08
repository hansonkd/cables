defmodule Cables.Handler do
  @moduledoc """
  Handlers specify how to consume response data.

  The handler flow starts with `init/3` being called and returning the initial state or an error. In `init`,
  additional data can be sent with the request by using `Cabels.send_data/2` and `Cabels.send_final_data/2`.

  After getting the new state we wait until we recieve the headers. `handle_headers/3` will be called with the
  status, headers and the state taken from `init`. A new state should be returned.

  After processing the headers, Cables will loop with `handle_data/2` until there is no more response data. Each call to `handle_data` should return a new state for the loop.

  After all response data is recieved, `handle_finish/1` will be called with the state from `handle_data` to finish any processing.
  """

  @callback init(gun_pid :: pid, stream_ref :: reference, init_arg :: term) :: {:ok, state} when state: any
  @callback handle_headers(integer, [{String.t, String.t}], state) :: state when state: any
  @callback handle_data(String.t, state) :: state when state: any
  @callback handle_finish(state) :: {:ok, any} when state: any
  @callback handle_down(reason :: any, state) :: {:error, any} when state: any

  defmacro __using__(_opts) do
    quote do
      @behaviour Cables.Handler

      def handle(gun_pid, stream_ref, timeout, init_arg) do
        state = init(gun_pid, stream_ref, init_arg)
        mref = :erlang.monitor(:process, gun_pid)
        timer = Process.send_after(self(), {:timeout, stream_ref}, timeout)
        receive do
          {:gun_response, ^gun_pid, ^stream_ref, :fin, status, headers} ->
            Process.cancel_timer(timer, async: true, info: false)
            handle_headers(status, headers, state) |> handle_finish()
          {:gun_response, ^gun_pid, ^stream_ref, :nofin, status, headers} ->
            new_state = handle_headers(status, headers, state)
            handle_data_loop(mref, gun_pid, stream_ref, timer, new_state)
          {:DOWN, ^mref, :process, ^gun_pid, reason} ->
            Process.cancel_timer(timer, async: true, info: false)
            handle_down(reason, state)
          {:timeout, ^stream_ref} ->
            :gun.cancel(gun_pid, stream_ref)
            {:error, :connection_timeout}
        end
      end

      def handle_finish(state) do
        {:ok, state}
      end

      def handle_down(reason, state) do
        {:error, {:conn_closed, reason}}
      end

      defp handle_data_loop(mref, gun_pid, stream_ref, timer, state) do
        receive do
          {:gun_data, ^gun_pid, ^stream_ref, :nofin, chunk} ->
            handle_data_loop(mref, gun_pid, stream_ref, timer, handle_data(chunk, state))
          {:gun_data, ^gun_pid, ^stream_ref, :fin, chunk} ->
            Process.cancel_timer(timer, async: true, info: false)
            handle_data(chunk, state) |> handle_finish()
          {:DOWN, ^mref, :process, ^gun_pid, reason} ->
            Process.cancel_timer(timer, async: true, info: false)
            handle_down(reason, state)
          {:timeout, ^stream_ref} ->
            :gun.cancel(gun_pid, stream_ref)
            {:error, :connection_timeout}
        end
      end

      defoverridable handle_finish: 1, handle_down: 2
    end
  end
end