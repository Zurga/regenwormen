defmodule Helpers do
  def crossover(%{__struct__: mod} = p1, p2, keys) do
    Enum.reduce(keys, struct(mod), fn {key, options}, acc ->
      if :rand.uniform() > 0.8 do
        Map.update!(acc, key, fn
          existing when is_list(existing) ->
            [Enum.random(options)]

          _ ->
            Enum.random(options)
        end)
      else
        parent = (:rand.uniform() > 0.5 && p1) || p2
        Map.put(acc, key, Map.get(parent, key))
      end
    end)
  end

  def dice_points(dice) do
    dice
    |> Enum.frequencies()
    |> Enum.map(fn {die, amount} -> {die, Game.points(die, amount)} end)
    |> Enum.into(%{})
  end

  def lowest_occurrence(dice, _thrown) do
    {chosen, _occurence} = sort_by_occurrence(dice) |> hd()
    chosen
  end

  def sort_by_occurrence(dice, order \\ :asc),
    do:
      dice
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), order)

  def sort_by_points(dice, order \\ :asc),
    do: dice |> dice_points() |> Enum.sort_by(&elem(&1, 1), order)
end

defmodule Strategy do
  import Helpers
  defp call_strategy(func, thrown, eyes_to_take) when is_atom(func) do
    apply(__MODULE__, func, [thrown, eyes_to_take])
  end

  defp call_strategy(%{__struct__: module} = strategy, thrown, eyes_to_take) do
    module.call(thrown, eyes_to_take, strategy)
  end

  def high_dice_ratio(thrown, dice) do
  {die, _ratio} =
    dice
    |> Enum.frequencies()
    |> Enum.map(fn {die, amount} -> {die, 1 - amount / Game.points(die, amount)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> hd()

  die
  end

  def early_worm(thrown, dice) do
    if 6 not in thrown and 6 in dice and length(Enum.filter(dice, &(&1 == 6))) > 1 do
      6
    else
      nil
    end
  end

  def highest_points(_thrown, dice) do
    [{chosen, _points} | _] = sort_by_points(dice, :desc)
    chosen
  end

  def random(_, dice), do: Enum.random(dice)

  def adaptive(game, points) do
    case game.players[game.current_player] do
      %{stack: []} -> greedy(game, points)
      %{stack: [high | _]} when high > 28 -> greedy(game, points)
      %{stack: [low | _]} when low <= 28 -> :throw
    end
  end

  def stealy(game, points) do
    if not is_nil(Game.steal_card(game, points)) do
      :keep
    else
      :throw
    end
  end

  def stacky(game, points) do
    if points in game.stack do
      :keep
    else
      :throw
    end
  end

  def greedy(game, points) do
    if points in game.stack or not is_nil(Game.steal_card(game, points)) do
      :keep
    else
      :throw
    end
  end

  def greedy_with_own(%{players: players, current_player: current_player} = game, points) do
    case players[current_player] do
      %{stack: []} ->
        greedy(game, points)

      %{stack: stack} ->
        if greedy(game, points) == :throw and points == hd(stack) do
          :keep
        else
          :throw
        end
    end
  end

  def decide(game, thrown, eyes_to_take, player) do
    break? =
      Enum.reduce_while(player.breakers || [], nil, fn
        nil, acc ->
          {:halt, acc}

        func, acc ->
          case apply(__MODULE__, func, [thrown, eyes_to_take]) do
            nil -> {:cont, acc}
            chosen -> {:halt, chosen}
          end
      end)

    {chosen, game} =
      case break? do
        nil -> {call_strategy(player.strategy, thrown, eyes_to_take), game}

        {chosen, statistic} -> game =  update_in(game, [Access.key!(:players), game.current_player, Access.key!(:statistics), statistic], & &1 || 0 + 1)
        {chosen, game}
        chosen ->
          {chosen, game}
      end

    taken = Enum.filter(eyes_to_take, &(&1 == chosen))
    points = Game.points(thrown ++ taken)

    if hold_or_not = player.hold do
      {taken, apply(__MODULE__, hold_or_not, [game, points]), game}
    else
      {taken, :throw, game}
    end
  end
end  

defmodule PreferSingle do
  import Helpers
  defstruct thrown: nil, break_point: nil, less_then: nil
  @args [thrown: 0..4//1, break_point: 1..16//1, less_then: 1..3//1]

  def new() do
    Enum.reduce(@args, %__MODULE__{}, fn {key, range}, acc ->
      Map.put(acc, key, Enum.random(range))
    end)
  end

  def call(thrown, dice, args) do
    [{lowest, _} | _] = sorted = sort_by_points(dice) 
    {highest, points} = Enum.reverse(sorted) |> hd()


    if length(thrown) < args.thrown and points < args.break_point and Enum.frequencies(dice)[highest] > args.less_then do
      # {lowest_occurrence(dice, thrown), :prefer_single}
      lowest
    else
      highest
    end
  end

  def crossover(args1, args2), do: Helpers.crossover(args1, args2, @args)
end

defmodule Player do
  defstruct age: 0,
            stack: [],
            breakers: [],
            strategy: :highest_points,
            hold: :greedy,
            amount_of_invalid: 0,
            amount_of_steal: 0,
            amount_of_stack: 0,
            total_best: 0,
            statistics: %{},
            wins: 0

  @strategy_options %{
    breakers: ~w/early_worm nil/a,
    strategy: [%PreferSingle{}], # ++ ~w/high_dice_ratio highest_points random/a,
    hold: ~w/greedy greedy_with_own stealy stacky adaptive nil/a
  }

  def random_new(players),
    do:
      Enum.reduce(@strategy_options, %__MODULE__{}, fn {key, options}, acc ->
        Map.update!(acc, key, fn
          existing when is_list(existing) ->
            [Enum.random(options)]

          _ ->
            case Enum.random(options) do
              %{__struct__: strategy} -> strategy.new()
              strategy -> strategy
            end
        end)
      end)
      |> then(fn player ->
        if Enum.map(players, &same?(player, elem(&1, 1))) |> Enum.any?() do
          random_new(players)
        else
          player
        end
      end)

  defp same?(player, other_player) do
    keys = Map.keys(@strategy_options)

    Enum.map([player, other_player], &Map.take(&1, keys))
    |> Enum.uniq()
    |> length() == 1
  end

  def crossover(%{strategy: %{__struct__: mod}} = p1, %{strategy: %{__struct__: mod}} = p2) do
    Map.put(Helpers.crossover(p1, p2, Map.delete(@strategy_options, :strategy)), :strategy, mod.crossover(p1.strategy, p2.strategy))
  end
  def crossover(p1, p2), do: Helpers.crossover(p1, p2, @strategy_options)


  def age(players) when is_list(players),
    do: Enum.map(players, &Map.update!(&1, :age, fn age -> age + 1 end))
end


defmodule Game do
  defstruct players: [], stack: 21..36 |> Enum.to_list(), current_player: 0, turns: 0, winner: nil

  def new(players) do
    # players = Enum.map(0..(num_players - 1), &{&1, %Player{}}) |> Enum.into(%{})
    # , 2 => %Player{}}
    %__MODULE__{players: players}
  end

  def run(%{stack: [], turns: turns} = game) when turns != 0 do
    scored =
      game.players
      |> Enum.map(fn {player, data} -> {player, score(data.stack)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case scored do
      [{_, score}, {_, score} | _] -> game
      [{player, _} | _] -> %{game | winner: player}
    end

    # |> IO.inspect(label: :done)
  end

  def run(game) do
    turn(game)
    |> run()
  end

  def turn(%{players: players, current_player: current_player, stack: game_stack} = game) do
    # IO.inspect(current_player, label: :Currnt)
    %{stack: player_stack} = players[current_player]
    {dice, game} = throw_dice(game)

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

          players =
            players
            |> put_in([current_player, Access.key!(:stack)], player_stack)
            |> update_in([current_player, Access.key!(:amount_of_invalid)], &(&1 + 1))

          %{game | stack: game_stack, players: players}
      end
    else
      points = points(dice)

      # dice
      # |> IO.inspect(label: "thrown #{points}")

      # player_top_cards = game.players |> Enum.map(&hd(elem(&1, 1).stack))

      case steal_card(game, points) do
        nil ->
          chosen = Enum.filter(game_stack, &(&1 <= points)) |> Enum.at(-1)

          if is_nil(chosen) do
            game
          else
            # IO.inspect("Player #{current_player} took #{inspect(chosen)} from stack")

            game
            |> put_in([Access.key!(:stack)], List.delete(game_stack, chosen))
            |> put_in([Access.key!(:players), current_player, Access.key!(:stack)], [
              chosen | player_stack
            ])
            |> update_in(
              [Access.key!(:players), current_player, Access.key!(:amount_of_stack)],
              &(&1 + 1)
            )
          end

        other_player_index ->
          %{stack: [chosen | other_stack]} = Map.get(players, other_player_index)

          # IO.inspect("Player #{current_player} stole #{chosen} from Player #{other_player_index}")

          players =
            players
            |> put_in([current_player, Access.key!(:stack)], [chosen | player_stack])
            |> update_in([current_player, Access.key!(:amount_of_steal)], &(&1 + 1))
            |> put_in([other_player_index, Access.key!(:stack)], other_stack)

          %{game | players: players}
      end
    end
    |> set_current_player()
  end

  def points(dice) when is_list(dice) do
    Enum.frequencies(dice)
    |> Enum.map(fn {die, amount} -> points(die, amount) end)
    |> Enum.sum()
  end

  def points(6, amount), do: 5 * amount
  def points(die, amount), do: die * amount

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

  def steal_card(%{current_player: current_player} = game, points) do
    Enum.find_index(game.players, fn
      {index, %{stack: [^points | _]}} when index != current_player -> true
      {_, _} -> false
    end)
  end

  defp set_current_player(%{current_player: current, players: players} = game) do
    next = current + 1

    put_in(game, [Access.key!(:current_player)], (next > map_size(players) - 1 && 0) || next)
    |> Map.update!(:turns, &(&1 + 1))
  end

  def throw_dice(game, amount_of_dice \\ 8, acc \\ [])

  def throw_dice(%{stack: game_stack} = game, 0, acc) do
    %{stack: player_stack, hold: hold} = game.players[game.current_player]
    points = points(acc)
    stack? = Enum.filter(game_stack, &(&1 <= points)) != []
    steal? = is_nil(steal_card(game, points))
    pass? = Enum.at(player_stack, 0) == points

    if 6 in acc and (stack? or steal? or pass?) do
      {acc, game}
    else
      {:error, game}
    end
  end

  def throw_dice(game, amount_of_dice, acc) do
    player = game.players[game.current_player]
    thrown = for _ <- 0..amount_of_dice, do: Enum.random(1..6)
    eyes_to_take = thrown |> Enum.filter(&(&1 not in acc))

    if eyes_to_take == [] do
      {:error, game}
    else
      {taken, next, game} = Strategy.decide(game, acc, eyes_to_take, player)
      acc = acc ++ taken

      if next == :throw do
        throw_dice(game, amount_of_dice - length(taken), acc)
      else
        {acc, game}
      end
    end
  end
end

defmodule Simulation do
  def run() do
    Enum.reduce(0..6, %{}, fn index, acc ->
      Map.put(acc, index, Player.random_new(acc))
    end)
    |> Map.put(7, %Player{})
    |> evaluate(0, 10)
  end

  def evaluate(players, current, max) do
    Enum.reduce(1..100, players, fn _, acc ->
      case Game.new(players) |> Game.run() do
        %{winner: nil} ->
          acc

        %{winner: index} = game ->
          update_in(acc, [index, Access.key!(:wins)], &((game.winner == index && &1 + 1) || &1))
      end
    end)
    |> mingle(current + 1, max)
  end

  def mingle(players, max, max) do
    players
    |> Enum.sort_by(&elem(&1, 1).wins, :desc)
    |> IO.inspect(label: :results)
  end

  def mingle(players, current, max) do
    [{_, best}, {_, second} | _] =
      Enum.sort_by(
        players,
        fn {_, player} ->
          player.wins * scale(player.total_best)
        end,
        :desc
      )

    num_players = map_size(players)

    offspring = [Player.crossover(best, second)]
    surviving = (increment([increment(best, :total_best), second], :age) ++ offspring)

      |> Enum.shuffle()
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {i, %{p | stack: [], wins: 0}} end)
      |> Enum.into(%{})

    Enum.reduce(map_size(surviving)..(num_players - 1), surviving, fn index, acc ->
      Map.put(acc, index, Player.random_new(acc))
    end)
    |> evaluate(current, max)
  end

  defp increment(enum, key) when is_list(enum), do: Enum.map(enum, &increment(&1, key))
  defp increment(value, key), do: Map.update!(value, key, &(&1 + 1))
  defp scale(0), do: 1
  defp scale(v), do: 1 + v * 0.1
end

Simulation.run()
