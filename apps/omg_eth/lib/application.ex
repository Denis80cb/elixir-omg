defmodule OMG.Eth.Application do
  @moduledoc false
  use Application

  alias OMG.Eth

  def start(_type, _args) do
    children = [
      %{id: :exw3, start: {ExW3.Contract, :start_link, []}},
      %{
        id: :root_chain,
        # FIXME: may behave non-deterministically
        start: {OMG.Eth.RootChain, :register, []},
        restart: :transient
      }
    ]

    opts = [strategy: :rest_for_one, name: OMG.Eth.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
