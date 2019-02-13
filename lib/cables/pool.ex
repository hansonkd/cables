defmodule Cables.Pool do
    defstruct [:host, :port, :conn_opts, :threshold, :pending, :waiting, :connections, :max_streams, :min_connections, :max_connections, :ttl, :max_requests]
    use GenServer
    alias Cables.Pool
    alias Cables.Request

    defmodule Connection do
        defstruct [:streams, :lifetime, :ref, :timer]

        def new(ref) do
            %Connection{streams: MapSet.new(), lifetime: 0, ref: ref}
        end
    end

    def request_stream(pool, request, timeout) do
      try do
        {gun_pid, [stream]} = GenServer.call(pool, {:request, [request]}, timeout)
        {gun_pid, stream}
      rescue
        exception ->
          Cables.Pool.cancel_waiting(pool, self())
          reraise exception, __STACKTRACE__
      end
    end

    def finish_stream(pool, gun_pid, stream_ref) do
        GenServer.cast(pool, {:finish, gun_pid, [stream_ref]})
    end

    def cancel_waiting(pool, waiting_pid) do
        GenServer.cast(pool, {:cancel_waiting, waiting_pid})
    end
    def start_link(opts) when is_list(opts) do
        gen_server_opts = Keyword.take(opts, [:name])
        GenServer.start_link(__MODULE__, opts, gen_server_opts)
    end
    def init(opts) do
        pool = %Pool{
            connections: %{},
            waiting: :queue.new(),
            pending: %{},
            host: Keyword.fetch!(opts, :host),
            port: Keyword.fetch!(opts, :port),
            conn_opts: Keyword.fetch!(opts, :connection_opts),
            threshold: Keyword.fetch!(opts, :threshold),
            max_streams: Keyword.fetch!(opts, :max_streams),
            min_connections: Keyword.fetch!(opts, :min_connections),
            max_connections: Keyword.fetch!(opts, :max_connections),
            max_requests: Keyword.fetch!(opts, :max_requests),
            ttl: Keyword.fetch!(opts, :connection_ttl),
        }
        {:ok, start_min(pool)}
    end

    defp start_min(pool = %Pool{pending: pending, host: host, port: port, conn_opts: conn_opts, min_connections: min_connections}) do
        new_pending = Enum.map(1..min_connections, fn _ ->
            {:ok, gun_pid} = :gun.open(host, port, conn_opts)
            ref = :erlang.monitor(:process, gun_pid)
            {gun_pid, ref}
        end)
        |> Enum.into(pending)
        %{pool | pending: new_pending}
    end

    def handle_call(
        {:request, requests},
        from,
        pool = %Pool{
            connections: connections,
            waiting: waiting
            }) do
        case find_or_start_connection(Enum.count(requests), pool) do
            {nil, new} ->
                {:noreply, %{new | waiting: :queue.in({from, requests}, waiting)}}
            {{gun_pid, conn}, new} ->
                {stream_refs, new_conn} = do_requests(requests, gun_pid, conn)
                {:reply, {gun_pid, stream_refs}, %{new | connections: Map.put(connections, gun_pid, new_conn)}}
        end
    end
    def handle_cast(
        {:finish, gun_pid, stream_refs},
        pool = %Pool{
            connections: connections,
            waiting: waiting,
            ttl: ttl,
            min_connections: min_connections,
            max_requests: max_requests,
            max_streams: max_streams
            }) do
        new =
            case connections do
                %{^gun_pid => conn = %Connection{streams: streams}} ->
                    new_streams = Enum.reduce(stream_refs, streams, fn stream_ref, streams -> MapSet.delete(streams, stream_ref) end)
                    {new_connection, new_waiting} =
                        handle_waiting(gun_pid, %{conn | streams: new_streams}, waiting, max_streams)
                    num_streams = MapSet.size(new_connection.streams)
                    new_connections =
                        cond do
                            num_streams == 0 and Map.size(connections) > min_connections ->
                                timer = Process.send_after(self(), {:close, gun_pid}, ttl)
                                Map.put(connections, gun_pid, %{new_connection | timer: timer})
                            num_streams == 0 and new_connection.lifetime >= max_requests ->
                                send(self(), {:close, gun_pid})
                                Map.delete(connections, gun_pid)
                            true ->
                                Map.put(connections, gun_pid, new_connection)
                        end
                    %{pool | connections: new_connections, waiting: new_waiting}
                _ ->
                    pool
            end
        {:noreply, new}
    end
    def handle_cast({:cancel_waiting, waiting_pid}, pool = %Pool{waiting: waiting}) do
        {:noreply, %{pool | waiting: :queue.filter(fn {{pid, _ref}, _} -> pid == waiting_pid end, waiting)}}
    end
    def handle_info(
        {:gun_up, gun_pid, _protocol},
        pool = %Pool{
            pending: pending,
            connections: connections,
            waiting: waiting,
            max_streams: max_streams}) do
        {ref, new_pending} = Map.pop(pending, gun_pid)
        connection = Map.get_lazy(connections, gun_pid, fn -> Connection.new(ref) end)
        {new_connection, new_waiting} = handle_waiting(gun_pid, connection, waiting, max_streams)
        {:noreply, %{pool | pending: new_pending, waiting: new_waiting, connections: Map.put(connections, gun_pid, new_connection)}}
    end
    def handle_info({:gun_down, gun_pid, _protocol, _reason, _killed_streams, _unprocessed_streams}, pool = %Pool{connections: connections}) do
        {:noreply, %{pool | connections: Map.delete(connections, gun_pid)}}
    end
    def handle_info(
        {:DOWN, _gun_ref, :process, gun_pid, _reason},
        pool = %Pool{
            pending: pending,
            connections: connections}) do
        {:noreply,
          %{pool |
            pending: Map.delete(pending, gun_pid),
            connections: Map.delete(connections, gun_pid)}}
    end
    def handle_info({:close, gun_pid}, pool = %Pool{connections: connections}) do
        :gun.close(gun_pid)
        {:noreply, %{pool | connections: Map.delete(connections, gun_pid)}}
    end
    defp find_or_start_connection(
        num_streams,
        pool = %Pool{
            pending: pending,
            host: host,
            port: port,
            conn_opts: conn_opts,
            threshold: threshold,
            max_streams: max_streams,
            max_connections: max_connections,
            connections: connections,
            max_requests: max_requests}) do
        found = Enum.find(connections, fn
            {_, %Connection{lifetime: lifetime, streams: streams}} ->
                (
                    (MapSet.size(streams) + num_streams) <= threshold
                    and
                    (lifetime + num_streams) <= max_requests
                )
        end)
        case found do
            nil ->
                new =
                    if Map.size(pending) + count_accepting(pool) < max_connections do
                        {:ok, gun_pid} = :gun.open(host, port, conn_opts)
                        ref = :erlang.monitor(:process, gun_pid)
                        %{pool | pending: Map.put(pending, gun_pid, ref)}
                    else
                        pool
                    end
                other = Enum.find(connections, fn
                    {_, %Connection{lifetime: lifetime, streams: streams}} ->
                        (
                            (MapSet.size(streams) + num_streams) <= max_streams
                            and
                            (lifetime + num_streams) <= max_requests
                        )
                end)
                {other, new}
            other ->
                {other, pool}
        end
    end
    defp count_accepting(%Pool{connections: connections, max_requests: max_requests}) do
        Enum.count(connections, fn {_, %Connection{lifetime: lifetime}} -> lifetime < max_requests end)
    end
    defp handle_waiting(gun_pid, conn = %Connection{streams: streams}, waiting_queue, max_streams) do
        available_streams = max_streams - MapSet.size(streams)
        if available_streams > 0 do
            case :queue.out(waiting_queue) do
                {{:value, {{pid, _ref} = waiting, requests}}, new_queue} ->
                    if not Process.alive?(pid) do
                        handle_waiting(gun_pid, conn, new_queue, max_streams)
                    else
                        if Enum.count(requests) <= available_streams do
                            {stream_refs, new_conn} = do_requests(requests, gun_pid, conn)
                            GenServer.reply(waiting, {gun_pid, stream_refs})
                            handle_waiting(gun_pid, new_conn, new_queue, max_streams)
                        else
                            {conn, waiting_queue}
                        end
                    end
                {:empty, _q} ->
                    {conn, waiting_queue}
            end
        else
            {conn, waiting_queue}
        end
    end
    defp do_requests(requests, gun_pid, conn = %Connection{timer: timer, streams: streams, lifetime: lifetime}) do
        if timer != nil do
            Process.cancel_timer(timer)
        end
        stream_refs = Enum.map(requests, fn
            %Request{method: method, path: path, headers: headers, body: body,  reply_to: reply_to} ->
                :gun.request(gun_pid, method, path, headers, body, %{reply_to: reply_to})
        end)
        new_conn = %{conn |
            timer: nil,
            streams:
                Enum.reduce(stream_refs, streams, fn
                    stream_ref, streams -> MapSet.put(streams, stream_ref)
                end),
            lifetime: lifetime + Enum.count(requests)
        }
        {stream_refs, new_conn}
    end
end
