-module(jsonrec_decode).

-include_lib("meta/include/meta_syntax.hrl").
-include("parsers.hrl").


-export([decode_gen/4]).

-export([format_error/1]).


-define(TYPE_METHODS_OPT, type_methods).
-define(TYPE_SURROGATES_OPT, type_surrogates).
-define(NAME_HANDLER_OPT, name_handler).

-define(re(Syntax), erl_syntax:revert(Syntax)).

-define(TYPE(Type, Args),
        {type, _Ln3, Type, Args}).
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
         ?TYPE(_Type, _Args) = Type}).
-define(TYPED_FIELD(Name, Type, Default),
        {typed_record_field,
         ?FIELD(Name, Default),
         ?TYPE(_Type, _Args) = Type}).

-define(RECORD_QUOTE(Name),
        {record, _Ln, Name, _Args}).
-define(TYPE_QUOTE(Name, Args),
        {call, _Ln1, {atom, _Ln2, Name}, Args}).
-define(LIST_QUOTE(Elem),
        {cons, _Ln1, Elem, {lin, _Ln2}}).


-record(mps,
        {defs = [],
         subs = [],
         attrs = [],
         name_conv}).

-record(def_funs,
        {parser}).

decode_gen(QStr, Type, Info, Options) ->
    code_gen(decode, QStr, Type, Info, Options).


code_gen(Attr, QArg, Type, Info, Options) ->
    Type1 = norm_type_quote(?e(Type)),
    Subs = proplists:get_value(?TYPE_METHODS_OPT, ?e(Options), []),
    Subs1 = [norm_type(T) || T <- Subs],                      
    NameFun = proplists:get_value(?NAME_HANDLER_OPT, ?e(Options),
                                  fun atom_to_mslist/1),
    Attrs = meta:reify_attributes(Attr, ?e(Info)),
    Mps = #mps{
      defs = [],
      subs = Subs1,
      attrs = Attrs,
      name_conv = NameFun},
    {Parser, _} = gen_decode(type_ref(Type1), ?e(Info), Mps),
    ?q(case ?s(to_parser(Parser, QArg)) of
           {ok, {Val, _}} ->
               {ok, Val};
           {error, _} = E ->
               E
       end).

gen_decode({record, [{atom, RecName}]} = Type, Info, Mps) ->
    {_, Fields, []} = meta:reify_type({record, RecName}, Info),
    {Parser, Mps1} = gen_object_parser(Fields, Info, Mps),
    Size = ?v(?re(erl_parse:abstract(length(Fields) + 1))),
    Parser1 = bind(
               Parser,
               fun(QFs) ->
                       return(
                         ?q(erlang:make_tuple(
                              ?s(Size),
                              undefined,
                              ?s(with_defaults(RecName, Fields, QFs)))))
               end),
    add_fun_def(Type, Parser1, Mps1);    

gen_decode({list, [InnerType]}, Info, Mps) ->
    code_list(InnerType, Info, Mps);

gen_decode({union, Types} = Type, Info, Mps) ->
    {Parser, Mps1} = code_union(Types, Info, Mps),
    add_fun_def(Type, Parser, Mps1);

gen_decode({integer, []} = Type, _Info, Mps) ->
    P = ?q(parsers:integer_p),
    code_basic(Type, P, Mps);

gen_decode({binary, []} = Type, _Info, Mps) ->
    P = ?q(parsers:string_p),
    code_basic(Type, P, Mps);

gen_decode({float, []} = Type, _Info, Mps) ->
    P = ?q(parsers:float_p),
    code_basic(Type, P, Mps);
gen_decode({boolean, []} = Type, _Info, Mps) ->
    P = ?q(parsers:boolean_p),
    code_basic(Type, P, Mps);
gen_decode({atom, []} = Type, _Info, Mps) ->
    Parser =
        bind(
          parsers:string(),
          fun(S) ->
                  return(
                    ?q(binary_to_existing_atom(?s(S), utf8)))
          end),
    add_fun_def(Type, Parser, Mps);

gen_decode({atom, undefined} = Type, _Info, Mps) ->
    P = ?q(parsers:null_p),
    code_basic(Type, P, Mps);

gen_decode({atom, Atom} = Type, _Info, Mps) ->
    Parser =
        right(
          match(
            ?v(?re(erl_parse:abstract(
                     "\"" ++ atom_to_list(Atom) ++ "\"")))),
          return(?v(?re(erl_parse:abstract(Atom))))),
    add_fun_def(Type, Parser, Mps);

gen_decode({any, []} = Type, _Info, Mps) ->
    P = ?q(parsers:any_json_p),
    code_basic(Type, P, Mps);

gen_decode({_UserType,_Args} = Type, Info, Mps) ->
    code_underlying(Type, Info, Mps);
    
gen_decode(Type, _Info, _Mps) ->
    meta:error(?MODULE, unexpected_type_decode, Type).



gen_object_parser(Types, Info, Mps) ->
    NTs = lists:zip(lists:seq(2, length(Types)+1), Types),
    {Es, Mps1} = lists:mapfoldl(
                  fun({N,T},M) ->
                          decode_field(N, T, Info, M)
                  end, Mps, NTs),
    P = parsers:object(Es),
    {P, Mps1}.

with_defaults(RecName, Types, Tail) ->
    NTs = lists:zip(lists:seq(2, length(Types)+1), Types),
    Ds = [decode_default(N, ?v(QDef))
          || {N, ?TYPED_FIELD(_, _, QDef)} <- NTs],
    QName = ?v(?re(erl_parse:abstract(RecName))),
    Tag = ?q({1,?s(QName)}),
    ?v(?re(erl_syntax:list([?s(Tag)|?s(parsers:sequence(Ds))], ?s(Tail)))).

