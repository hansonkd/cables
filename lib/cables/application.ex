defmodule Cables.Application do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Cabels.ConnPoolSupervisor}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end