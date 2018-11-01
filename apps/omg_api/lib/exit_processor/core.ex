# Copyright 2018 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.API.ExitProcessor.Core do
  @moduledoc """
  The functional, zero-side-effect part of the exit processor. Logic should go here:
    - orchestrating the persistence of the state
    - finding invalid exits, disseminating them as events according to rules
    - MoreVP protocol managing should go here
  """

  alias OMG.API.Crypto
  alias OMG.API.Utxo
  alias OMG.Watcher.Eventer.Event

  use OMG.API.LoggerExt

  @default_sla_margin 10

  defstruct [:sla_margin, exits: %{}]

  @type t :: %__MODULE__{exits: map}

  @doc """
  Reads database-specific list of exits and turns them into current state
  """
  @spec init(db_exits :: [{Utxo.Position.t(), {non_neg_integer, Crypto.address_t(), Crypto.address_t()}}]) :: {:ok, t()}
  def init(db_exits, sla_margin \\ @default_sla_margin) do
    {:ok,
     %__MODULE__{
       exits:
         db_exits
         |> Enum.into(%{}, fn {utxo_pos, {amount, currency, owner, eth_height}} ->
           {utxo_pos, %{amount: amount, currency: currency, owner: owner, eth_height: eth_height}}
         end),
       sla_margin: sla_margin
     }}
  end

  @doc """
  Add new exits from Ethereum events into tracked state
  """
  @spec new_exits(t(), [map()]) :: {t(), list()}
  def new_exits(%__MODULE__{exits: exits} = state, new_exits) do
    # FIXME eth_height missing from the eth event information
    new_exits_kv_pairs =
      new_exits
      |> Enum.map(fn %{utxo_pos: utxo_pos} = exit_info ->
        {Utxo.Position.decode(utxo_pos), Map.delete(exit_info, :utxo_pos)}
      end)

    db_updates =
      new_exits_kv_pairs
      |> Enum.map(fn {utxo_pos, %{amount: amount, currency: currency, owner: owner, eth_height: eth_height}} ->
        {:put, utxo_pos, {amount, currency, owner, eth_height}}
      end)

    new_exits_map = Map.new(new_exits_kv_pairs)

    {%{state | exits: Map.merge(exits, new_exits_map)}, db_updates}
  end

  @doc """
  Finalize exits based on Ethereum events, removing from tracked state
  """
  def finalize_exits(%__MODULE__{} = state, exits) do
    finalizing_positions =
      exits
      |> Enum.map(fn %{utxo_pos: utxo_pos} = _finalization_info -> Utxo.Position.decode(utxo_pos) end)

    db_updates =
      finalizing_positions
      |> Enum.map(fn utxo_pos -> {:delete, utxo_pos} end)

    {state, db_updates, finalizing_positions}
  end

  @doc """
  All the active exits, in-flight exits, exiting output piggybacks etc., based on the current tracked state
  """
  @spec get_exiting_utxo_positions(t()) :: list
  def get_exiting_utxo_positions(%__MODULE__{exits: exits} = _state) do
    Map.keys(exits)
  end

  @doc """
  Based on the result of exit validity (utxo existence), return invalid exits or appropriate notifications

  NOTE: We're using `ExitStarted`-height with `sla_exit_margin` added on top, to determine old, unchallenged invalid
        exits. This is different than documented, according to what we ought to be using
        `exitable_at - sla_exit_margin_s` to determine such exits.

  NOTE: If there were any exits unchallenged for some time in chain history, this might detect breach of SLA,
        even if the exits were eventually challenged (e.g. during syncing)
  """
  @spec invalid_exits(list, t(), pos_integer) :: {list, list}
  def invalid_exits(utxo_exists_result, %__MODULE__{exits: exits, sla_margin: sla_margin} = state, eth_height_now) do
    exiting_utxo_positions = get_exiting_utxo_positions(state)

    invalid_exit_positions =
      utxo_exists_result
      |> Enum.zip(exiting_utxo_positions)
      |> Enum.filter(fn {exists, _} -> !exists end)
      |> Enum.map(fn {_, position} -> position end)

    # get exits which are still invalid and after the SLA margin
    has_no_late_invalid_exits =
      exits
      |> Map.take(invalid_exit_positions)
      |> Map.values()
      |> Enum.map(& &1.eth_height)
      |> Enum.filter(&(&1 + sla_margin <= eth_height_now))
      |> Enum.empty?()

    events =
      invalid_exit_positions
      |> Enum.map(fn position -> {:invalid_exit, position} end)

    events =
      if has_no_late_invalid_exits,
        do: events,
        else: [
          # FIXME: temporary reuse of slightly different event with same effect. New event needs to be defined
          %Event.InvalidBlock{
            error_type: :unchallenged_exit,
            hash: nil,
            number: nil
          }
          | events
        ]

    {events, invalid_exit_positions}
  end
end
