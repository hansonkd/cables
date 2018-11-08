defmodule Cables do
  @moduledoc """
  Asynchronous multiplexed HTTP/2 connection manager.

  Create a new Cable using `Cable.ensure_connection/2`. Cables will not open a connection
  until the first request is recieved.

  ## Examples
      {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      {:ok, %Cables.Response{status: 200}} = Cables.get(cable, "/get")
  """

  @type profile() :: [
    pool_timeout: integer(),
    conn_timeout: integer(),
    max_streams: integer(),
    pool_size: integer(),
    max_overflow: integer(),
    conn_ttl: integer(),
    conn_opts: map()
  ]
  @type http_method() :: :get | :post | :head | :put | :patch | :options | :delete | String.t

  defmodule Request do
    @moduledoc """
    Holds request info
    """
    defstruct [:method, :path, :headers, :body, :reply_to]
  end

  defmodule Cable do
    @moduledoc """
    Holds timeout info and poolname
    """
    defstruct [:pool_name, :pool_timeout, :conn_timeout]
  end

  @doc """
  If a pool is not already created for the specified uri, create one.
  """
  @spec ensure_connection(String.t(), atom()) :: Cabel.t()
  def ensure_connection(uri, profile_name \\ :default) do
    %URI{host: host, scheme: scheme, port: port} = URI.parse(uri)
    pool_name = String.to_atom("#{profile_name}@#{uri}")

    profile = get_profile(profile_name)
    config = poolboy_config(pool_name, profile)
    conn_opts = conn_opts(scheme, profile)

    supervisor_result = DynamicSupervisor.start_child(
      Cabels.ConnPoolSupervisor,
      :poolboy.child_spec(pool_name, config, [to_charlist(host), port, conn_opts, Keyword.get(profile, :max_streams), Keyword.get(profile, :conn_ttl)])
    )
    case supervisor_result do
      {:ok, _pid} ->
        {:ok, make_cable(pool_name, profile)}
      {:error, {:already_started, _pid}} ->
        {:ok, make_cable(pool_name, profile)}
    end
  end

  @doc """
  Start a request and handle it with the request_handler. `Cables.Handler`
  This gives you full control over sending and recieving stream data.

  For an example see `Cables.Response`.

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.request(cable, :get, "/get", Cables.Response, nil)
      ...> status
      200
  """
  @spec request(Cabel.t(), http_method(), String.t, [{String.t, String.t}], String.t, pid(), module(), any()) :: t::any()
  def request(%Cable{pool_name: pool_name, pool_timeout: pool_timeout, conn_timeout: timeout}, method, path, headers \\ [], body \\ "", reply_to \\ nil, module, init_args) do
    method_str =
      case method do
        :get -> "GET"
        :post -> "POST"
        :head -> "HEAD"
        :put -> "PUT"
        :patch -> "PATCH"
        :delete -> "DELETE"
        :options -> "OPTIONS"
        m when is_binary(m) -> m
      end

    req = %Request{
      method: method_str,
      path: path,
      headers: headers,
      body: body,
      reply_to: if is_nil(reply_to) do self() else reply_to end
    }

    c = :poolboy.checkout(pool_name, true, pool_timeout)
    {{remote_conn, stream_ref}, check_in} =
      try do
        GenServer.call(c, {:request, req})
      rescue
        exception ->
          :ok = :poolboy.checkin(pool_name, c)
          reraise exception, __STACKTRACE__
      else
        {ret, streams_available} ->
          # If there are available streams, immedidately return to the pool. Else return
          # to the pool after this stream is finished.
          if streams_available do
            :ok = :poolboy.checkin(pool_name, c)
          end
          {ret, not streams_available}
      end

    try do
      module.handle(remote_conn, stream_ref, timeout, init_args)
    after
      if check_in do
        :ok = :poolboy.checkin(pool_name, c)
      end
      GenServer.cast(c, {:finish_stream, stream_ref})
    end
  end

  @doc """
  Simple GET request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.get(cable, "/get")
      ...> status
      200

  """
  @spec get(Cabel.t(), [{String.t, String.t}], String.t, pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def get(cable, path, headers \\ [], reply_to \\ nil) do
    request(cable, :get, path, headers, "", reply_to, Cables.Response, nil)
  end

  @doc """
  Simple POST request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.post(cable, "/post", [], "hello world")
      ...> status
      200

  """
  @spec post(Cabel.t(), String.t, [{String.t, String.t}], iodata(), pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def post(cable, path, headers \\ [], body \\ "", reply_to \\ nil) do
    request(cable, :post, path, headers, body, reply_to, Cables.Response, nil)
  end

  @doc """
  Simple PUT request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.put(cable, "/put", [], "hello world")
      ...> status
      200
  """
  @spec put(Cabel.t(), String.t, [{String.t, String.t}], iodata(), pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def put(cable, path, headers \\ [], body \\ "", reply_to \\ nil) do
    request(cable, :put, path, headers, body, reply_to, Cables.Response, nil)
  end

  @doc """
  Simple PATCH request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.patch(cable, "/patch", [], "hello world")
      ...> status
      200
  """
  @spec patch(Cabel.t(), String.t, [{String.t, String.t}], iodata(), pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def patch(cable, path, headers \\ [], body \\ "", reply_to \\ nil) do
    request(cable, :patch, path, headers, body, reply_to, Cables.Response, nil)
  end

  @doc """
  Simple DELETE request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.ensure_connection("https://httpbin.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.delete(cable, "/delete")
      ...> status
      200
  """
  @spec delete(Cabel.t(), String.t, [{String.t, String.t}], iodata(), pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def delete(cable, path, headers \\ [], body \\ "", reply_to \\ nil) do
    request(cable, :delete, path, headers, body, reply_to, Cables.Response, nil)
  end

  @doc """
  Simple HEAD request with `Cables.Response`
  """
  @spec head(Cabel.t(), [{String.t, String.t}], String.t, pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def head(cable, path, headers \\ [], reply_to \\ nil) do
    request(cable, :head, path, headers, "", reply_to, Cables.Response, nil)
  end

  @doc """
  Simple OPTIONS request with `Cables.Response`
  """
  @spec options(Cabel.t(), [{String.t, String.t}], String.t, pid()) :: {:ok, Cables.Response.t} | {:error, any()}
  def options(cable, path, headers \\ [], reply_to \\ nil) do
    request(cable, :options, path, headers, reply_to, Cables.Response, nil)
  end

  @doc """
  Send a piece of data. Make sure to use &send_final_data/3 to send the final chunk.
  """
  @spec send_data(pid(), reference(), String.t) :: :ok
  def send_data(gun_pid, stream_ref, data) do
    :gun.data(gun_pid, stream_ref, :nofin, data)
  end

  @doc """
  Send a piece of data and indicate that the request body has finished.
  """
  @spec send_final_data(pid(), reference(), String.t) :: :ok
  def send_final_data(gun_pid, stream_ref, data) do
    :gun.data(gun_pid, stream_ref, :fin, data)
  end

  @spec conn_opts(String.t(), profile()) :: any()
  defp poolboy_config(pool_name, profile) do
    [
      name: {:local, pool_name},
      worker_module: Cables.Connection,
      size: Keyword.get(profile, :pool_size),
      max_overflow: Keyword.get(profile, :max_overflow),
      strategy: :lifo
    ]
  end

  @spec conn_opts(String.t(), profile()) :: map()
  defp conn_opts(scheme, profile) do
    transport =
      case scheme do
        "https" -> :tls
        _ -> :tcp
      end
    Map.merge(%{transport: transport}, Keyword.get(profile, :conn_opts))
  end

  @spec make_cable(atom(), profile()) :: Cable.t()
  defp make_cable(pool_name, profile) do
    %Cable{
      pool_name: pool_name,
      pool_timeout: Keyword.get(profile, :pool_timeout),
      conn_timeout: Keyword.get(profile, :conn_timeout),
    }
  end

  @spec get_profile(atom()) :: profile()
  defp get_profile(profile_name) do
    default = [
      pool_timeout: 5_000,
      conn_timeout: 5_000,
      max_streams: 100,
      pool_size: 10,
      max_overflow: 0,
      conn_ttl: 10_000,
      conn_opts: %{}
    ]
    profiles = Application.get_env(:cables, :profiles, [])
    Keyword.merge(default, Keyword.get(profiles, profile_name, []))
  end
end
