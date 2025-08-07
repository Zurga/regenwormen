defmodule Player do
  defstruct stack: [], strategy: RandomGreedy
end

defmodule HighestDieRatioGreedy do
  def next(game, thrown, eyes_to_take) do
    [{chosen, _ratio} | _] =
      eyes_to_take
      |> Enum.reduce(Map.from_keys(eyes_to_take, 0), fn
        6, acc -> Map.update!(acc, 6, &(&1 + 5))
        die, acc -> Map.update!(acc, die, &(&1 + die))
      end)
      |> Enum.sort_by(
        fn {die, points} -> points / (Enum.filter(eyes_to_take, &(&1 == die)) |> length) end,
        :desc
      )

    taken = Enum.filter(eyes_to_take, &(&1 == chosen))
    points = Game.points(thrown ++ taken)

    if points in game.stack or not is_nil(Game.steal_card(game, points)) do
      {taken, :keep}
    else
      {taken, :throw}
    end
  end
end

defmodule Random do
  def next(_game, _thrown, eyes_to_take) do
    chosen = Enum.random(eyes_to_take)
    taken = Enum.filter(eyes_to_take, &(&1 == chosen))

    {taken, :throw}
  end
end

defmodule RandomGreedy do
  def next(game, thrown, eyes_to_take) do
    chosen = Enum.random(eyes_to_take)
    taken = Enum.filter(eyes_to_take, &(&1 == chosen))
    points = Game.points(thrown ++ taken)

    if points in game.stack or not is_nil(Game.steal_card(game, points)) do
      {taken, :keep}
    else
      {taken, :throw}
    end
  end
end

defmodule Game do
  defstruct players: [], stack: 21..36 |> Enum.to_list(), current_player: 0, turns: 0

  def new(num_players) do
    players = Enum.map(0..(num_players - 1), &{&1, %Player{strategy: HighestDieRatioGreedy}}) |> Enum.into(%{})
    # players = %{0 => %Player{strategy: HighestDieRatioGreedy}, 1 => %Player{}, 2 => %Player{}}
    %__MODULE__{players: players}
  end

  def turn(%{stack: []} = game) do
    [{player, _score}| _] =
      game.players
      |> Enum.map(fn {player, data} -> {player, score(data.stack)} end)
      |> Enum.sort(&(elem(&1, 1) > elem(&2, 1)))

    player
  end

  def turn(%{players: players, current_player: current_player, stack: game_stack} = game) do
    %{stack: player_stack} = players[current_player]
    dice = throw_dice(game)

    if dice == :error do
      # IO.puts("invalid turn")

      case player_stack do
        [] ->
          game

        [player_card | player_stack] ->
          # If we put back the highest card, don't remove it
          game_stack =
            if Enum.filter(game_stack, &(&1 > player_card)) == [] do
              List.insert_at(game_stack, -1, player_card)
            else
              [player_card | game_stack] |> Enum.sort() |> List.delete_at(-1)
            end

          %{
            game
            | stack: game_stack,
              players: put_in(players, [current_player, Access.key!(:stack)], player_stack)
          }
      end
    else
      points = points(dice)

      # dice
      # |> IO.inspect(label: "thrown #{points}")

      # player_top_cards = game.players |> Enum.map(&hd(elem(&1, 1).stack))

      case steal_card(game, points) do
        nil ->
          chosen = Enum.filter(game_stack, &(&1 <= points)) |> Enum.at(-1)

          # IO.inspect("Player #{current_player} took #{inspect(chosen)} from stack")

          game
          |> put_in([Access.key!(:stack)], List.delete(game_stack, chosen))
          |> put_in([Access.key!(:players), current_player, Access.key!(:stack)], [
            chosen | player_stack
          ])

        other_player_index ->
          %{stack: [chosen | other_stack]} =  Map.get(players, other_player_index)

          # IO.inspect("Player #{current_player} stole #{chosen} from Player #{other_player_index}")

          players =
            players
            |> put_in([current_player, Access.key!(:stack)], [chosen | player_stack])
            |> put_in([other_player_index, Access.key!(:stack)], other_stack)

          %{game | players: players}
      end
    end
    |> set_current_player()
    |> turn()
  end

  def points(dice) do
    Enum.reduce(dice, 0, fn
      6, total -> total + 5
      die, total -> die + total
    end)
  end

  def score(stack) do
    points = %{
      (21..24) => 1,
      (25..28) => 2,
      (29..32) => 3,
      (33..36) => 4
    }

    for card <- stack, {range, points} <- points do
      if card in range do
        points
      else
        0
      end
    end
    |> Enum.sum()
  end

  def steal_card(game, points) do
    Enum.find_index(game.players, fn
      {_, %{stack: [^points | _]}} -> true
      {_, _} -> false
    end)
  end

  defp set_current_player(%{current_player: current, players: players} = game) do
    next = current + 1

    put_in(
      game,
      [Access.key!(:current_player)],
      if next > map_size(players) - 1 do
        0
      else
        next
      end
    )
    |> Map.update!(:turns, &(&1 + 1))
  end

  def throw_dice(game, amount_of_dice \\ 8, acc \\ [])

  def throw_dice(%{stack: stack} = game, 0, acc) do
    points = points(acc)
    possible = Enum.filter(stack, &(&1 <= points))

    if 6 not in acc or possible == [] or not is_nil(steal_card(game, points)) do
      :error
    else
      acc
    end
  end

  def throw_dice(game, amount_of_dice, acc) do
    player = game.players[game.current_player]
    thrown = for _ <- 0..amount_of_dice, do: Enum.random(1..6)
    eyes_to_take = thrown |> Enum.filter(&(&1 not in acc))

    if eyes_to_take == [] do
      :error
    else
      {taken, next} = player.strategy.next(game, acc, eyes_to_take)
      acc = acc ++ taken

      if next == :throw do
        throw_dice(game, amount_of_dice - length(taken), acc)
      else
        acc
      end
    end
  end
end

for _ <- 1..5000 do
  Game.new(4) |> Game.turn()
end
|> Enum.frequencies()
|> IO.inspect(label: :results)
