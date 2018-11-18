# Cables

An experimental asynchronous multiplexed HTTP/2 Client for Elixir. Streams are consumed by
modules implementing `Cables.Handler` which build a state by looping over chunks
of data returned by the request.

You can either implement the handler yourself or use the convience methods
`Cables.get/4`, `Cables.post/5`, `Cables.patch/5`, `Cables.put/5`,
`Cables.delete/5` and `Cables.head/4`

### Docs

[https://hexdocs.pm/cables](https://hexdocs.pm/cables/readme.html)

### Multiplexing

Multiple streams are multiplexed over a single connection. Cables do not wait
for the response to be recieved before sending another request.

### Multiple Connections

Even though multiple requests can be piped through a single connection, sometimes
opening more connections will substantially increase performance. Cables will automatically open new connections as load is detected.

### Persistent Connections

Cables will open a persistent connection using [gun](https://github.com/ninenines/gun).
Gun will attempt to keep the connection open and reopen if it goes down. Sometimes this is not always wanted. Cables will close connections after the TTL (specified in the profile option `connection_ttl`) passes.

### Handlers

The `Cables.Handler` flow starts with `init/3` being called and returning the initial state or an error. In `init/3`,
additional data can be sent with the request by using `Cabels.send_data/2` and `Cabels.send_final_data/2`.

After getting the new state we wait until we recieve the headers. `handle_headers/3` will be called with the
status, headers and the state taken from `init/3`. A new state should be returned.

After processing the headers, `handle_data/2` will loop until there is no more response data. Each call to `handle_data/2` should return a new state for the loop.

After all response data is recieved, `handle_finish/1` will be called with the state from `handle_data/2` to finish any processing before passing it back.


## Example Plug Proxy

This example shows how to use the streaming capabilities to incrementally Proxy a request from `Plug.Conn` to a remote HTTP connection.

```elixir
defmodule PlugProxy do
  use Cables.Handler

  def init(gun_pid, stream_ref, {conn, read_opts}) do
    forward_request_data(conn, gun_pid, stream_ref, read_opts)
  end

  def forward_request_data(conn, gun_pid, stream_ref, read_opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, binary, conn} ->
        :ok = Cables.send_final_data(gun_pid, stream_ref, binary)
        conn
      {:more, binary, conn} ->
        :ok = Cables.send_data(gun_pid, stream_ref, binary)
        forward_request_data(conn, gun_pid, stream_ref, read_opts)
    end
  end

  def handle_headers(status, headers, conn) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.send_chunked(status)
  end

  def handle_data(chunk, conn) do
    {:ok, conn} = Plug.Conn.chunk(conn, chunk)
    conn
  end

  def handle_finish(conn) do
    {:ok, conn}
  end
end

{:ok, cable} = Cables.new_pool("https://nghttp2.org/")
# ... Somewhere in your Plug
{:ok, conn} = Cables.request(
  cable, conn.method, conn.path, conn.headers, PlugProxy, {conn, [length: 1024, read_length: 1024]}
)
```

### Profiles

Connection configurations are backed by profiles the default profile is:

```elixir
[
  # How long to wait in milliseconds for a connection from the pool
  pool_timeout: 5_000,
  # How long to wait in milliseconds for a response.
  conn_timeout: 5_000,
  # When all connections have this many streams, open a new connection.
  threshold: 10,
  # How many requests to serve on a connection before closing
  max_requests: :infinity,
  # Maximum number of streams per connection
  max_streams: 100,
  # Maximum number of connections
  max_connections: 10,
  # Minimum number of connections to hold open
  min_connections: 1,
  # Time in milliseconds that should pass without a request before the connection is closed
  connection_ttl: 10_000,
  # Extra connection options to pass to `:gun.open/3`
  connection_opts: %{}
]
```

You can override the default profile or create a new one by creating an entry in your `config/*.exs` file

```elixir
config :cables,
  profiles: [
    default: [
      max_streams: 1000
    ],
    slow_connection: [
      connection_timeout: 10_000
    ]
  ]
```

Then pass the profile into `Cables.new_pool/2`

```elixir
{:ok, slow_pool} = Cables.new_pool("https://myslowsite", :slow_connection)
```

### HTTP Fallback
Cables will work with the previous version of HTTP, however you should specify a
profile with `max_streams` set to 1 to prevent multiplexing.

```elixir
config :cables,
  profiles: [
    http: [
      max_streams: 1
    ]
  ]

...

{:ok, http_cable} = Cables.new_pool("https://httpbin.com/", :http)
```

## Benchmarks

Cables client wasn't built out of a need for speed, but rather it was made from necessity to base new applications around low-level parallel long-lived HTTP/2 streams with few connections. That being said, the client that resulted has very good performance characteristics.

Since any new HTTP client would be incomplete without a comparison. A hastely put together benchmark can be found at [CablesBenchmark](http://github.com/hansonkd/cables_benchmark). The basic conclusion is that Cables can be up to 10-30% faster than HTTPoison/hackney (HTTP/1.1)'s connection pools while maintaining a fraction of the connections. Even when Cables are limited to 1 stream per connection, they will in general outperform HTTPoison. When pushing 10,000 requests down 1 connection with 1 stream, Cables are about 2x faster than HTTPoison.

The benchmark is very naive and is done with the client on the same machine as the server. Over a network, I would expect HTTP/2 performance to continue to outpace HTTP/1.1, but that is an exercise for another day.

*Notes: Hackney actually verifies the SSL certs and is in general a more robust HTTP client. If you need to use something in production, use HTTPosion or Hackney*

## Work that needs to be done

The pool is very naive. It is based around searching over a Map structure and in Elixir Maps have no defined order which complicates how the requests are distributed among the connections.

When there is a spurt of new requests (requests added faster than the time it takes to connect) when the current connections are past their threshold (or there are not current connections), Cables will open all available connections. This isn't ideal if you add 10 requests to the queue at once because it will open 10 new connections in anticipation of more requests later. We should add the option to limit the rate of new connections created.

## Installation

The package can be installed by adding `cables` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cables, "~> 0.1.1"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/cables](https://hexdocs.pm/cables/readme.html).
