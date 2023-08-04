defmodule Doku.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Doku.Finch},
      {Task.Supervisor, name: Doku.TaskSupervisor}
      # Doku.Repo
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Doku.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
