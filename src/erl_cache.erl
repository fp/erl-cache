-module(erl_cache).

-behaviour(gen_server).

-include("erl_cache.hrl").

%% ==================================================================
%% API Function Exports
%% ==================================================================

-export([
        get/2, get/3,
        get_stats/1,
        set/3, set/4,
        start_link/0, start_cache/2,
        stop_cache/1,
        evict/2, evict/3
    ]).

-type name() :: atom().
-type key() :: term().
-type value() :: term().

-type config_key()::validity | evict | refresh_callback | wait_for_refresh | wait_until_done.

-type validity() :: pos_integer().  %% How long an entry shold be considered valid (in ms)
-type evict() :: non_neg_integer(). %% How long an entry shold be considered stale (non valid byt
                                    %% not yet to be evicted, in ms)
-type refresh_callback() :: function() | mfa() | undefined. %% How to refresh a stale entry when
                                                            %% requested via get
-type wait_for_refresh() :: boolean(). %% Whether a get call hiting a stale value should wait for
                                       %% the refreshed value or return immediatly with a not_found
-type wait_until_done() :: boolean().  %% Whether set and evict operations should behave
                                       %% synchronously or asynchronously

-type invalid_opt_error()::{invalid, config_key() | cache_name}.

-type cache_get_opt()::{wait_for_refresh, wait_for_refresh()}.
-type cache_set_opt() ::
    {validity, validity()} |
    {evict, evict()} |
    {wait_until_done, wait_until_done()} |
    {refresh_callback, refresh_callback()}.
-type cache_evict_opt() :: {wait_until_done, wait_until_done()}.
-type cache_opts()::[cache_get_opt() | cache_set_opt() | cache_evict_opt()].

-type cache_stat()::{memory, pos_integer()} | {size, non_neg_integer()} | {hit, non_neg_integer()} |
                    {evict, non_neg_integer()} | {stale, non_neg_integer()} |
                    {miss, non_neg_integer()}.
-type cache_stats()::[cache_stat()].

-export_type([
        name/0, key/0, value/0, validity/0, evict/0, refresh_callback/0, cache_stats/0,
        wait_for_refresh/0, wait_until_done/0
]).

%% ==================================================================
%% gen_server Function Exports
%% ==================================================================

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
        cache_map::ets:tid()
}).

-define(CACHE_MAP, cache_map).
-define(SERVER, ?MODULE).

%% ====================================================================
%% API
%% ====================================================================

%% @doc Starts this server, which will act as a cache server manager.
%% To be called by erl_cache_sup
-spec start_link() -> {ok, pid()}.
%% @end
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Starts a cache server with the given name and default options.
%% Returns a name in case the given name corresponds to a running cache server or any other process
%% in the system
-spec start_cache(name(), cache_opts()) -> ok | {error, invalid_opt_error()}.
%% @end
start_cache(Name, Opts) ->
    gen_server:call(?SERVER, {start_cache, Name, Opts}).

%% @doc Stops a cache server.
%% Returs an error if the given name does not correspond to a running cache server
-spec stop_cache(name()) -> ok | {error, invalid_opt_error()}.
%% @end
stop_cache(Name) ->
    gen_server:call(?SERVER, {stop_cache, Name}).

%% @see get/3
-spec get(name(), key()) ->
    {error, not_found} |
    {error, invalid_opt_error()} |
    {ok, value()}.
%% @end
get(Name, Key) ->
    get(Name, Key, []).

%% @doc Gets the value associated with a given key in the cache signaled by the given name.
-spec get(name(), key(), [cache_get_opt()]) ->
    {error, not_found} |
    {error, invalid_opt_error()} |
    {ok, value()}.
%% @end
get(Name, Key, Opts) ->
    case validate_opts(Opts, get_name_defaults(Name)) of
        {ok, ValidatedOpts} ->
            erl_cache_server:get(Name, Key, proplists:get_value(wait_for_refresh, ValidatedOpts));
        {error, _}=E -> E
    end.

