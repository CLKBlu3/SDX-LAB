-module(node4).
-export([start/1, start/2]).

-define(Stabilize, 1000).
-define(Timeout, 5000).

start(MyKey) ->
    start(MyKey, nil).

start(MyKey, PeerPid) ->
    timer:start(),
    spawn(fun() -> init(MyKey, PeerPid) end).

init(MyKey, PeerPid) ->
    Predecessor = nil,
    {ok, Successor} = connect(MyKey, PeerPid),
    schedule_stabilize(),    
    node(MyKey, Predecessor, Successor, storage:create(), nil, storage:create()). 
    %%He suposat que l'anell esta buit i no hi ha ningu a qui referencia com a "Next"

connect(MyKey, nil) ->
    {ok, {MyKey, nil ,self()}};    %% TODO: ADD SOME CODE
connect(_, PeerPid) ->
    Qref = make_ref(),
    PeerPid ! {key, Qref, self()},
    receive
        {Qref, Skey} ->
            {ok, {Skey, monit(PeerPid),PeerPid}}    %% TODO: ADD SOME CODE
    after ?Timeout ->
        io:format("Timeout: no response from ~w~n", [PeerPid])
    end.
monit(Pid) ->
    erlang:monitor(process,Pid).

demonit(nil) ->
    ok;

demonit(MonitorRef) ->
    erlang:demonitor(MonitorRef, [flush]).

schedule_stabilize() ->
    timer:send_interval(?Stabilize, self(), stabilize).

node(MyKey, Predecessor, Successor, Store, Next, Replica) ->
    receive 
        {key, Qref, Peer} ->
            Peer ! {Qref, MyKey},
            node(MyKey, Predecessor, Successor, Store,Next, Replica);
        {notify, NewPeer} ->
            NewPredecessor = notify(NewPeer, MyKey, Predecessor, Store),
            node(MyKey, NewPredecessor, Successor, Store,Next, Replica);
        {request, Peer} ->
            request(Peer, Predecessor,Successor),
            node(MyKey, Predecessor, Successor, Store,Next, Replica);
        {status, Pred, Nx} ->
            {NewSuccessor, NewNext} = stabilize(Pred, Nx ,MyKey, Successor),
            node(MyKey, Predecessor, NewSuccessor, Store, NewNext, Replica);
        stabilize ->
            stabilize(Successor),
            node(MyKey, Predecessor, Successor, Store,Next,Replica);
        stop ->
            ok;
        {add, Key, Value, Qref, Client} ->
            Added = add(Key, Value, Qref, Client, MyKey, Predecessor, Successor, Store),
            node(MyKey, Predecessor, Successor, Added, Next,Replica); %%crec que aqui no hi ha que canviar el valor de next encara
        {lookup, Key, Qref, Client} ->
            lookup(Key, Qref, Client, MyKey, Predecessor, Successor, Store),
            node(MyKey, Predecessor, Successor, Store, Next,Replica); %%No es canvia tampoc elvalor de "next"
        probe ->
            create_probe(MyKey, Successor),
            node(MyKey, Predecessor, Successor, Store, Next,Replica);
        {probe, MyKey, Nodes, T} ->
            remove_probe(MyKey, Nodes, T, Store, Replica),
            node(MyKey, Predecessor, Successor, Store, Next,Replica);
        {probe, RefKey, Nodes, T} ->
            forward_probe(RefKey, [MyKey|Nodes], T, Successor, Store, Replica),
            node(MyKey, Predecessor, Successor, Store, Next,Replica);
        {handover, Elements} ->
            Merged = storage:merge(Store, Elements),
            {_, _, Spid} = Successor,
            Spid ! {pushreplica, Merged},
            node(MyKey, Predecessor, Successor, Merged, Next,Replica);
        {'DOWN', Ref, process, _,_} ->
            {NewPred, NewSucc, NewNext, NewStore} = down(Ref, Predecessor, Successor, Next, Store, Replica),
            {_, _, Spid} = Successor,
            Spid ! {pushreplica, NewStore},
            node(MyKey, NewPred, NewSucc, NewStore, NewNext, storage:create());
            %%Ho he girat perque nosaltres tenim la capçalera diferent a l'enunciat
        {replicate, Key, Value} ->
            NewReplica = storage:add(Key,Value, Replica),
            node(MyKey, Predecessor, Successor, Store, Next, NewReplica);
        {pushreplica, NewReplica} ->
            node(MyKey, Predecessor, Successor, Store, Next, NewReplica)
   end.

