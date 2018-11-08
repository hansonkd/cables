# Cables

*If Elixir has Plugs, where are the cables?*


## About

Cables is an HTTP/2 client for Elixir. It is designed to support multiple streams over one connection. Cables try its best to keep the minimum connections open at a time. Under load, it will automatically add new connections to the pool until it reaches the maximum number allowed. After a period of time, these extra connections are cleaned up and removed from the pool.

## HTTP/1.1 

Cables can also fall back to the older HTTP protocol. However, this will set the maximum number of streams at 1 and disable multiplexing.

## Performance


## Usage

Create a new connection pool:

```Elixir
cable = Cables.new("https://localhost:4003")
```
Perform a syncronous request. This will block until the connection is closed, the timeout is met or all data is recieved.
```Elixir
Cables.request(cable, :get, "/", [])
```

You can also specify asyncronous handlers. These will loop over chunks of data and a state.
```Elixir
defmodule SimpleRequest do
  use Cables.Handler
  
  def init(_) do
  
  end
  
  def handle_response(status, headers, state) do
  end
  
  def handle_data(data, state) do
  end
end
```

Call a handler
```Elixir
Cables.run_handler(cable, SimpleRequest, [])
```
