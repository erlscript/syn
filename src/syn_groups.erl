%% ==========================================================================================================
%% Syn - A global Process Registry and Process Group manager.
%%
%% The MIT License (MIT)
%%
%% Copyright (c) 2015-2019 Roberto Ostinelli <roberto@ostinelli.net> and Neato Robotics, Inc.
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% ==========================================================================================================
-module(syn_groups).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([join/2, join/3]).
-export([leave/2]).
-export([get_members/1, get_members/2]).
-export([member/2]).

%% sync API
-export([sync_join/3, sync_leave/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% records
-record(state, {}).

%% includes
-include("syn.hrl").

%% ===================================================================
%% API
%% ===================================================================
-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    Options = [],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], Options).

-spec join(GroupName :: any(), Pid :: pid()) -> ok.
join(GroupName, Pid) ->
    join(GroupName, Pid, undefined).

-spec join(GroupName :: any(), Pid :: pid(), Meta :: any()) -> ok.
join(GroupName, Pid, Meta) when is_pid(Pid) ->
    Node = node(Pid),
    gen_server:call({?MODULE, Node}, {join_on_node, GroupName, Pid, Meta}).

-spec leave(GroupName :: any(), Pid :: pid()) -> ok | {error, Reason :: any()}.
leave(GroupName, Pid) ->
    case find_process_entry_by_name_and_pid(GroupName, Pid) of
        undefined ->
            {error, not_in_group};
        _ ->
            Node = node(Pid),
            gen_server:call({?MODULE, Node}, {leave_on_node, GroupName, Pid})
    end.

