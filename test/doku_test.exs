defmodule DokuTest do
  use ExUnit.Case
  doctest Doku

  test "greets the world" do
    assert Doku.hello() == :world
  end
end
