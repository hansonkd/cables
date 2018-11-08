defmodule Cables.Connection do
  @moduledoc """
  Holds the state of a connection.
  """
  defstruct [:host, :port, :conn_opts, :max_streams, :ttl, :gun_pid, :ref, :timer, :streams]

  use GenServer
  alias Cables.Connection
  alias Cables.Request


  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  def init([host, port, conn_opts, max_streams, ttl]) do
    IO.inspect(%Connection{host: host, port: port, conn_opts: conn_opts, max_streams: max_streams, ttl: ttl, streams: MapSet.new})
    {:ok, %Connection{host: host, port: port, conn_opts: conn_opts, max_streams: max_streams, ttl: ttl, streams: MapSet.new}}
  end
  def handle_call({:request, request}, from, state = %Connection{streams: streams, max_streams: max_streams}) do
    {reply, new_state} = connect_or_request(request, state)
    {:reply, {reply, MapSet.size(state.streams) < max_streams} , new_state}
  end
  def handle_cast({:finish_stream, stream_ref}, state = %Connection{max_streams: max_streams, streams: streams}) do
    new_streams = MapSet.delete(streams, stream_ref)
    new_state = %{state | streams: new_streams}
    {:noreply, new_state}
  end
  def handle_info({:gun_up, gun_pid, protocol}, state) do
    {:noreply, state}
  end
  def handle_info(:close, state = %Connection{gun_pid: pid}) do
    :gun.close(pid)
    {:noreply, state}
  end
  def handle_info({:gun_down, gun_pid, _protocol, reason, _killed_streams, unprocessed_streams}, state = %Connection{ttl: ttl, gun_pid: pid}) do
    {:noreply, %{state | streams: MapSet.new}}
  end
  def handle_info(
    {:DOWN, gun_ref, :process, gun_pid, _reason}, state = %Connection{gun_pid: gun_pid, ref: gun_ref}) do
    {:noreply,
      %{state |
        streams: MapSet.new,
        gun_pid: nil,
        ref: nil}}
  end


  defp connect_or_request(request, state = %Connection{host: host, port: port, conn_opts: opts, gun_pid: nil}) do
    {:ok, pid} = :gun.open(host, port, opts)
    {:ok, _} = :gun.await_up(pid)
    gun_ref = :erlang.monitor(:process, pid)
    do_request(request, %{state | gun_pid: pid, ref: gun_ref})
  end
  defp connect_or_request(request, state = %Connection{}) do
    do_request(request, state)
  end
  defp do_request(%Request{method: method, path: path, headers: headers, body: body,  reply_to: reply_to}, state = %Connection{timer: timer, ttl: ttl, streams: streams, gun_pid: gun_pid}) do
    stream_ref = :gun.request(gun_pid, method, path, headers, body, %{reply_to: reply_to})
    if timer != nil do
        Process.cancel_timer(timer, async: true, info: false)
    end
    timer = Process.send_after(self(), :close, ttl)
    {{gun_pid, stream_ref}, %{state | streams: MapSet.put(streams, stream_ref), timer: timer}}
  end
end