-spec get_members(Name :: any()) -> [pid()].
get_members(GroupName) ->
    Entries = mnesia:dirty_read(syn_groups_table, GroupName),
    Pids = [Entry#syn_groups_table.pid || Entry <- Entries],
    lists:sort(Pids).

-spec get_members(GroupName :: any(), with_meta) -> [{pid(), Meta :: any()}].
get_members(GroupName, with_meta) ->
    Entries = mnesia:dirty_read(syn_groups_table, GroupName),
    Pids = [{Entry#syn_groups_table.pid, Entry#syn_groups_table.meta} || Entry <- Entries],
    lists:sort(Pids).

-spec member(Pid :: pid(), GroupName :: any()) -> boolean().
member(Pid, GroupName) ->
    case find_process_entry_by_name_and_pid(GroupName, Pid) of
        undefined -> false;
        _ -> true
    end.

-spec sync_join(GroupName :: any(), Pid :: pid(), Meta :: any()) -> ok.
sync_join(GroupName, Pid, Meta) ->
    gen_server:cast(?MODULE, {sync_join, GroupName, Pid, Meta}).

-spec sync_leave(GroupName :: any(), Pid :: pid()) -> ok.
sync_leave(GroupName, Pid) ->
    gen_server:cast(?MODULE, {sync_leave, GroupName, Pid}).

%% ===================================================================
%% Callbacks
%% ===================================================================

%% ----------------------------------------------------------------------------------------------------------
%% Init
%% ----------------------------------------------------------------------------------------------------------
-spec init([]) ->
    {ok, #state{}} |
    {ok, #state{}, Timeout :: non_neg_integer()} |
    ignore |
    {stop, Reason :: any()}.
init([]) ->
    %% wait for table
    case mnesia:wait_for_tables([syn_groups_table], 10000) of
        ok ->
            %% monitor nodes
            ok = net_kernel:monitor_nodes(true),
            %% init
            {ok, #state{}};
        Reason ->
            {stop, {error_waiting_for_groups_table, Reason}}
    end.

%% ----------------------------------------------------------------------------------------------------------
%% Call messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_call(Request :: any(), From :: any(), #state{}) ->
    {reply, Reply :: any(), #state{}} |
    {reply, Reply :: any(), #state{}, Timeout :: non_neg_integer()} |
    {noreply, #state{}} |
    {noreply, #state{}, Timeout :: non_neg_integer()} |
    {stop, Reason :: any(), Reply :: any(), #state{}} |
    {stop, Reason :: any(), #state{}}.

handle_call({join_on_node, GroupName, Pid, Meta}, _From, State) ->
    %% check if pid is alive
    case is_process_alive(Pid) of
        true ->
            join_on_node(GroupName, Pid, Meta),
            %% multicast
            rpc:eval_everywhere(nodes(), ?MODULE, sync_join, [GroupName, Pid, Meta]),
            %% return
            {reply, ok, State};
        _ ->
            {reply, {error, not_alive}, State}
    end;

handle_call({leave_on_node, GroupName, Pid}, _From, State) ->
    case leave_on_node(GroupName, Pid) of
        ok ->
            %% multicast
            rpc:eval_everywhere(nodes(), ?MODULE, sync_leave, [GroupName, Pid]),
            %% return
            {reply, ok, State};
        {error, Reason} ->
            %% return
            {reply, {error, Reason}, State}
    end;

handle_call(Request, From, State) ->
    error_logger:warning_msg("Syn(~p): Received from ~p an unknown call message: ~p~n", [node(), Request, From]),
    {reply, undefined, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Cast messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_cast(Msg :: any(), #state{}) ->
    {noreply, #state{}} |
    {noreply, #state{}, Timeout :: non_neg_integer()} |
    {stop, Reason :: any(), #state{}}.

handle_cast({sync_join, GroupName, Pid, Meta}, State) ->
    %% add to table
    add_to_local_table(GroupName, Pid, Meta, undefined),
    %% return
    {noreply, State};

handle_cast({sync_leave, GroupName, Pid}, State) ->
    %% remove entry
    remove_from_local_table(GroupName, Pid),
    %% return
    {noreply, State};

handle_cast(Msg, State) ->
    error_logger:warning_msg("Syn(~p): Received an unknown cast message: ~p~n", [node(), Msg]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% All non Call / Cast messages
%% ----------------------------------------------------------------------------------------------------------
-spec handle_info(Info :: any(), #state{}) ->
    {noreply, #state{}} |
    {noreply, #state{}, Timeout :: non_neg_integer()} |
    {stop, Reason :: any(), #state{}}.

handle_info({'DOWN', _MonitorRef, process, Pid, Reason}, State) ->
    case find_processes_entry_by_pid(Pid) of
        [] ->
            %% log
            log_process_exit(undefined, Pid, Reason);

        Entries ->
            lists:foreach(fun(Entry) ->
                %% get process info
                GroupName = Entry#syn_groups_table.name,
                %% log
                log_process_exit(GroupName, Pid, Reason),
                %% remove from table
                remove_from_local_table(Entry),
                %% multicast
                rpc:eval_everywhere(nodes(), ?MODULE, sync_leave, [GroupName, Pid])
            end, Entries)
    end,
    %% return
    {noreply, State};

handle_info(Info, State) ->
    error_logger:warning_msg("Syn(~p): Received an unknown info message: ~p~n", [node(), Info]),
    {noreply, State}.

%% ----------------------------------------------------------------------------------------------------------
%% Terminate
%% ----------------------------------------------------------------------------------------------------------
-spec terminate(Reason :: any(), #state{}) -> terminated.
terminate(Reason, _State) ->
    error_logger:info_msg("Syn(~p): Terminating with reason: ~p~n", [node(), Reason]),
    terminated.

%% ----------------------------------------------------------------------------------------------------------
%% Convert process state when code is changed.
%% ----------------------------------------------------------------------------------------------------------
-spec code_change(OldVsn :: any(), #state{}, Extra :: any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal
%% ===================================================================
-spec join_on_node(GroupName :: any(), Pid :: pid(), Meta :: any()) -> ok.
join_on_node(GroupName, Pid, Meta) ->
    MonitorRef = case find_processes_entry_by_pid(Pid) of
        [] ->
            %% process is not monitored yet, add
            erlang:monitor(process, Pid);
        [Entry | _] ->
            Entry#syn_groups_table.monitor_ref
    end,
    %% add to table
    add_to_local_table(GroupName, Pid, Meta, MonitorRef).

-spec leave_on_node(GroupName :: any(), Pid :: pid()) -> ok | {error, Reason :: any()}.
leave_on_node(GroupName, Pid) ->
    case find_process_entry_by_name_and_pid(GroupName, Pid) of
        undefined ->
            {error, not_in_group};

        Entry when Entry#syn_groups_table.monitor_ref =/= undefined ->
            %% is this the last group process is in?
            case find_processes_entry_by_pid(Pid) of
                [Entry] ->
                    %% demonitor
                    erlang:demonitor(Entry#syn_groups_table.monitor_ref);
                _ ->
                    ok
            end,
            %% remove from table
            remove_from_local_table(Entry)
    end.

-spec add_to_local_table(GroupName :: any(), Pid :: pid(), Meta :: any(), MonitorRef :: undefined | reference()) -> ok.
add_to_local_table(GroupName, Pid, Meta, MonitorRef) ->
    %% clean if any
    remove_from_local_table(GroupName, Pid),
    %% write
    mnesia:dirty_write(#syn_groups_table{
        name = GroupName,
        pid = Pid,
        node = node(Pid),
        meta = Meta,
        monitor_ref = MonitorRef
    }).

-spec remove_from_local_table(GroupName :: any(), Pid :: pid()) -> ok | {error, Reason :: any()}.
remove_from_local_table(GroupName, Pid) ->
    case find_process_entry_by_name_and_pid(GroupName, Pid) of
        undefined ->
            {error, not_in_group};
        Entry ->
            %% remove from table
            remove_from_local_table(Entry)
    end.

-spec remove_from_local_table(Entry :: #syn_groups_table{}) -> ok.
remove_from_local_table(Entry) ->
    mnesia:dirty_delete_object(syn_groups_table, Entry).

-spec find_processes_entry_by_pid(Pid :: pid()) -> Entries :: list(#syn_groups_table{}).
find_processes_entry_by_pid(Pid) when is_pid(Pid) ->
    mnesia:dirty_index_read(syn_groups_table, Pid, #syn_groups_table.pid).

-spec find_process_entry_by_name_and_pid(GroupName :: any(), Pid :: pid()) -> Entry :: #syn_groups_table{} | undefined.
find_process_entry_by_name_and_pid(GroupName, Pid) ->
    %% build match specs
    MatchHead = #syn_groups_table{name = GroupName, pid = Pid, _ = '_'},
    Guards = [],
    Result = '$_',
    %% select
    case mnesia:dirty_select(syn_groups_table, [{MatchHead, Guards, [Result]}]) of
        [Entry] -> Entry;
        [] -> undefined
    end.

-spec log_process_exit(Name :: any(), Pid :: pid(), Reason :: any()) -> ok.
log_process_exit(GroupName, Pid, Reason) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        {shutdown, _} -> ok;
        killed -> ok;
        _ ->
            case GroupName of
                undefined ->
                    error_logger:error_msg(
                        "Syn(~p): Received a DOWN message from an unmonitored process ~p with reason: ~p~n",
                        [node(), Pid, Reason]
                    );
                _ ->
                    error_logger:error_msg(
                        "Syn(~p): Process in group ~p and pid ~p exited with reason: ~p~n",
                        [node(), GroupName, Pid, Reason]
                    )
            end
    end.