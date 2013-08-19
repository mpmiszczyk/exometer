-module(exometer_probe).
-behaviour(gen_server).

-export([start/3,
	 stop/1,
	 subscribe/1,
	 unsubscribe/1]).

%% gen_server callbacks
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

%% behaviour_info
-export([behaviour_info/1]).

-include("exometer.hrl").

-record(st, {name,
	     subscribers = [],
	     collect_from = [],
	     mod,
	     mod_state,
	     sample_timer,
	     report_timer,
	     sample_interval = infinity,
	     report_interval = infinity,
	     opts = [],
	     user_opts = []}).

behaviour_info(callbacks) ->
    [{init, 3},        % (Name, Opts, Opaque)
     {sample, 1},      % (ModSt)
     {get_value, 1},   % (ModSt)
     {report, 1},      % (ModSt)
     {event, 2}];      % (Event, ModSt)
behaviour_info(_) ->
    undefined.

start(Name, Mod, Opts) ->
    gen_server:start_link({via, exometer_reg, Name}, ?MODULE,
			  {Name, Mod, Opts}, []).

stop(Name) ->
    call(Name, stop).

subscribe(Name) ->
    call(Name, {subscribe, self()}).

unsubscribe(Name) ->
    call(Name, {unsubscribe, self()}).

init({Name, Mod, Opts}) ->
    St0 = check_opts(Name, Opts),
    case Mod:init(Name, St0#st.user_opts, St0) of
	{ok, ModSt} ->
	    St = St0#st{name = Name,
			mod = Mod,
			mod_state = ModSt},
	    %% Sample immediately. If subscribers exist, and there's a
	    %% (non-infinity) report interval, start the report timer.
	    {ok, sample(restart_timer(
			  sample, check_report_timer(St)))};
	{error, Reason} ->
	    {error, Reason}
    end.

handle_call({subscribe, Pid}, _From, #st{subscribers = Subs} = St) ->
    MRef = erlang:monitor(process, Pid),
    St1 = St#st{subscribers = [{Pid, MRef}|
			       lists:keydelete(Pid, 1, Subs)]},
    {reply, ok, check_report_timer(St1)};
handle_call({unsubscribe, Pid}, _From, #st{subscribers = Subs} = St) ->
    case lists:keyfind(Pid, 1, Subs) of
	{_, Ref} ->
	    erlang:demonitor(Ref),
	    Subs1 = lists:keydelete(Pid, 1, Subs),
	    {reply, ok, check_report_timer(St#st{subscribers = Subs1})};
	false ->
	    {reply, ok, St}
    end;
handle_call(get_value, _From, St) ->
    {V, St1} = get_value(St),
    {reply, {ok, V}, St1};
handle_call(_, _, St) ->
    {reply, error, St}.

handle_cast(_, St) ->
    {noreply, St}.

handle_info({timeout, TRef, sample}, #st{sample_timer = TRef} = St) ->
    {noreply, sample(restart_timer(sample, St))};
handle_info({timeout, TRef, report}, #st{report_timer = TRef} = St) ->
    {noreply, report(restart_timer(report, St))};
handle_info({?MODULE, sample, From}, St) ->
    {V, St1} = get_value(St),
    From ! #exometer_event{from = St1#st.name, event = V},
    {noreply, St1};
handle_info(#exometer_event{} = E, #st{mod = M, mod_state = ModSt} = St) ->
    St1 = handle_mod_return(M:event(E, ModSt), St),
    {noreply, St1};
handle_info(_, St) ->
    {noreply, St}.

terminate(_, _) ->
    ok.

code_change(From, #st{mod = M, mod_state = ModSt} = St, Extra) ->
    case M:code_change(From, ModSt, Extra) of
	{ok, ModSt1} ->
	    {ok, St#st{mod_state = ModSt1}};
	Other ->
	    Other
    end.

%% ===================================================================

call(Name, Req) ->
    gen_server:call({via, exometer_reg, Name}, Req).

sample(#st{mod = M, mod_state = ModSt} = St) ->
    Ret = M:sample(ModSt),
    handle_mod_return(Ret, St).

get_value(#st{mod = M, mod_state = ModSt} = St) ->
    case M:get_value(ModSt) of
	{ok, V} -> {V, St};
	{ok, V, ModSt1} ->
	    {V, St#st{mod_state = ModSt1}};
	{ok, V, Events, ModSt1} ->
	    broadcast(Events, St#st.subscribers),
	    {V, St#st{mod_state = ModSt1}};
	{ok, V, Actions, Events, ModSt1} ->
	    broadcast(Events, St#st.subscribers),
	    St1 = perform_actions(Actions, St#st{mod_state = ModSt1}),
	    {V, St1};
	{error, Reason} ->
	    {{error, Reason}, St}  % ??
    end.

report(#st{mod = M, mod_state = ModSt} = St) ->
    handle_mod_return(M:report(ModSt), St).

handle_mod_return({ok, ModSt1}, St) ->
    St#st{mod_state = ModSt1};
handle_mod_return({ok, Events, ModSt1}, St) ->
    broadcast(Events, St#st.subscribers),
    St#st{mod_state = ModSt1};
handle_mod_return({ok, Actions, Events, ModSt1}, St) when is_list(Actions),
							  is_list(Events) ->
    broadcast(Events, St#st.subscribers),
    perform_actions(Actions, St#st{mod_state = ModSt1});
handle_mod_return({error, Reason}, _St) ->
    error({Reason, erlang:get_stacktrace()}).

broadcast(Events, #st{name = Name, subscribers = Subs}) ->
    T = exometer:timestamp(),
    [[Pid ! #exometer_event{from = Name,
			    time = T,
			    event = E} || {Pid,_} <- Subs] || E <- Events].

perform_actions(Actions, St) ->
    lists:foldl(fun(collect, St1) ->
			collect(St1)
		end, St, Actions).

collect(#st{collect_from = C} = St) ->
    Msg = {exometer, sample, self()},
    lists:foldl(
      fun(Pid, St1) when is_pid(Pid) ->
	      Pid ! Msg,
	      St1;
	 (Name, St1) ->
	      exometer_reg:send(Name, Msg),
	      St1
      end, St, C).

restart_timer(sample, #st{sample_interval = Int} = St) ->
    St#st{sample_timer = start_timer(Int, sample)};
restart_timer(report, #st{report_interval = Int} = St) ->
    St#st{report_timer = start_timer(Int, report)}.

check_report_timer(#st{report_timer = undefined,
		       subscribers = [_|_],
		       report_interval = Int} = St) ->
    St#st{report_timer = start_timer(Int, report)};
check_report_timer(#st{report_timer = TRef,
		       subscribers = []} = St) when is_reference(TRef) ->
    erlang:cancel_timer(TRef),
    St#st{report_timer = undefined};
check_report_timer(St) ->
    St.

start_timer(infinity, _) ->
    undefined;
start_timer(T, Msg) when is_integer(T), T >= 0, T =< 16#FFffFFff ->
    erlang:start_timer(T, self(), Msg).

check_opts(Name, Opts) ->
    lists:foldl(fun({K, V}, S) ->
			case K of
			    sample_interval -> S#st{sample_interval = V};
			    report_interval -> S#st{report_interval = V};
			    user -> S#st{user_opts = V};
			    collect_from ->
				if is_list(V) ->
					S#st{collect_from = V};
				   true ->
					error({badarg, K})
				end;
			    _ -> S
			end
		end, #st{name = Name}, Opts).
