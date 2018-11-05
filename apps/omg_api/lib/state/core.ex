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

defmodule OMG.API.State.Core do
  @moduledoc """
  Functional core for State.
  """

  require Logger

  @maximum_block_size 65_536

  defstruct [:height, :last_deposit_child_blknum, :utxos, pending_txs: [], tx_index: 0]

  alias OMG.API.Block
  alias OMG.API.Crypto
  alias OMG.API.State.Core
  alias OMG.API.State.Transaction
  alias OMG.API.Utxo
  require Utxo

  @type t() :: %__MODULE__{
          height: non_neg_integer(),
          last_deposit_child_blknum: non_neg_integer(),
          utxos: utxos,
          pending_txs: list(Transaction.Recovered.t()),
          tx_index: non_neg_integer()
        }

  @type deposit() :: %{
          blknum: non_neg_integer(),
          currency: Crypto.address_t(),
          owner: Crypto.address_t(),
          amount: pos_integer()
        }
  @type exit_t() :: %{
          utxo_pos: pos_integer(),
          token: Crypto.address_t(),
          owner: Crypto.address_t(),
          amount: pos_integer()
        }

  @type utxos() :: %{Utxo.Position.t() => Utxo.t()}

  @type exec_error ::
          :incorrect_spender
          | :incorrect_currency
          | :amounts_dont_add_up
          | :invalid_current_block_number
          | :utxo_not_found

  @type deposit_event :: %{deposit: %{amount: non_neg_integer, owner: Crypto.address_t()}}
  @type exit_event :: %{
          exit: %{owner: Crypto.address_t(), blknum: pos_integer, txindex: non_neg_integer, oindex: non_neg_integer}
        }
  @type tx_event :: %{tx: Transaction.Recovered.t(), child_blknum: pos_integer, child_block_hash: Block.block_hash_t()}

  @type db_update ::
          {:put, :utxo, {{pos_integer, non_neg_integer, non_neg_integer}, map}}
          | {:delete, :utxo, {pos_integer, non_neg_integer, non_neg_integer}}
          | {:put, :child_top_block_number, pos_integer}
          | {:put, :last_deposit_child_blknum, pos_integer}
          | {:put, :block, Block.t()}

  @spec extract_initial_state(
          utxos_query_result :: [utxos],
          height_query_result :: non_neg_integer | :not_found,
          last_deposit_child_blknum_query_result :: non_neg_integer | :not_found,
          child_block_interval :: pos_integer
        ) :: {:ok, t()} | {:error, :last_deposit_not_found | :top_block_number_not_found}
  def extract_initial_state(
        utxos_query_result,
        height_query_result,
        last_deposit_child_blknum_query_result,
        child_block_interval
      )
      when is_list(utxos_query_result) and is_integer(height_query_result) and
             is_integer(last_deposit_child_blknum_query_result) and is_integer(child_block_interval) do
    # extract height, last deposit height and utxos from query result
    height = height_query_result + child_block_interval

    utxos =
      Enum.reduce(utxos_query_result, %{}, fn {raw_position, raw_utxo}, acc_map ->
        {blknum, txindex, oindex} = raw_position
        %{owner: owner, currency: currency, amount: amount} = raw_utxo
        new_position = Utxo.position(blknum, txindex, oindex)
        new_utxo = %Utxo{owner: owner, currency: currency, amount: amount}
        Map.put(acc_map, new_position, new_utxo)
      end)

    state = %__MODULE__{
      height: height,
      last_deposit_child_blknum: last_deposit_child_blknum_query_result,
      utxos: utxos
    }

    {:ok, state}
  end

  def extract_initial_state(
        _utxos_query_result,
        _height_query_result,
        :not_found,
        _child_block_interval
      ) do
    {:error, :last_deposit_not_found}
  end

  def extract_initial_state(
        _utxos_query_result,
        :not_found,
        _last_deposit_child_blknum_query_result,
        _child_block_interval
      ) do
    {:error, :top_block_number_not_found}
  end

  @doc """
  Includes the transaction into the state when valid, rejects otherwise.

  NOTE that tx is assumed to have distinct inputs, that should be checked in prior state-less validation
  """
  @spec exec(tx :: Transaction.Recovered.t(), fees :: map(), state :: t()) ::
          {:ok, {Transaction.Recovered.signed_tx_hash_t(), pos_integer, pos_integer}, t()}
          | {{:error, exec_error}, t()}
  def exec(
        %Transaction.Recovered{
          signed_tx: %Transaction.Signed{raw_tx: raw_tx}
        } = recovered_tx,
        fees,
        state
      ) do
    with :ok <- validate_block_size(state),
         {:ok, input_amounts_by_currency} <- correct_inputs?(state, recoverd_tx),
         :ok <- amounts_add_up?(input_amounts_by_currency, recovered_tx, fees) do
      {:ok, {recovered_tx.signed_tx_hash, state.height, state.tx_index},
       state
       |> apply_spend(raw_tx)
       |> add_pending_tx(recovered_tx)}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  defp add_pending_tx(%Core{pending_txs: pending_txs, tx_index: tx_index} = state, new_tx) do
    %Core{
      state
      | tx_index: tx_index + 1,
        pending_txs: [new_tx | pending_txs]
    }
  end

  defp correct_inputs?(
         %Core{utxos: utxos} = state,
         %Transaction.Recovered{
           signed_tx: %Transaction.Signed{raw_tx: raw_tx}
         } = recovered_tx,
         spenders
       ) do
    inputs = Transaction.get_inputs(raw_tx)

    with :ok <- inputs_not_from_future_block?(state, inputs),
         {:ok, inputs} <- inputs_belong_to_spenders?(utxos, inputs) do
      {:ok, get_amounts_by_currency(inputs)}
    end
  end

  defp inputs_not_from_future_blocks?(%__MODULE__{height: blknum}, inputs) do
    no_utxo_from_future_block =
      inputs
      |> Enum.all?(fn [blknum: input_blknum] -> blknum >= input_blknum end)

    if no_utxo_from_future_block, do: :ok, else: {:error, :input_utxo_ahead_of_state}
  end

  defp inputs_belong_to_spenders?(
         utxos,
         %Transaction.Recovered{
           signed_tx: %Transaction.Signed{raw_tx: raw_tx}
         } = recovered_tx
       ) do
    inputs = Transaction.get_inputs(raw_tx)

    with {:ok, input_utxos} <- get_input_utxos(utxos, inputs),
         input_utxos_owners <- Enum.map(input_utxos, fn %{owner: owner} -> owner end),
         :authorized <- Transaction.Recovered.spent_authorized?(recovered_tx, input_utxos_owners) do
      {:ok, input_utxos}
    end
  end

  defp get_input_utxos(utxos, inputs) do
    input_utxos =
      for %{blknum: blknum, txindex: txindex, oindex: oindex} <- inputs do
        get_utxo(utxos, Utxo.position(blknum, txindex, oindex))
      end

    input_utxos
    |> Enum.reduce([], &extract_utxo_or_error/2)
  end

  defp extract_utxo_or_error({:ok, input_utxos}, {:ok, input_utxo}), do: {:ok, [input_utxo | input_utxos]}

  defp extract_utxo_or_error({:ok, input_utxos}, {:error, _} = error), do: error

  defp extract_utxo_or_error({:error, _} = error, _), do: error

  defp get_utxo(utxos, position) do
    case Map.get(utxos, position) do
      nil -> {:error, :utxo_not_found}
      found -> {:ok, found}
    end
  end

  defp get_amounts_by_currency(utxos) do
    utxos
    |> Enum.group_by(fn %{currency: currency} -> currency end)
    |> Enum.map(fn amounts -> Enum.reduce(amounts, 0, fn amount, acc -> amount + acc end) end)
  end

  # fee is implicit - it's the difference between funds owned and spend
  defp amounts_add_up?(has, spends) do
    if has >= spends, do: :ok, else: {:error, :amounts_dont_add_up}
  end

  defp apply_spend(
         %Core{height: height, tx_index: tx_index, utxos: utxos} = state,
         %Transaction{inputs: inputs} = tx
       ) do
    new_utxos_map =
      tx
      |> non_zero_utxos_from(height, tx_index)
      |> Map.new()

    utxos =
      inputs
      |> Enum.reduce(utxos, fn [blknum: blknum, txindex: txindex, oindex: oindex], utxos ->
        Map.delete(utxos, Utxo.position(blknum, txindex, oindex))
      end)

    %Core{state | utxos: Map.merge(utxos, new_utxos_map)}
  end

  defp non_zero_utxos_from(%Transaction{} = tx, height, tx_index) do
    tx
    |> utxos_from(height, tx_index)
    |> Enum.filter(fn {_key, value} -> is_non_zero_amount?(value) end)
  end

  defp utxos_from(%Transaction{outputs: outputs} = tx, height, tx_index) do
    for {[owner: owner, currency: currency, amount: amount], oindex} <- Enum.with_index(outputs) do
      {Utxo.position(height, tx_index, oindex), %Utxo{owner: owner, currency: currency, amount: amount}}
    end
  end

  defp is_non_zero_amount?(%{amount: 0}), do: false
  defp is_non_zero_amount?(%{amount: _}), do: true

  @doc """
   - Generates block and calculates it's root hash for submission
   - generates triggers for events
   - generates requests to the persistence layer for a block
   - processes pending txs gathered, updates height etc
  """
  @spec form_block(pos_integer(), state :: t()) :: {:ok, {Block.t(), [tx_event], [db_update]}, new_state :: t()}
  def form_block(child_block_interval, %Core{pending_txs: reverse_txs, height: height} = state) do
    txs = Enum.reverse(reverse_txs)

    block = txs |> Block.hashed_txs_at(height)

    event_triggers =
      txs
      |> Enum.map(fn tx ->
        %{tx: tx, child_blknum: block.number, child_block_hash: block.hash}
      end)

    db_updates_new_utxos =
      txs
      |> Enum.with_index()
      |> Enum.flat_map(fn {%Transaction.Recovered{signed_tx: %Transaction.Signed{raw_tx: tx}}, tx_idx} ->
        non_zero_utxos_from(tx, height, tx_idx)
      end)
      |> Enum.map(&utxo_to_db_put/1)

    db_updates_spent_utxos =
      txs
      |> Enum.flat_map(fn %Transaction.Recovered{signed_tx: %Transaction.Signed{raw_tx: tx}} ->
        [Utxo.position(tx.blknum1, tx.txindex1, tx.oindex1), Utxo.position(tx.blknum2, tx.txindex2, tx.oindex2)]
      end)
      |> Enum.filter(fn position -> position != Utxo.position(0, 0, 0) end)
      |> Enum.map(fn Utxo.position(blknum, txindex, oindex) -> {:delete, :utxo, {blknum, txindex, oindex}} end)

    db_updates_block = [{:put, :block, block}]

    db_updates_top_block_number = [{:put, :child_top_block_number, height}]

    db_updates =
      [db_updates_new_utxos, db_updates_spent_utxos, db_updates_block, db_updates_top_block_number]
      |> Enum.concat()

    new_state = %Core{
      state
      | tx_index: 0,
        height: height + child_block_interval,
        pending_txs: []
    }

    {:ok, {block, event_triggers, db_updates}, new_state}
  end

  @spec deposit(deposits :: [deposit()], state :: t()) :: {:ok, {[deposit_event], [db_update]}, new_state :: t()}
  def deposit(deposits, %Core{utxos: utxos, last_deposit_child_blknum: last_deposit_child_blknum} = state) do
    deposits = deposits |> Enum.filter(&(&1.blknum > last_deposit_child_blknum))

    new_utxos =
      deposits
      |> Enum.map(&deposit_to_utxo/1)

    event_triggers =
      deposits
      |> Enum.map(fn %{owner: owner, amount: amount} -> %{deposit: %{amount: amount, owner: owner}} end)

    last_deposit_child_blknum = get_last_deposit_child_blknum(deposits, last_deposit_child_blknum)

    db_updates_new_utxos =
      new_utxos
      |> Enum.map(&utxo_to_db_put/1)

    db_updates = db_updates_new_utxos ++ last_deposit_child_blknum_db_update(deposits, last_deposit_child_blknum)

    _ = if deposits != [], do: Logger.info(fn -> "Recognized deposits #{inspect(deposits)}" end)

    new_state = %Core{
      state
      | utxos: Map.merge(utxos, Map.new(new_utxos)),
        last_deposit_child_blknum: last_deposit_child_blknum
    }

    {:ok, {event_triggers, db_updates}, new_state}
  end

  defp utxo_to_db_put({Utxo.position(blknum, txindex, oindex), %Utxo{} = utxo}),
    do: {:put, :utxo, {{blknum, txindex, oindex}, Map.from_struct(utxo)}}

  defp deposit_to_utxo(%{blknum: blknum, currency: cur, owner: owner, amount: amount}) do
    {Utxo.position(blknum, 0, 0), %Utxo{amount: amount, currency: cur, owner: owner}}
  end

  defp get_last_deposit_child_blknum(deposits, current_height) do
    if Enum.empty?(deposits) do
      current_height
    else
      deposits
      |> Enum.max_by(& &1.blknum)
      |> Map.get(:blknum)
    end
  end

  defp last_deposit_child_blknum_db_update(deposits, last_deposit_child_blknum) do
    if Enum.empty?(deposits) do
      []
    else
      [{:put, :last_deposit_child_blknum, last_deposit_child_blknum}]
    end
  end

  defp validate_block_size(%__MODULE__{tx_index: number_of_transactions_in_block}) do
    case number_of_transactions_in_block == @maximum_block_size do
      true -> {:error, :too_many_transactions_in_block}
      false -> :ok
    end
  end

  @doc """
  Spends exited utxos
  """
  @spec exit_utxos(exiting_utxos :: [exit_t], state :: t()) :: {:ok, {[exit_event], [db_update]}, new_state :: t()}
  def exit_utxos(exiting_utxos, %Core{utxos: utxos} = state) do
    exiting_utxos =
      exiting_utxos
      |> Enum.filter(&utxo_exists?(&1, state))

    event_triggers =
      exiting_utxos
      |> Enum.map(fn %{owner: owner, utxo_pos: utxo_pos} ->
        %{exit: %{owner: owner, utxo_pos: Utxo.Position.decode(utxo_pos)}}
      end)

    new_state = %{
      state
      | utxos:
          Enum.reduce(exiting_utxos, utxos, fn %{utxo_pos: utxo_pos}, utxos ->
            Map.delete(utxos, Utxo.Position.decode(utxo_pos))
          end)
    }

    deletes =
      exiting_utxos
      |> Enum.map(fn %{utxo_pos: utxo_pos} ->
        {:utxo_position, blknum, txindex, oindex} = Utxo.Position.decode(utxo_pos)
        {:delete, :utxo, {blknum, txindex, oindex}}
      end)

    {:ok, {event_triggers, deletes}, new_state}
  end

  @doc """
  Checks if utxo exists
  """
  @spec utxo_exists?(exit_t, t()) :: boolean()
  def utxo_exists?(%{utxo_pos: utxo_pos} = _exiting_utxo, %Core{utxos: utxos}) do
    Map.has_key?(utxos, Utxo.Position.decode(utxo_pos))
  end

  @doc """
      Gets the current block's height and whether at the beginning of the block
  """
  @spec get_status(t()) :: {current_block_height :: non_neg_integer(), is_block_beginning :: boolean()}
  def get_status(%__MODULE__{height: height, tx_index: tx_index, pending_txs: pending}) do
    is_beginning = tx_index == 0 && Enum.empty?(pending)
    {height, is_beginning}
  end
end
