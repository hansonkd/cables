defmodule Cables do
  @moduledoc """
  Asynchronous multiplexed HTTP/2 connection manager.

  Create a new Cable using `Cable.new_pool/2`. Cables will not open a connection
  until the first request is recieved.

  ## Examples
      {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      {:ok, %Cables.Response{status: 200}} = Cables.get(cable, "/httpbin/get")
  """

  @type profile() :: [
    pool_timeout: integer(),
    connection_timeout: integer(),
    threshold: integer(),
    max_requests: integer(),
    max_streams: integer(),
    max_connections: integer(),
    min_connections: integer(),
    connnection_ttl: integer(),
    connection_opts: map()
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
    defstruct [:pool_name, :pool_timeout, :connection_timeout]
  end

  @doc """
  If a pool is not already created for the specified uri, create one.
  """
  @spec new_pool(String.t(), atom()) :: Cabel.t()
  def new_pool(uri, profile_name \\ :default) do
    %URI{host: host, scheme: scheme, port: port} = URI.parse(uri)

    profile = get_profile(profile_name)
    conn_opts = conn_opts(scheme, profile)

    {:ok, pid} = DynamicSupervisor.start_child(
      Cabels.ConnPoolSupervisor,
      {Cables.Pool, Keyword.merge(profile, [connection_opts: conn_opts, host: to_charlist(host), port: port])}
    )
    {:ok, make_cable(pid, profile)}
  end

  @doc """
  Start a request and handle it with the request_handler. `Cables.Handler`
  This gives you full control over sending and recieving stream data.

  For an example see `Cables.Response`.

  ## Examples

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.request(cable, :get, "/httpbin/get", Cables.Response, nil)
      ...> status
      200
  """
  @spec request(Cabel.t(), http_method(), String.t, [{String.t, String.t}], String.t, pid(), module(), any()) :: t::any()
  def request(%Cable{pool_name: pool, pool_timeout: pool_timeout, connection_timeout: timeout}, method, path, headers \\ [], body \\ "", reply_to \\ nil, module, init_args) do
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

    request = %Request{
      method: method_str,
      path: path,
      headers: headers,
      body: body,
      reply_to: if is_nil(reply_to) do self() else reply_to end
    }

    {gun_pid, stream_ref} = Cables.Pool.request_stream(pool, request, pool_timeout)


    try do
      module.handle(gun_pid, stream_ref, timeout, init_args)
    after
      Cables.Pool.finish_stream(pool, gun_pid, stream_ref)
    end
  end

  @doc """
  Simple GET request with `Cables.Response`

  ## Examples

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.get(cable, "/httpbin/get")
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

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.post(cable, "/httpbin/post", [], "hello world")
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

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.put(cable, "/httpbin/put", [], "hello world")
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

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.patch(cable, "/httpbin/patch", [], "hello world")
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

      iex> {:ok, cable} = Cables.new_pool("https://nghttp2.org/")
      ...> {:ok, %Cables.Response{status: status}} = Cables.delete(cable, "/httpbin/delete")
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

  @spec conn_opts(String.t(), profile()) :: map()
  defp conn_opts(scheme, profile) do
    transport =
      case scheme do
        "https" -> :tls
        _ -> :tcp
      end
    Map.merge(%{transport: transport}, Keyword.get(profile, :connection_opts))
  end

  @spec make_cable(atom(), profile()) :: Cable.t()
  defp make_cable(pool_name, profile) do
    %Cable{
      pool_name: pool_name,
      pool_timeout: Keyword.get(profile, :pool_timeout),
      connection_timeout: Keyword.get(profile, :connection_timeout),
    }
  end

  @spec get_profile(atom()) :: profile()
  defp get_profile(profile_name) do
    defaults = [
      pool_timeout: 5_000,
      connection_timeout: 5_000,
      threshold: 10,
      max_requests: :infinity,
      max_streams: 100,
      max_connections: 10,
      min_connections: 1,
      connection_ttl: 10_000,
      connection_opts: %{}
    ]
    profiles = Application.get_env(:cables, :profiles, [])
    profile = case profile_name do
      :default -> Keyword.get(profiles, profile_name, [])
      _ -> Keyword.fetch!(profiles, profile_name)
    end
    profile = Keyword.merge(defaults, profile)
    threshold = min(Keyword.fetch!(profile, :threshold), Keyword.fetch!(profile, :max_streams))
    min_connections = min(Keyword.fetch!(profile, :min_connections), Keyword.fetch!(profile, :max_connections))
    profile
    |> Keyword.put(:threshold, threshold)
    |> Keyword.put(:min_connections, min_connections)
  end
end
