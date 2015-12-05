%% @doc Abuse module constant pools as a "read-only shared heap" (since erts 5.6) for non-binary
%%      Erlang terms.
%%      <a href="http://www.erlang.org/pipermail/erlang-questions/2009-March/042503.html">[1]</a>.
%%      Based on <a href="https://mochiweb.googlecode.com/svn/trunk/src/mochiglobal.erl">[2]</a>.
%%
%%      <B>Note:</B> We are explicitly using tuples here because we expect to
%%      use this to speed up ETS lookups and ETS stores tuples.
-module(fling_mochiglobal).
-export([create/3, 
	 create/4, 
	 get/2, 
	 get/3,
	 purge/1]).

-define(GETTER, term).
-define(GETTER(K), term(K)).

-type get_expr_fun() :: fun((tuple()) -> any()).

-spec create(        L :: [ tuple() ], 
	        GetKey :: get_expr_fun(),
	      GetValue :: get_expr_fun() ) -> ModName :: atom().
%% @doc create a module using the list of tuples given. The functions
%% passed in should return the key and the value respectively when
%% provided an element from the list of input tuples. Each function will be given 
%% the same element of L as input.
%%
%% A simple example might be:
%% <pre>
%% get_key({K, _V}) -> K.
%% get_value({_K, V}) -> V.
%% </pre>
%%
%% A more complex example might be:
%% <pre>
%% -record(person, { name, phone }).
%% % use phone as the key for this record lookup
%% get_key(#person{ phone = Phone }) -> Phone.
%% % use entire record tuple as the value
%% get_value(E) -> E.
%% </pre>
create(L, GetKey, GetValue) when is_list(L) andalso L /= [] 
				 andalso is_function(GetKey) andalso is_function(GetValue)->
    ModName = choose_module_name(),
    ok = create(ModName, L, GetKey, GetValue),
    ModName.

-spec create(  ModName :: atom(), 
	             L :: [ tuple() ],  
	        GetKey :: get_expr_fun(),
	      GetValue :: get_expr_fun() 
	    ) -> ok | {error, Reason :: term()}.
%% @doc create and load a module using the given module name, and constructed
%% using the list of tuples given.
%% {@link create/3}
create(ModName, L, GetKey, GetValue) when is_atom(ModName) 
					  andalso is_list(L) andalso L /= [] 
					  andalso is_function(GetKey) andalso is_function(GetValue) ->
    Bin = compile(ModName, L, GetKey, GetValue),
    code:purge(ModName),
    case code:load_binary(ModName, atom_to_list(ModName) ++ ".erl", Bin) of
	    {module, ModName} -> ok;
	    Error -> Error
    end.

-spec get(ModName :: atom(), Key :: term()) -> any() | undefined.
%% @equiv get(ModName, K, undefined)
get(ModName, K) ->
    get(ModName, K, undefined).

-spec get(ModName :: atom(), Key :: term(), Default :: term()) -> term().
%% @doc Get the term for K or return Default.
get(ModName, K, Default) ->
    try 
	ModName:?GETTER(K)
    catch 
	error:function_clause ->
            Default
    end.

-spec purge( ModName :: atom() ) -> boolean().
%% @doc Purges and removes the given module
purge(ModName) ->
    code:purge(ModName),
    code:delete(ModName).

%% internal functions
% @private
-spec choose_module_name() -> atom().
choose_module_name() ->
    list_to_atom("fling$" ++ md5hex(term_to_binary(erlang:make_ref()))).

-spec md5hex( binary() ) -> string().
md5hex(Data) ->
    binary_to_list(hexlify(erlang:md5(Data))).

%% http://stackoverflow.com/a/29819282
-spec hexlify( binary() ) -> binary().
hexlify(Bin) when is_binary(Bin) ->
    << <<(hex(H)),(hex(L))>> || <<H:4,L:4>> <= Bin >>.

hex(C) when C < 10 -> $0 + C;
hex(C) -> $a + C - 10.

-spec compile(  ModName :: atom(), 
	              L :: [ tuple() ], 
	         GetKey :: get_expr_fun(),
	       GetValue :: get_expr_fun() ) -> binary().
compile(Module, L, GetKey, GetValue) ->
    {ok, Module, Bin} = compile:forms(forms(Module, L, GetKey, GetValue),
                                      [verbose, report_errors]),
    Bin.

-spec forms(  ModName :: atom(), 
	            L :: [ tuple() ], 
	       GetKey :: get_expr_fun(),
	     GetValue :: get_expr_fun() ) -> [erl_syntax:syntaxTree()].
forms(Module, L, GetKey, GetValue) ->
    [erl_syntax:revert(X) || X <- [ module_header(Module), export_getter(?GETTER), 
				    make_lookup_terms(?GETTER, L, GetKey, GetValue) ] ].

-spec module_header( ModName :: atom() ) -> erl_syntax:syntaxTree().
%% -module(Module).
module_header(Module) ->
   erl_syntax:attribute(
     erl_syntax:atom(module),
     [erl_syntax:atom(Module)]).

%% -export([ term/1 ]).
-spec export_getter( Getter :: atom() ) -> erl_syntax:syntaxTree().
export_getter(Getter) ->
    erl_syntax:attribute(
       erl_syntax:atom(export),
       [erl_syntax:list(
         [erl_syntax:arity_qualifier(
            erl_syntax:atom(Getter),
            erl_syntax:integer(1))])]).

%% term(K) -> V;
-spec make_lookup_terms(   Getter :: atom(), 
			        L :: [ tuple() ], 
			   GetKey :: get_expr_fun(), 
			 GetValue :: get_expr_fun() ) -> [erl_syntax:syntaxTree()].
make_lookup_terms(Getter, L, GetKey, GetValue) ->
    erl_syntax:function(
       erl_syntax:atom(Getter),
       make_terms(L, GetKey, GetValue, [])).
	
-spec make_terms(        L :: [ tuple() ], 
	            GetKey :: get_expr_fun(),
		  GetValue :: get_expr_fun(),
		       Acc :: list() ) -> [erl_syntax:syntaxTree()].
make_terms([], _GetKey, _GetValue, Acc) ->
    Acc;
make_terms([ H | T ], GetKey, GetValue, Acc) ->
    make_terms(T, GetKey, GetValue,
    %%  Pattern (Key)                               Guards, Function Body (Value)
	[ erl_syntax:clause([erl_syntax:abstract(GetKey(H))], none, [erl_syntax:abstract(GetValue(H))]) | Acc ]).

%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
basic_test() -> 
    L = [{a,1}, {b,2}, {c,3}],
    GetKey = fun({K, _V}) -> K end,
    GetValue = fun({_K, V}) -> V end,
    Mod = create(L, GetKey, GetValue),
    ?assertEqual(1, ?MODULE:get(Mod, a)),
    ?assertEqual(2, ?MODULE:get(Mod, b)),
    ?assertEqual(3, ?MODULE:get(Mod, c)),
    ?assertEqual(undefined, ?MODULE:get(Mod, d)).

-record(person, {name, phone}).
record_test() ->
   L = [ #person{name="mike", phone=1}, #person{name="joe", phone=2}, #person{name="robert", phone=3} ],
   GetKey = fun(#person{ phone = P }) -> P end,
   GetValue = fun(#person{ name = N }) -> N end,
   Mod = create(L, GetKey, GetValue),
   ?assertEqual("mike", ?MODULE:get(Mod, 1)),
   ?assertEqual("joe", ?MODULE:get(Mod, 2)),
   ?assertEqual("robert", ?MODULE:get(Mod, 3)).

-endif.
