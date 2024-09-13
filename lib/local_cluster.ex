defmodule LocalCluster do
  @moduledoc """
  Easy local cluster handling for Elixir.

  This library is a utility library to offer easier testing of distributed
  clusters for Elixir. It offers very minimal shimming above several built
  in Erlang features to provide seamless node creations, especially useful
  when testing distributed applications.
  """
  import Record

  # a list of letters A - Z
  @alphabet Enum.to_list(?a..?z)

  # generally acceptable timeout
  @timeout :timer.seconds(30)

  # Cluster type
  @type t :: pid() | atom()

  # Cluster member
  @type member ::
          record(:member,
            pid: pid(),
            node: node()
          )

  # Cluster state
  @type state ::
          record(:state,
            index: integer(),
            prefix: binary(),
            members: [member()],
            options: Keyword.t()
          )

  # Cluster member record
  defrecord :member,
    pid: nil,
    node: nil

  defrecord :state,
    index: 0,
    prefix: nil,
    members: [],
    options: []

  ##############
  # Public API #
  ##############

  @doc """
  Starts the current node as a distributed node.
  """
  @spec start :: :ok
  def start do
    # boot server startup
    start_boot_server = fn ->
      # voodoo flag to generate a "started" atom flag
      :global_flags.once("local_cluster:started", fn ->
        {:ok, _} =
          :erl_boot_server.start([
            {127, 0, 0, 1}
          ])
      end)

      :ok
    end

    # only ever handle the :erl_boot_server on the initial startup
    case :net_kernel.start([:"manager@127.0.0.1"]) do
      # handle nodes that have already been started elsewhere
      {:error, {:already_started, _}} -> start_boot_server.()
      # handle nodes that have already been started elsewhere
      {:error, {{:already_started, _}, _}} -> start_boot_server.()
      # handle the node being started
      {:ok, _} -> start_boot_server.()
      # coveralls-ignore-next-line
      anything -> anything
    end
  end

  @doc """
  Starts a number of child nodes under a supervising process.

  This will start the current runtime enviornment on a set of child nodes
  and return the process identifier of the parent process. All child nodes
  will be linked to this parent process, and so will terminate once the
  parent process does.

  There are several options to provide when customizing the child nodes:

  ## Options

    * `:applications`

      The `:applications` option allows the caller to provide an ordered list
      of applications to be started on child nodes. This is useful when you
      need to control startup sequences, or omit applications completely. If
      this option is not provided, all currently loaded applications on the
      local node will be used as a default.

    * `:environment`

      The `:environment` option allows the caller to override application
      environment variables loaded on a member (via `Application.get_env/3`).

    * `:files`

      The `:files` option can be used to load additional files onto remote
      nodes, which are then compiled on the remote node. This is necessary
      if you wish to spawn tasks from inside test code, as test code would
      not typically be loaded automatically.

    * `:name`

      The `:name` option allows the caller to register the name of a local
      cluster should they wish to, rather than calling by pid.

    * `:prefix`

      The `:prefix` option allows the caller to choose the prefix name for
      the indexed nodes in a cluster. This is randomly generated if not
      provided.

  """
  @spec start_link(
          amount :: integer(),
          options :: Keyword.t()
        ) :: GenServer.on_start()
  def start_link(amount, opts \\ []) when is_integer(amount) and is_list(opts),
    do:
      GenServer.start_link(
        __MODULE__,
        {amount, opts},
        Keyword.take(opts, [:name])
      )

  @doc """
  Retrieves a child specification for a cluster.
  """
  @spec child_spec({integer(), Keyword.t()}) :: Supervisor.child_spec()
  def child_spec({amount, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [amount, opts]}
    }
  end

  @doc """
  Retrieves the node names within a cluster.
  """
  @spec nodes(cluster :: LocalCluster.t()) :: {:ok, [node()]}
  def nodes(cluster) when is_atom(cluster) or is_pid(cluster) do
    {:ok, members} = members(cluster)
    {:ok, Enum.map(members, &member(&1, :node))}
  end

  @doc """
  Retrieves the members within a cluster.
  """
  @spec members(cluster :: LocalCluster.t()) :: {:ok, [member()]}
  def members(cluster) when is_atom(cluster) or is_pid(cluster),
    do: {:ok, GenServer.call(cluster, :members, @timeout)}

  @doc """
  Retrieves the process identifiers within a cluster.
  """
  @spec pids(cluster :: LocalCluster.t()) :: [pid()]
  def pids(cluster) when is_atom(cluster) or is_pid(cluster) do
    {:ok, members} = members(cluster)
    {:ok, Enum.map(members, &member(&1, :pid))}
  end

  @doc """
  Starts new members within a cluster.
  """
  @spec start(cluster :: LocalCluster.t(), amount :: integer()) ::
          {:ok, [member()]}
  def start(cluster, amount) when is_integer(amount),
    do: GenServer.call(cluster, {:start, amount}, @timeout)

  @doc """
  Stops a previously started cluster.
  """
  @spec stop(cluster :: LocalCluster.t()) :: :ok
  def stop(cluster) when is_atom(cluster) or is_pid(cluster),
    do: GenServer.stop(cluster)

  @doc """
  Stops a member within a cluster.

  This will terminate the member node without terminating the rest
  of the cluster by unlinking it beforehand.
  """
  @spec stop(cluster :: LocalCluster.t(), member() | atom() | pid()) :: :ok
  def stop(cluster, member() = member),
    do: GenServer.call(cluster, {:stop, member}, @timeout)

  def stop(cluster, node) when is_atom(node),
    do: GenServer.call(cluster, {:stop, node}, @timeout)

  def stop(cluster, pid) when is_pid(pid),
    do: GenServer.call(cluster, {:stop, pid}, @timeout)

  @doc """
  Stops the current distributed node and turns it back into a local node.
  """
  @spec stop :: :ok | {:error, atom}
  def stop,
    # coveralls-ignore-next-line
    do: :net_kernel.stop()

  ##################
  # Implementation #
  ##################

  @doc false
  def init({amount, options}) do
    prefix =
      Keyword.get_lazy(options, :prefix, fn ->
        Keyword.get_lazy(options, :name, fn ->
          1..8
          |> Enum.map(fn _ -> Enum.random(@alphabet) end)
          |> List.to_string()
        end)
      end)

    state =
      state(
        prefix: prefix,
        members: [],
        options: options
      )

    add_members(state, amount)
  end

  @doc false
  # Simple handler to fetch all known cluster members.
  def handle_call(:members, _from, state(members: members) = state),
    do: {:reply, members, state}

  @doc false
  # Handled to enable adding new members to an existing cluster.
  def handle_call({:start, amount}, _from, state(members: m1) = state) do
    {:ok, state(members: m2) = modified} = add_members(state, amount)
    {:reply, {:ok, Enum.reduce(m1, m2, &List.delete(&2, &1))}, modified}
  end

  @doc false
  # Allows termination of a single member node without stopping the parent.
  def handle_call({:stop, member() = member}, _from, state) do
    handle_stop(state, fn
      ^member -> true
      _member -> false
    end)
  end

  def handle_call({:stop, node}, _from, state) when is_atom(node),
    do: handle_stop(state, &match?(member(node: ^node), &1))

  def handle_call({:stop, pid}, _from, state) when is_pid(pid),
    do: handle_stop(state, &match?(member(pid: ^pid), &1))

  @doc false
  def handle_call(_msg, _from, state),
    # coveralls-ignore-next-line
    do: {:reply, nil, state}

  defp handle_stop(state(members: members) = state, locator) do
    case Enum.find(members, locator) do
      nil ->
        {:reply, :ok, state}

      member(pid: pid) = member ->
        true = Process.unlink(pid)
        :ok = stop_member(member)

        {:reply, :ok, state(state, members: List.delete(members, member))}
    end
  end

  ###############
  # Private API #
  ###############

  # Attach members to a current set of members.
  defp add_members(state, amount) do
    state(index: index, prefix: prefix) = state
    state(members: current, options: options) = state

    members =
      Enum.map(1..amount, fn idx ->
        {:ok, pair} =
          start_member(
            ~c"127.0.0.1",
            :"#{prefix}#{index + idx}",
            Enum.map(
              ~w[-loader inet -hosts 127.0.0.1 -setcookie #{:erlang.get_cookie()}],
              &String.to_charlist/1
            )
          )

        pair
      end)

    nodes = Enum.map(members, &member(&1, :node))
    rpc = &({_, []} = :rpc.multicall(nodes, &1, &2, &3))

    rpc.(:code, :add_paths, [:code.get_path()])

    enviroment = Keyword.get(options, :environment, [])

    merged_config =
      Application.loaded_applications()
      |> Enum.map(fn {app_name, _, _} ->
        {app_name,
         Keyword.merge(
           Application.get_all_env(app_name),
           Keyword.get(enviroment, app_name, [])
         )}
      end)

    rpc.(:application, :set_env, [merged_config])

    rpc.(Application, :ensure_all_started, [[:mix, :logger]])

    rpc.(Logger, :configure, [[level: Logger.level()]])
    rpc.(Mix, :env, [Mix.env()])

    rpc.(Application, :ensure_all_started, [
      Keyword.get(options, :applications, [])
    ])

    for file <- Keyword.get(options, :files, []) do
      rpc.(Code, :require_file, [file])
    end

    new_members = current ++ members
    new_index = length(current ++ members)

    {:ok, state(state, index: new_index, members: new_members)}
  end

  # Handling of Erlang OTP changes prior to `:peer` being introduced
  if Code.ensure_loaded?(:peer) and function_exported?(:peer, :start_link, 1) do
    # Start a member using `:peer`.
    #
    # This is simple enough; turn the arguments into a map and pass through to
    # :peer.start_link/1 before mapping the result to a `member`.
    defp start_member(host, name, args) do
      # convert the arguments into a :peer map
      options = %{host: host, name: name, args: args}

      # pass through to :peer and map the result to a member
      with {:ok, pid, node} <- :peer.start_link(options) do
        {:ok, member(pid: pid, node: node)}
      end
    end

    # Stops a member using `:peer`.
    def stop_member(member(pid: pid)),
      do: :peer.stop(pid)
  else
    # Start a member using `:slave`.
    #
    # A little more complicated than `:peer` as we have to track the processes
    # currently linked to this process between each call. We map these pids
    # back into the state of the cluster before passing back as a member.
    defp start_member(host, name, args) do
      # join the args list into a string
      param = :string.join(args, ~c" ")

      # current links
      links =
        self()
        |> :erlang.process_info(:links)
        |> elem(1)

      # pass through to :slave and map the result to a member
      with {:ok, node} <- :slave.start_link(host, name, param) do
        # fetch the list of known links after adding a node
        {:links, nlinks} = :erlang.process_info(self(), :links)

        # ignore all previously known pids
        [pid] =
          Enum.reject(nlinks, fn elem ->
            Enum.member?(links, elem)
          end)

        # convert back over to a member
        {:ok, member(pid: pid, node: node)}
      end
    end

    # Stops a member using `:slave`.
    def stop_member(member(node: node)),
      do: :slave.stop(node)
  end
end
