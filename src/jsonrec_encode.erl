%%%-------------------------------------------------------------------
%%% @author Eduard Sergeev <eduard.sergeev@gmail.com>
%%% @copyright (C) 2013, Eduard Sergeev
%%% @doc
%%% JSON "encode" code generator
%%% @end
%%% Created : 28 Nov 2012 by <eduard.sergeev@gmail.com>
%%%-------------------------------------------------------------------
-module(jsonrec_encode).

-include_lib("meta/include/meta_syntax.hrl").
-include("parsers.hrl").


-export([encode_gen/4, encode_gen_encoder/4]).

-export([integer_to_json/1, float_to_json/1,
         binary_to_json/1, string_to_json/1,
         boolean_to_json/1, atom_to_json/1]).

-export([format_error/1]).


-define(ENCODERS_OPT, encoders).
-define(SURROGATES_OPT, surrogate_types).
-define(NAME_HANDLER_OPT, name_handler).
-define(ENCODE_ATTR, encode).

-define(re(Syntax), erl_syntax:revert(Syntax)).

-define(TYPE(Type, Args),
        {type, _Ln3, Type, Args}).
-define(ATOM_TYPE(Atom),
        {atom, _Ln, Atom}).
-define(FIELD(Name),
        {record_field, _Ln1,
         {atom, _Ln2, Name}}).
-define(FIELD(Name, Default),
        {record_field, _Ln1,
         {atom, _Ln2, Name},
         Default}).
-define(TYPED_FIELD(Name, Type),
        {typed_record_field,
         ?FIELD(Name),
         Type}).
-define(TYPED_FIELD(Name, Type, Default),
        {typed_record_field,
         ?FIELD(Name, Default),
         Type}).

-define(RECORD_QUOTE(Name),
        {record, _Ln, Name, _Args}).
-define(TYPE_QUOTE(Name, Args),
        {call, _Ln1, {atom, _Ln2, Name}, Args}).
-define(LIST_QUOTE(Elem),
        {cons, _Ln1, Elem, {nil, _Ln2}}).

-record(mps,
        {defs = dict:new(),
         subs :: dict(),
         name_conv :: name_conv(),
         types = gb_sets:new()}).

-record(def_funs,
        {ind :: integer(),
         fun_name :: meta:quote(any()),
         v_fun :: fun((meta:quote(any())) -> meta:quote(any())),
         g_fun :: fun((meta:quote(any())) -> meta:quote(any())) | none,
         def :: meta:quote(any()) | none}).


-type type_quote() :: {record, integer(), atom(), []} |
                      {call, integer(), {atom, integer(), atom()}, [type_quote()]} |
                      {cons, integer(), type_quote(), {nil, integer()}}.

-type form() :: erl_parse:abstract_form().
-type type() :: {{record, atom()}, form(), []} |
                {atom(), form(), [type()]} |
                {atom(), [type()]}.
-type norm_type() :: {record, [{atom, atom()}]} |
                     {atom(), [norm_type()]}.


-type encode_options() :: [encode_option()].
-type encode_option() :: encoders() | name_handler().

-type encoders() :: {encoders, [encoder_type_ref() | encoder_fun_ref()]}.
%% This option is used to specify custom encoding for a type.

-type encoder_type_ref() :: {record, Name :: atom()} |
                            {TypeName :: atom(), Args :: [encoder_type_ref()]}.
-type encoder_fun_ref() :: local_fun_ref() | remote_fun_ref().
-type local_fun_ref() :: FunName :: atom().
-type remote_fun_ref() :: {Mod :: atom(), FunName :: atom()}.

-type name_handler() :: {name_handler, name_conv()}.
%% Forces decoder to preprocess all record field names
%% using specified function {@type name_conv()}

-type name_conv() :: fun((atom()) -> string()).