%% @doc Retrieves the stats associated with a cache instance
-spec get_stats(name()) -> {ok, cache_stats()}  | {error, invalid_opt_error()}.
%% @end
get_stats(Name) ->
    case is_cache_server(Name) of
        true -> erl_cache_server:get_stats(Name);
        false -> {error, {invalid, cache_name}}
    end.

%% @see set/4
-spec set(name(), key(), value()) -> ok | {error, invalid_opt_error()}.
%% @end
set(Name, Key, Value) ->
    set(Name, Key, Value, []).

%% @doc Sets a cache entry in a cache instance.
%% The options passed in this function call will overwrite the default ones for the cache instance
%% for any operation related to this specific key.
-spec set(name(), key(), value(), [cache_set_opt()]) -> ok | {error, invalid_opt_error()}.
%% @end
set(Name, Key, Value, Opts) ->
    case validate_opts(Opts, get_name_defaults(Name)) of
        {ok, ValidatedOpts} ->
            Validity = proplists:get_value(validity, ValidatedOpts),
            Evict = proplists:get_value(evict, ValidatedOpts),
            RefreshCb = proplists:get_value(refresh_callback, ValidatedOpts),
            Wait = proplists:get_value(wait_until_done, ValidatedOpts),
            erl_cache_server:set(Name, Key, Value, Validity, Evict, RefreshCb, Wait);
        {error, _}=E -> E
    end.

%% @see evict/3
-spec evict(name(), key()) -> ok  | {error, invalid_opt_error()}.
%% @end
evict(Name, Key) ->
    evict(Name, Key, []).

%% @doc Forces a cache entry to be evivted from the indicated cache instance
-spec evict(name(), key(), [cache_evict_opt()]) -> ok  | {error, invalid_opt_error()}.
%% @end
evict(Name, Key, Opts) ->
    case validate_opts(Opts, get_name_defaults(Name)) of
        {ok, ValidatedOpts} ->
            erl_cache_server:evict(Name, Key,
                                   proplists:get_value(wait_until_done, ValidatedOpts));
        {error, _}=E -> E
    end.

%% ====================================================================
%% gen_server callbacks
%% ====================================================================