stabilize(Pred, Next, MyKey, Successor) -> 
  {Skey, Sref , Spid} = Successor,
  case Pred of
      nil -> %%esto
          Spid ! {notify, {MyKey, self()}},
          {Successor, Next};
      {MyKey, _, _} ->
          {Successor, Next};
      {Skey, _, _} -> %%esto
          Spid ! {notify, {MyKey, self()}},
          {Successor, Next};
      {Xkey, _, Xpid} ->
            case key:between(Xkey, MyKey, Skey) of
                true ->%%esto
                    %Successor = stabilize(Xkey, MyKey, Skey),
                    %Successor;
                    self() ! stabilize,
                    demonit(Sref),
                    {{Xkey,monit(Xpid),Xpid}, Successor};
                false ->%%esto
                    Spid ! {notify, {MyKey, self()}},
                    {Successor, Next} %%esto no
            end
    end.

stabilize({_, _,Spid}) ->
    Spid ! {request, self()}.

request(Peer, Predecessor, Successor) ->
    case Predecessor of
        nil ->
            Peer ! {status, nil,Successor};
        {Pkey, Pref, Ppid} ->
            Peer ! {status, {Pkey, Pref,Ppid},Successor}
    end.

notify({Nkey,Npid}, MyKey, Predecessor, Store) ->
    case Predecessor of
        nil -> %%esto
            Keep = handover(Store, MyKey, Nkey, Npid),
            {Keep, monit(Npid), Npid};
            %{Nkey, Npid};
        {Pkey, Pref  , _} ->
            case key:between(Nkey, Pkey, MyKey) of
                true -> %%esto
                    demonit(Pref),
                    N = {Nkey, monit(Npid), Npid},
                    N;
                false -> 
                    {Predecessor, Store}
                    %%Predecessor %% TT
            end
    end.

create_probe(MyKey, {_, _, Spid}) ->
    Spid ! {probe, MyKey, [MyKey], erlang:monotonic_time()},
    io:format("Create probe ~w!~n", [MyKey]).
	
remove_probe(MyKey, Nodes, T, Store, Replica) ->
    T2 = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(T2-T, native, millisecond),
    io:format("Store: ~w ~n", [Store]),
    io:format("Replica: ~w ~n", [Replica]),
    io:format("Received probe ~w in ~w ms Ring: ~w~n", [MyKey, Time, Nodes]).
	
forward_probe(RefKey, Nodes, T, {_, _, Spid}, Store, Replica) ->
    Spid ! {probe, RefKey, Nodes, T},
    io:format("Store: ~w ~n", [Store]),
    io:format("Replica: ~w ~n", [Replica]),
    io:format("Forward probe ~w!~n", [RefKey]).

add(Key, Value, Qref, Client, MyKey, {Pkey, _, _}, {_, _, Spid}, Store) ->
    case key:between(Key, Pkey , MyKey)  of    %% TODO: ADD SOME CODE
        true ->
            Spid ! {replicate, Key, Value},
            Added = storage:add(Key, Value, Store),    %% TODO: ADD SOME CODE
            Client ! {Qref, ok},
            Added;
        false ->
            Spid ! {add, Key, Value, Qref, Client}, %% TODO: ADD SOME CODE
            Store
    end.

lookup(Key, Qref, Client, MyKey, {Pkey, _, _}, {_, _,Spid}, Store) ->
    case key:between(Key , Pkey , MyKey)  of    %% TODO: ADD SOME CODE
        true ->
            Result = storage:lookup(Key, Store),    %% TODO: ADD SOME CODE
            Client ! {Qref, Result};
        false ->
            Spid ! {lookup, Key, Qref, Client} %% TODO: ADD SOME CODE
    end.

handover(Store, MyKey, Nkey, Npid) ->
    {Keep, Leave} = storage:split(MyKey, Nkey, Store),
    Npid ! {handover, Leave},
    Keep.


down(Ref, {_,Ref,_}, Successor, Next, Store, Replica) ->
    Merged = storage:merge(Store, Replica),
    {nil, Successor, Next, Merged};

down(Ref, Predecessor, {_,Ref,_}, {Nkey, _, Npid}, Store, Replica) ->
    %TODO add some code Ramoneta = monit(Npid)??
    self() ! stabilize, % add some code
    {Predecessor, {Nkey, monit(Npid), Npid}, nil, Store, Replica}. 
    %%He passat Nref a monit(Npid), no se si afecta al funcionament 
    %%si assignem monit(Npid) abans de stabilize --> TODO: provar-ho