%%--------------------------------------------------------------------
%% @doc
%% Generates JSON "encode" function body for JSON serialization
%% using type annotation.
%%
%% Note: This is `meta' function and normally it should not be used directly.
%% Use `?encode_gen/2' and `?encode_gen/3' macros instead.
%% <ul>
%% <li>`Arg' is {@type meta:quote()} reference to generated function input parameter</li>
%% <li>`Type' is {@type meta:quote()} of the type being JSON encoded</li>
%% <li>`Info' is {@type meta:info()} structure returned by {@link meta:reify/0}</li>
%% <li>`Options' is {@type meta:quote()} of a list of options {@type encode_options()}</li>
%% </ul>
%%
%% Typical usage:
%% ```encode(#my_record{} = Rec) ->
%%      ?encode_gen(#my_record{}, Rec).'''
%% Upon compilation this code will generate the code which outputs
%% JSON in the form of binary {@type iolist()} from passed `#my_record{}'
%% @end
%%--------------------------------------------------------------------
-spec encode_gen(Arg, Type, Info, Options) -> meta:quote(FunBody) when
      Arg :: meta:quote(Var :: any()),
      Type :: meta:quote(Type :: any()),
      Info :: meta:quote(meta:info()),
      Options :: meta:quote(encode_options()),
      FunBody :: any().
encode_gen(Arg, Type, Info, Options) ->
    code_gen(fun fetch_vfun/3, Arg, Type, Info, Options).