-spec init([]) -> {ok, #state{}}.
init([]) ->
    Tid = ets:new(?CACHE_MAP, [set, protected, named_table, {read_concurrency, true}]),
    Servers = case application:get_env(erl_cache, cache_servers) of
        undefined -> [];
        {ok, L} when is_list(L) -> L
    end,
    ok = lists:foreach(fun ({Name, Opts}) -> do_start_cache(Name, Opts) end, Servers),
    {ok, #state{cache_map=Tid}}.


-spec handle_call(term(), term(), #state{}) ->
    {reply, Data::any(), #state{}}.
handle_call({start_cache, Name, Defaults}, _From, #state{}=State) ->
    Res = do_start_cache(Name, Defaults),
    {reply, Res, State#state{}};
handle_call({stop_cache, Name}, _From, #state{}=State) ->
    Res = case is_cache_server(Name) of
        true ->
            ok = erl_cache_server_sup:remove_cache(Name),
            ?INFO("Stopping cache server '~p'", [Name]),
            true = ets:delete(?CACHE_MAP, Name),
            ok;
        false ->
            {error, {invalid, cache_name}}
    end,
    {reply, Res, State}.

-spec do_start_cache(name(), cache_opts()) -> ok | {error, invalid_opt_error()}.
do_start_cache(Name, Opts) ->
    case is_available_name(Name) of
        true ->
            case validate_opts(Opts, []) of
                {ok, ValidatedOpts} ->
                    ?INFO("Starting cache server '~p'", [Name]),
                    {ok, _} = erl_cache_server_sup:add_cache(Name),
                    true = ets:insert(?CACHE_MAP, {Name, ValidatedOpts}),
                    ok;
                {error, _}=E -> E
            end;
        false ->
            {error, {invalid, cache_name}}
    end.

-spec handle_cast(any(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(any(), #state{}) -> {noreply, #state{}}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(any(), #state{}) -> any().
terminate(_Reason, _State) ->
    ok.

-spec code_change(any(), #state{}, any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

-spec validate_opts(cache_opts(), cache_opts() | undefined) ->
    {ok, cache_opts()} | {error, invalid_opt_error()}.
validate_opts(_, undefined) ->
    {error, {invalid, cache_name}};
validate_opts(Opts, Defaults) ->
    CacheOpts = [validity, evict, refresh_callback, wait_for_refresh, wait_until_done],
    ValidationResults = [{K, validate_value(K, Opts, Defaults)} || K <- CacheOpts],
    ErrorList = lists:dropwhile(
            fun ({K, {invalid, K}}) -> false; ({_, _}) -> true end, ValidationResults),
    case ErrorList of
        [] -> {ok, ValidationResults};
        [{K, {invalid, K}=E} | _] -> {error, E}
    end.

-spec validate_value(config_key(), [cache_opts()], [cache_opts()]) ->
    term() | {invalid, config_key()}.
validate_value(Key, Opts, Defaults) when Key==refresh_callback ->
    case proplists:get_value(Key, Opts, undefined) of
        undefined -> default(Key, Defaults);
        {M, F, A} when is_atom(M) andalso is_atom(F) andalso is_list(A) -> {M, F, A};
        Fun when is_function(Fun) -> Fun;
        _ -> {invalid, Key}
    end;
validate_value(Key, Opts, Defaults) when Key==validity ->
    case proplists:get_value(Key, Opts, undefined) of
        undefined -> default(Key, Defaults);
        N when is_integer(N) andalso N>0 -> N;
        _ -> {invalid, Key}
    end;
validate_value(Key, Opts, Defaults) when Key==evict ->
    case proplists:get_value(Key, Opts, undefined) of
        undefined -> default(Key, Defaults);
        N when is_integer(N) andalso N>=0 -> N;
        _ -> {invalid, Key}
    end;
validate_value(Key, Opts, Defaults) when Key==wait_for_refresh; Key==wait_until_done ->
    case proplists:get_value(Key, Opts, undefined) of
        undefined -> default(Key, Defaults);
        B when is_boolean(B) -> B;
        _ -> {invalid, Key}
    end.

-spec default(config_key(), cache_opts()) -> term().
default(validity, Defaults) ->
    proplists:get_value(validity, Defaults, ?DEFAULT_VALIDITY);
default(evict, Defaults) ->
    proplists:get_value(evict, Defaults, ?DEFAULT_EVICT);
default(wait_for_refresh, Defaults) ->
    proplists:get_value(wait_for_refresh, Defaults, ?DEFAULT_WAIT_FOR_REFRESH);
default(refresh_callback, Defaults) ->
    proplists:get_value(refresh_callback, Defaults, ?DEFAULT_REFRESH_CALLBACK);
default(wait_until_done, Defaults) ->
    proplists:get_value(wait_until_done, Defaults, ?DEFAULT_WAIT_UNTIL_CACHED).

-spec is_available_name(name()) -> boolean().
is_available_name(Name) ->
    ets:lookup(?CACHE_MAP, Name)==[] andalso erlang:whereis(Name)==undefined
        andalso not lists:member(erl_cache_server:get_table_name(Name), ets:all()).

-spec is_cache_server(name()) -> boolean().
is_cache_server(Name) ->
    ets:lookup(?CACHE_MAP, Name)/=[].

-spec get_name_defaults(name()) -> cache_opts() | undefined.
get_name_defaults(Name) ->
    case ets:lookup(?CACHE_MAP, Name) of
        [{Name, Opts}] -> Opts;
        [] -> undefined
    end.