decode_default(Ind, QDef) ->
    QInd = ?v(?re(erl_parse:abstract(Ind))),
    ?q({?s(QInd), ?s(QDef)}).


decode_field(Ind, ?FIELD(Fn), Info, Mps) ->
    decode_record(Ind, Fn, {any, []}, Info, Mps);
decode_field(Ind, ?FIELD(Fn, _Def), Info, Mps) ->
    decode_record(Ind, Fn, {any, []}, Info, Mps);
decode_field(Ind, ?TYPED_FIELD(Fn, Type), Info, Mps) ->
    decode_record(Ind, Fn, type_ref(Type), Info, Mps);
decode_field(Ind, ?TYPED_FIELD(Fn, Type, _Def), Info, Mps) ->
    decode_record(Ind, Fn, type_ref(Type), Info, Mps).

decode_record(Index, Fn, Type, Info, #mps{name_conv = NC} = Mps) ->
    {Parser, Mps1} = fetch(Type, Info, Mps),
    QFn = ?v(?re(erl_parse:abstract(NC(Fn)))),
    QInd = ?v(?re(erl_parse:abstract(Index))),
    Triple = {QFn, Parser, QInd},
    {Triple, Mps1}. 


%%
%% General decode/encode functions
%%
fetch(Type, Info, Mps) ->
    case proplists:lookup(Type, Mps#mps.subs) of
        none ->
            Attrs = Mps#mps.attrs,
            case proplists:lookup(Type, Attrs) of
                none ->
                    case proplists:lookup(Type, Mps#mps.defs) of
                        {Type, #def_funs{parser = Parser}} ->
                            {Parser, Mps};
                        none ->
                            gen_decode(Type, Info, Mps)
                    end;
                {Type, {_,Args} = SType} when is_list(Args) ->
                    fetch(SType, Info, Mps);
                {Type, Fun} ->
                    QFun = json_fun(Fun),
                    add_fun_def(Type, lift(QFun), Mps)
            end;
        {Type, {_,Args} = SType} when is_list(Args) ->
            fetch(SType, Info, Mps);
        {Type, Fun} ->
            QFun = json_fun(Fun),
            add_fun_def(Type, lift(QFun), Mps)
    end.

code_list(InnerType, Info, Mps) -> 
    {Parser, Mps1} = fetch(type_ref(InnerType), Info, Mps),
    add_fun_def({list, [InnerType]}, parsers:array(Parser), Mps1).

code_union(Types, Info, Mps) ->
    P0 = fail(?q(none_matches)),
    {Parser, MpsN} =
        lists:foldl(
          fun(TA, {P1, Mps1}) ->
                  Type = type_ref(TA),
                  {P2, Mps2} = fetch(Type, Info, Mps1),
                  P3 = mplus(P2, P1),
                  {P3, Mps2}
          end, {P0, Mps}, Types),
    {Parser, MpsN}.

code_underlying({_, Args} = Type, Info, Mps) ->
    Type1 =  meta:reify_type(Type, Info),
    {_, Type2, []} = ground_type(Type1, Args),
    TR = type_ref(Type2),
    fetch(TR, Info, Mps).

code_basic(Type, ParserFun, Mps) ->
    add_fun_def(Type, lift(ParserFun), Mps).

%%
%% Default data conversion functions
%%
%% atom_to_msbinary(Atom) ->
%%     list_to_binary(atom_to_mslist(Atom)).

atom_to_mslist(Atom) when is_atom(Atom) ->
    List = atom_to_list(Atom),
    Parts = string:tokens(List, "_"),
    Capitalized = lists:map(fun([H|T]) -> string:to_upper([H]) ++ T end, Parts),
    lists:concat(Capitalized). 

%%
%% Utils
%%
norm_type_quote(?RECORD_QUOTE(Name)) ->
    {record,[{atom,Name}]};
norm_type_quote(?TYPE_QUOTE(Name, Args)) ->
    Args1 = [norm_type_quote(A) || A <- Args],
    {Name, Args1};
norm_type_quote(?LIST_QUOTE(Elem)) ->
    InnerType = norm_type_quote(Elem),
    {list, InnerType}.

type_ref({type, _Ln, Tag, Args}) ->
    {Tag, [type_ref(A) || A <- Args]};
type_ref({atom, _Ln, Atom}) ->
    {atom, Atom};
type_ref(Converted) ->
    Converted.

norm_type({{record, Name}, _Def, []}) ->
    {record,[{atom,Name}]};
norm_type({Name, _Def, Args}) ->
    {Name, Args};
norm_type({_Name, _Args} = Type) ->
    Type.

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


add_fun_def(Type, Parser, #mps{defs = Defs} = Mps) ->
    FDef = #def_funs{parser = Parser},
    Defs1 = [{Type,FDef}|Defs],
    {Parser, Mps#mps{defs = Defs1}}.


json_fun({Mod,Fun}) ->
    QM = ?v(?re(erl_parse:abstract(Mod))),
    QF = ?v(?re(erl_parse:abstract(Fun))),
    ?q(?s(QM):?s(QF));
json_fun(LocalFun) ->
    ?v(?re(erl_parse:abstract(LocalFun))).


%%
%% Formats error messages for compiler 
%%
format_error({unexpected_type_decode, Type}) ->
    format("Don't know how to decode type ~p", [Type]).

format(Format, Args) ->
    lists:flatten(io_lib:format(Format, Args)).

%%
%% Utils
%%

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