%%--------------------------------------------------------------------
%% @doc
%% Generates JSON encoder using type annotation.
%%
%% Similar to {@link encode_gen/3} but `-encode` attributes are ignored
%% for top-level type `Type' (2nd argument of the function).
%% All nested types are treated identically to {@link encode_gen/3} behaviour
%% The resulting function is typically used in {@type encoder_fun_ref()}
%%
%% Note: This is `meta' function and normally it should not be used directly.
%% Use `?encode_gen_encoder/2' and `?encode_gen_encode/3' macros instead.
%%
%% <ul>
%% <li>`Arg' is {@type meta:quote()} reference to generated function input parameter</li>
%% <li>`Type' is {@type meta:quote()} of the type being JSON encoded</li>
%% <li>`Info' is {@type meta:info()} structure returned by {@link meta:reify/0}</li>
%% <li>`Options' is {@type meta:quote()} of a list of options {@type encode_options()}</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec encode_gen_encoder(Arg, Type, Info, Options) -> meta:quote(FunBody) when
      Arg :: meta:quote(#var{}),
      Type :: meta:quote(?TYPE(atom(), [any()])),
      Info :: meta:quote(meta:info()),
      Options :: meta:quote(encode_options()),
      FunBody :: any().
encode_gen_encoder(QArg, Type, Info, Options) ->
    CodeFun = fun(T, I, M) ->
                      {#def_funs{v_fun = VFun}, M1} = gen_encode(T, I, M),
                      {VFun, M1}
              end,
    code_gen(CodeFun, QArg, Type, Info, Options).

code_gen(CodeFun, QArg, Type, Info, Options) ->
    Type1 = norm_type_quote(?e(Type)),
    Attrs = meta:reify_attributes(?ENCODE_ATTR, ?e(Info)),
    AEs = lists:flatten(proplists:get_all_values(?ENCODERS_OPT, Attrs)),
    ASs = lists:flatten(proplists:get_all_values(?SURROGATES_OPT, Attrs)),
    OEs = proplists:get_value(?ENCODERS_OPT, ?e(Options), []),
    OSs = proplists:get_value(?SURROGATES_OPT, ?e(Options), []),
    Subs = [handle_encoder(E) || E <- AEs ++ OEs]
        ++ [handle_surrogate(S) || S <- ASs ++ OSs],
    DSubs = dict:from_list(Subs),
    NameFun = proplists:get_value(
                ?NAME_HANDLER_OPT, ?e(Options),
                fun atom_to_list/1),
    Mps = #mps{
      subs = DSubs,
      name_conv = NameFun},
    {VFun, Mps1} = CodeFun(type_ref(Type1), ?e(Info), Mps),
    Defs = [D || {_, D} <- dict:to_list(Mps1#mps.defs)],
    SDefs = lists:sort(
              fun(L,R) ->
                      L#def_funs.ind =< R#def_funs.ind
              end, Defs),
    Fs = [?q(?s(FN) = ?s(Def))
          || #def_funs{fun_name = FN, def = Def} <- SDefs,
             Def /= none],
    Call = VFun(QArg),
    ?v(?re(erl_syntax:block_expr(
             ?s(parsers:sequence(Fs))
             ++ [?s(Call)]))).


-spec gen_encode(Type, Info, Mps) -> {DefFuns, Mps} when
      Type :: norm_type(),
      Info :: meta:info(),
      Mps :: #mps{},
      DefFuns :: #def_funs{}.
gen_encode({record, [{atom, RecName}]} = Type, Info, Mps) ->
    {_, Fields, []} = meta:reify_type({record, RecName}, Info),
    {Def, Mps1} = encode_fields(Fields, Info, Mps),
    QTag = ?v(?re(erl_parse:abstract(RecName))),
    GFun = fun(Item) ->
                   ?q(is_record(?s(Item), ?s(QTag)))
           end,
    add_fun_def(Type, Def, Mps1, id, GFun);
gen_encode({list, [InnerType]}, Info, Mps) ->
    encode_list(InnerType, Info, Mps);

gen_encode({union, Types} = Type, Info, Mps) ->
    {Def, Mps1} = encode_union(Types, Info, Mps),
    add_fun_def(Type, Def, Mps1);

gen_encode({integer, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:integer_to_json),
    encode_basic_pred(Type, P, ?q(is_integer), Mps);
gen_encode({binary, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:binary_to_json),
    encode_basic_pred(Type, P, ?q(is_binary), Mps);
gen_encode({string, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:string_to_json),
    encode_basic_pred(Type, P, ?q(is_list), Mps);
gen_encode({float, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:float_to_json),
    encode_basic_pred(Type, P, ?q(is_float), Mps);
gen_encode({boolean, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:boolean_to_json),
    encode_basic_pred(Type, P, ?q(is_boolean), Mps);
gen_encode({atom, []} = Type, _Info, Mps) ->
    P = ?q(?MODULE:atom_to_json),
    encode_basic_pred(Type, P, ?q(is_atom), Mps);

gen_encode({atom, Atom} = Type, _Info, Mps) ->
    VFun = fun(_) ->
                   fun(_Item) ->
                           if
                               Atom =:= undefined ->
                                   ?q(undefined);
                               true ->
                                   ?v(?re(erl_parse:abstract(
                                            <<$\",(atom_to_binary(Atom, utf8))/binary, $\">>)))
                           end
                   end
           end,
    GFun = fun(Item) ->
                   ?q(?s(Item) =:= ?s(?v(?re(erl_parse:abstract(Atom)))))
           end,
    add_fun_def(Type, none, Mps, VFun, GFun);

gen_encode({any, []} = Type, _Info, Mps) ->
    FunVFun = fun(_) ->
                   fun(Item) ->
                           Item
                   end
           end,
    GFun = fun(Item) ->
                   ?q(is_binary(?s(Item)))
           end,
    add_fun_def(Type, none, Mps, FunVFun, GFun);

gen_encode({tuple, _Args} = Type, _Info, _Mps) ->
    meta:error(?MODULE, tuple_unsupported, Type);

gen_encode({_UserType, _Args} = Type, Info, Mps) ->
    encode_underlying(Type, Info, Mps);
            
gen_encode(Type, _Info, _Mps) ->
    meta:error(?MODULE, unexpected_type, Type).

encode_fields(Fields, Info, Mps) ->
    NFs = lists:zip(lists:seq(2, length(Fields)+1), Fields),
    {Es,Mps1} = lists:mapfoldl(
                fun({I,T}, M) ->
                        encode_field(I, T, Info, M)
                end, Mps, NFs),
    Es1 = lists:reverse(Es),
    {?q(fun(_Rec) ->
                [<<"{">>, ?s(loop(?r(_Rec), ?q([]), Es1)), <<"}">>]
        end),
     Mps1}.

loop(QRec, QAcc, [F]) ->
    ?q(case ?s(F(QRec, QAcc)) of
           [] ->
               [];
           [_|Es] -> Es
       end);
loop(QRec, QAcc, [F|Fs]) ->
    ?q(begin
           Acc = ?s(F(QRec, QAcc)),
           ?s(loop(QRec, ?r(Acc), Fs))
       end).

    

encode_field(Ind, ?FIELD(Fn), Info, Mps) ->
    encode_record(Ind, Fn, {any, []}, Info, Mps);
encode_field(Ind, ?FIELD(Fn, _Def), Info, Mps) ->
    encode_record(Ind, Fn, {any, []}, Info, Mps);
encode_field(Ind, ?TYPED_FIELD(Fn, Type), Info, Mps) ->
    encode_record(Ind, Fn, type_ref(Type), Info, Mps);
encode_field(Ind, ?TYPED_FIELD(Fn, Type, _Def), Info, Mps) ->
    encode_record(Ind, Fn, type_ref(Type), Info, Mps).

encode_record(Ind, Fn, Type, Info, #mps{name_conv = NC} = Mps) ->
    {VFun, Mps1} = fetch_vfun(Type, Info, Mps),
    AFN = ?v(?re(erl_parse:abstract("\"" ++ NC(Fn) ++ "\""))),
    QInd = ?v(?re(erl_parse:abstract(Ind))),
    DefFun = fun(QRec, QAcc) ->
                     case nullable_kind(Type) of
                         nullable ->
                             ?q(begin
                                    V = ?s(VFun(?q(element(?s(QInd), ?s(QRec))))),
                                    if V =/= undefined ->
                                            [<<$,>>, ?s(AFN), <<":">>, V
                                             | ?s(QAcc)];
                                       true ->
                                            ?s(QAcc)
                                    end
                                end);
                         non_nullable ->
                             ?q([<<$,>>, ?s(AFN), <<":">>,
                                 ?s(VFun(?q(element(?s(QInd), ?s(QRec)))))
                                 | ?s(QAcc)]);
                         null ->
                             QAcc
                     end
             end,
    {DefFun, Mps1}.


%%
%% General encode functions
%%
fetch_vfun(Type, Info, Mps) ->
    {#def_funs{v_fun = VFun}, Mps1} = fetch(Type, Info, Mps),
    {VFun, Mps1}.
    
fetch(Type, Info, Mps) ->
    case dict:find(Type, Mps#mps.subs) of
        error ->
            case dict:find(Type, Mps#mps.defs) of
                {ok, DefFuns} ->
                    {DefFuns, Mps};
                error ->
                    Ts = Mps#mps.types,
                    case gb_sets:is_member(Type, Ts) of
                        false ->
                            Ts1 = gb_sets:add(Type, Ts),
                            gen_encode(Type, Info, Mps#mps{types = Ts1});
                        true ->
                            meta:error(?MODULE, loop, Type)
                    end
            end;
        {ok, {_,Args} = SType} when is_list(Args) ->
            fetch(SType, Info, Mps);
        {ok, Fun} ->
            FunVFun = json_fun(Fun),
            add_fun_def(Type, none, Mps, FunVFun)
    end.

encode_list(InnerType, Info, Mps) -> 
    {Fun, Mps1} = fetch_vfun(type_ref(InnerType), Info, Mps),
    Def = ?q(fun([]) ->
                     <<"[]">>;
                (Es) ->
                     [<<$[>> |
                      tl(lists:foldl(fun(E, Acc) ->
                                             [<<$,>>, ?s(Fun(?r(E))) | Acc]
                                     end,
                                     [<<$]>>], lists:reverse(Es)))]
             end),
    add_fun_def({list, [InnerType]}, Def, Mps1).

encode_union(Types, Info, Mps) ->
    {Cs, MpsN} =
        lists:mapfoldl(
          fun(TA, Mps1) ->
                  Type = type_ref(TA),
                  {VFun, Mps2} = fetch_vfun(Type, Info, Mps1),
                  QF = case get_guard(Type, Info, Mps2) of
                           none ->
                               ?q(fun(V) ->
                                          ?s(VFun(?r(V)))
                                  end);
                           GFun ->
                               ?q(fun(V) when ?s(GFun(?r(V))) ->
                                          ?s(VFun(?r(V)))
                                  end)
                       end,
                  [C] = erl_syntax:fun_expr_clauses(?e(QF)),
                  {C,Mps2}
          end, Mps, Types),
    Def = ?v(?re(erl_syntax:fun_expr(Cs))),
    {Def, MpsN}.

encode_underlying({_, Args} = Type, Info, Mps) ->
    Type1 =  meta:reify_type(Type, Info),
    {_, Type2, []} = ground_type(Type1, Args),
    TR = type_ref(Type2),
    {VFun, Mps1} = fetch_vfun(TR, Info, Mps),
    FunVFun = fun(_) -> VFun end,
    GFun = get_guard(TR, Info, Mps1),
    add_fun_def(Type, none, Mps1, FunVFun, GFun).

encode_basic_pred(Type, FunName, QGuardFun, Mps) ->
    FunVFun = fun(_) ->
                   fun(Item) ->
                           ?q(?s(FunName)(?s(Item)))
                   end
           end,
    GFun = fun(Item) ->
                   ?q(?s(QGuardFun)(?s(Item)))
           end,
    add_fun_def(Type, none, Mps, FunVFun, GFun).


%%
%% JSON emitter functions 
%%
integer_to_json(I) ->
    list_to_binary(integer_to_list(I)).

float_to_json(F) ->
    list_to_binary(io_lib_format:fwrite_g(F)).

binary_to_json(B) ->    
    [$", escape_binary(B), $"].

string_to_json(Str) ->
    binary_to_json(list_to_binary(Str)).

boolean_to_json(true) ->
    <<"true">>;
boolean_to_json(false) ->
    <<"false">>.

atom_to_json(A) ->
    <<$\", (atom_to_binary(A, utf8))/binary, $\">>.


escape_binary(Bin) ->
    escape_iter(Bin, Bin, 0, []).

escape_iter(<<>>, Bin, _, []) ->
    Bin;
escape_iter(<<>>, Bin, _, Acc) ->
    lists:reverse([Bin|Acc]);
escape_iter(<<$", Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\\"">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\\, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\\\">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$/, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\/">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\b, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\b">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\f, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\f">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\n, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\n">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\r, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\r">>, binary:part(Bin, 0, Len) | Acc]);
escape_iter(<<$\t, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Rest, 0, [<<"\\t">>, binary:part(Bin, 0, Len) | Acc]);

escape_iter(<<_/utf8, Rest/binary>>, Bin, Len, Acc) ->
    escape_iter(Rest, Bin, Len+1, Acc);
escape_iter(Inv, _, _, _) ->
    error({invalid_unicode, Inv}).


%%
%% Utils
%%
-spec norm_type_quote(type_quote()) -> norm_type().
norm_type_quote(?RECORD_QUOTE(Name)) ->
    {record,[{atom,Name}]};
norm_type_quote(?TYPE_QUOTE(Name, Args)) ->
    Args1 = [norm_type_quote(A) || A <- Args],
    {Name, Args1};
norm_type_quote(?LIST_QUOTE(Elem)) ->
    InnerType = norm_type_quote(Elem),
    {list, [InnerType]}.

type_ref({type, _Ln, Tag, Args}) ->
    {Tag, [type_ref(A) || A <- Args]};
type_ref({atom, _Ln, Atom}) ->
    {atom, Atom};
type_ref(Converted) ->
    Converted.

ground_type({Name, Def, Params}, Args) ->
    PAs = lists:zip(Params, Args),
    Ls = lists:map(
           fun({{var, _, P}, TA}) ->
                   {P, TA}
           end, PAs),
    DC = dict:from_list(Ls),
    Fun = fun({var, _Ln, P}) ->
                  dict:fetch(P, DC);
             (Smt) ->
                  Smt
          end,
    Def1 = map(Fun, Def),
    {Name, Def1, []}.

add_fun_def(Type, Def, Mps) ->
    add_fun_def(Type, Def, Mps, id).

add_fun_def(Type, Def, Mps, FunVFun) ->
    add_fun_def(Type, Def, Mps, FunVFun, none).

add_fun_def(Type, Def, Mps, id, GFun) ->
    FunVFun = fun(QFunName) ->
                   fun(Item) ->
                           ?q(?s(QFunName)(?s(Item)))
                   end
              end,
    add_fun_def(Type, Def, Mps, FunVFun, GFun);
add_fun_def(Type, Def, #mps{defs = Defs} = Mps, FunVFun, GFun) ->
    Ind = dict:size(Defs),
    FN = list_to_atom("Fun" ++ integer_to_list(Ind)),
    FunName = ?v(?re(erl_syntax:revert(erl_syntax:variable(FN)))),
    VFun = FunVFun(FunName),
    FDef = #def_funs
        {ind = Ind,
         fun_name = FunName,
         v_fun = VFun,
         def = Def,
         g_fun = GFun},
    Defs1 = dict:store(Type, FDef, Defs),
    {FDef, Mps#mps{defs = Defs1}}.


get_guard(Type, Info, Mps) ->
    {#def_funs{g_fun = GFun}, _} = fetch(Type, Info, Mps),
    GFun.


json_fun({Mod,Fun}) ->
    QM = ?v(?re(erl_parse:abstract(Mod))),
    QF = ?v(?re(erl_parse:abstract(Fun))),
    fun(_) ->
            fun(Item) ->
                    ?q(?s(QM):?s(QF)(?s(Item)))
            end
    end;
json_fun(LocalFun) ->
    QFun = ?v(?re(erl_parse:abstract(LocalFun))),
    fun(_) ->
            fun(Item) ->
                    ?q(?s(QFun)(?s(Item)))
            end
    end.

nullable_kind({atom, undefined}) ->
     null;
nullable_kind(Type) ->
    case is_undefinable(Type) of
        true ->
            nullable;
        false ->
            non_nullable
    end.

is_undefinable({union, Types}) ->
    lists:any(fun is_undefinable/1, Types);
is_undefinable({atom, undefined}) ->
    true;
is_undefinable(_Type) ->
    false.


handle_encoder({Type, FunRef}) ->
    Type1 = option_type_norm(Type),
    FunRef1 = option_fun_norm(FunRef), 
    {Type1, FunRef1};
handle_encoder(Inv) ->
    meta:error(?MODULE, {invalid_encoder_option, Inv}).

handle_surrogate({Type, Surrogate}) ->
    {option_type_norm(Type), option_type_norm(Surrogate)};
handle_surrogate(Inv) ->
    meta:error(?MODULE, {invalid_surrogate_option, Inv}).

option_type_norm({record, Name}) when is_atom(Name) ->
    {record,[{atom,Name}]};
option_type_norm({Type, Args})
  when is_atom(Type) andalso is_list(Args) ->
    Args1 = [option_type_norm(A) || A <- Args],
    {Type, Args1};
option_type_norm(Inv) ->
    meta:error(?MODULE, {invalid_type_reference, Inv}).

option_fun_norm({Mod, FunName} = FunRef)
  when is_atom(Mod) andalso is_atom(FunName) ->
    FunRef;
option_fun_norm(FunName) when is_atom(FunName) ->
    FunName;
option_fun_norm(Inv) ->
    meta:error(?MODULE, {invalid_fun_reference, Inv}).




%%
%% Formats error messages for compiler 
%%
-spec format_error(any()) -> iolist().
format_error({unexpected_type, Type}) ->
    format("Don't know how to encode type ~p",
           [type_to_list(Type)]);
format_error({loop, Type}) ->
    format("Cannot handle recursive type definition for type ~p",
           [type_to_list(Type)]);
format_error({invalid_encoder_option, Inv}) ->
    format("Invalid 'encoder' option: ~p", [Inv]);
format_error({invalid_surrogate_option, Inv}) ->
    format("Invalid 'surrogate_type' option: ~p", [Inv]);
format_error({invalid_type_reference, Inv}) ->
    format("Invalid type reference in option list: ~p", [Inv]);
format_error({invalid_fun_reference, Inv}) ->
    format("Invalid function reference in option list: ~p", [Inv]);
format_error({tuple_unsupported, Type}) ->
    format("Don't know how to encode tuple type ~p",
           [type_to_list(Type)]).


type_to_list({union, Types}) ->
    string:join([type_to_list(T) || T <- Types], " | ");
type_to_list({record, [{atom, Name}]}) ->
    lists:flatten(format("#~s{}", [Name]));
type_to_list({atom, Atom}) ->
    atom_to_list(Atom);
type_to_list({Name, Args}) ->
    Args1 = string:join([type_to_list(T) || T <- Args], ","),
    lists:flatten(format("~s(~s)", [Name, Args1])).

format(Format, Args) ->
    io_lib:format(Format, Args).


%%
%% Depth-first map
%%
map(Fun, Form) when is_tuple(Form) ->
    Fs = tuple_to_list(Form),
    Fs1 = map(Fun, Fs),
    Form1 = list_to_tuple(Fs1),
    Fun(Form1);
map(Fun, Fs) when is_list(Fs) ->
    [map(Fun, F) || F <- Fs];
map(Fun, Smt) ->
    Fun(Smt).
