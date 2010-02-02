%%% Copyright (C) 2009 Enrique Marcote, Miguel Rodriguez
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%% o Redistributions of source code must retain the above copyright notice,
%%%   this list of conditions and the following disclaimer.
%%%
%%% o Redistributions in binary form must reproduce the above copyright notice,
%%%   this list of conditions and the following disclaimer in the documentation
%%%   and/or other materials provided with the distribution.
%%%
%%% o Neither the name of ERLANG TRAINING AND CONSULTING nor the names of its
%%%   contributors may be used to endorse or promote products derived from this
%%%   software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
%%% LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
%%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
%%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%%% CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
%%% ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%%% POSSIBILITY OF SUCH DAMAGE.
-module(smpp_session).

%%% INCLUDE FILES
-include_lib("oserl/include/oserl.hrl").

%%% EXTERNAL EXPORTS
-export([congestion/3, connect/1, listen/1]).

%%% SOCKET LISTENER FUNCTIONS EXPORTS
-export([wait_listen/3, wait_recv/3, wait_recv/4, recv_loop/4]).

%% TIMER EXPORTS
-export([cancel_timer/1, start_timer/2]).

%%% MACROS
-define(CONNECT_OPTS, [binary, {packet, 0}, {active, false}]).
-define(CONNECT_TIME, 30000).
-define(LISTEN_OPTS(Addr),
        if
            Addr == undefined ->
                [binary, {packet, 0}, {active, false}, {reuseaddr, true}];
            true ->
                [binary,
                 {packet, 0},
                 {active, false},
                 {reuseaddr, true},
                 {ip, Addr}]
        end).

%%%-----------------------------------------------------------------------------
%%% EXTERNAL EXPORTS
%%%-----------------------------------------------------------------------------
%% Computes the congestion state.
%%
%% - CongestionSt: Current ``congestion_state`` value.
%% - WaitTime: Are the microseconds waiting for the PDU.
%% - Timestamp: Represents the moment when the PDU was received.
%%
%% The time since ``Timestamp`` is the PDU dispatching time.  If
%% this value equals the ``WaitTime`` (i.e. ``DispatchTime/WaitTime = 1``),
%% then we shall assume optimum load (value 85).  Having this in mind the
%% instant congestion state value is calculated.  Notice this value cannot be
%% greater than 99.
congestion(CongestionSt, WaitTime, Timestamp) ->
    case (timer:now_diff(now(), Timestamp) div (WaitTime + 1)) * 85 of
        Val when Val < 1 ->
            0;
        Val when Val > 99 ->  % Out of bounds
            ((19 * CongestionSt) + 99) div 20;
        Val ->
            ((19 * CongestionSt) + Val) div 20
    end.


connect(Opts) ->
    case proplists:get_value(sock, Opts, undefined) of
        undefined ->
            Addr = proplists:get_value(addr, Opts),
            Port = proplists:get_value(port, Opts, ?DEFAULT_SMPP_PORT),
            gen_tcp:connect(Addr, Port, ?CONNECT_OPTS, ?CONNECT_TIME);
        Sock ->
            case inet:setopts(Sock, ?CONNECT_OPTS) of
                ok ->
                    {ok, Sock};
                Error ->
                    Error
            end
    end.


listen(Opts) ->
    case proplists:get_value(lsock, Opts, undefined) of
        undefined ->
            Addr = proplists:get_value(addr, Opts, default_addr()),
            Port = proplists:get_value(port, Opts, ?DEFAULT_SMPP_PORT),
            gen_tcp:listen(Port, ?LISTEN_OPTS(Addr));
        LSock ->
            Addr = proplists:get_value(addr, Opts, default_addr()),
            case inet:setopts(LSock, ?LISTEN_OPTS(Addr)) of
                ok ->
                    {ok, LSock};
                Error ->
                    Error
            end
    end.

%%%-----------------------------------------------------------------------------
%%% SOCKET LISTENER FUNCTIONS
%%%-----------------------------------------------------------------------------
handle_accept(Pid, Sock) ->
    ok = gen_tcp:controlling_process(Sock, Pid),
    case inet:peername(Sock) of
        {ok, {Addr, _Port}} ->
            gen_fsm:send_event(Pid, {accept, Sock, Addr}),
            true;
        {error, _Reason} ->  % Most probably the socket is closed
            false
    end.


handle_input(Pid, <<CmdLen:32, Rest/binary>> = Buffer, Lapse, N, Log) ->
    Now = now(), % PDU received.  PDU handling starts now!
    Len = CmdLen - 4,
    case Rest of
        <<PduRest:Len/binary-unit:8, NextPdus/binary>> ->
            BinPdu = <<CmdLen:32, PduRest/binary>>,
            case catch smpp_operation:unpack(BinPdu) of
                {ok, Pdu} ->
                    smpp_log_mgr:pdu(Log, BinPdu),
                    CmdId = smpp_operation:get_value(command_id, Pdu),
                    Event = {input, CmdId, Pdu, (Lapse div N), Now},
                    gen_fsm:send_all_state_event(Pid, Event);
                {error, _CmdId, _Status, _SeqNum} = Event ->
                    gen_fsm:send_all_state_event(Pid, Event);
                {'EXIT', _What} ->
                    Event = {error, 0, ?ESME_RUNKNOWNERR, 0},
                    gen_fsm:send_all_state_event(Pid, Event)
            end,
            % The buffer may carry more than one SMPP PDU.
            handle_input(Pid, NextPdus, Lapse, N + 1, Log);
        _IncompletePdu ->
            Buffer
    end;
handle_input(_Pid, Buffer, _Lapse, _N, _Log) ->
    Buffer.


wait_listen(Pid, LSock, Log) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            case handle_accept(Pid, Sock) of
                true ->
                    wait_recv(Pid, Sock, Log);
                false ->
                    ?MODULE:wait_listen(Pid, LSock, Log)
            end;
        {error, Reason} ->
            gen_fsm:send_all_state_event(Pid, {listen_error, Reason})
    end.


wait_recv(Pid, Sock, Log) ->
    ?MODULE:wait_recv(Pid, Sock, <<>>, Log).

wait_recv(Pid, Sock, Buffer, Log) ->
    Timestamp = now(),
    case gen_tcp:recv(Sock, 0) of
        {ok, Input} ->
            L = timer:now_diff(now(), Timestamp),
            B = handle_input(Pid, concat_binary([Buffer, Input]), L, 1, Log),
            case recv_loop(Pid, Sock, B, Log) of
                {ok, NewBuffer} ->
                    ?MODULE:wait_recv(Pid, Sock, NewBuffer, Log);
                RecvError ->
                    gen_fsm:send_all_state_event(Pid, RecvError)
            end;
        {error, Reason} ->
            gen_fsm:send_all_state_event(Pid, {sock_error, Reason})
    end.

recv_loop(Pid, Sock, Buffer, Log) ->
    case gen_tcp:recv(Sock, 0, 0) of
        {ok, Input} ->                    % Some input waiting already
            B = handle_input(Pid, concat_binary([Buffer, Input]), 0, 1, Log),
            ?MODULE:recv_loop(Pid, Sock, B, Log);
        {error, timeout} ->               % No data inmediately available
            {ok, Buffer};
        {error, Reason} ->
            {sock_error, Reason}
    end.

%%%-----------------------------------------------------------------------------
%%% TIMER FUNCTIONS
%%%-----------------------------------------------------------------------------
cancel_timer(undefined) ->
    false;
cancel_timer(Ref) ->
    gen_fsm:cancel_timer(Ref).


start_timer(#timers_smpp{response_time = infinity}, {response_timer, _}) ->
    undefined;
start_timer(#timers_smpp{response_time = infinity}, enquire_link_failure) ->
    undefined;
start_timer(#timers_smpp{enquire_link_time = infinity}, enquire_link_timer) ->
    undefined;
start_timer(#timers_smpp{session_init_time = infinity}, session_init_timer) ->
    undefined;
start_timer(#timers_smpp{inactivity_time = infinity}, inactivity_timer) ->
    undefined;
start_timer(#timers_smpp{response_time = Time}, {response_timer, _} = Msg) ->
    gen_fsm:start_timer(Time, Msg);
start_timer(#timers_smpp{response_time = Time}, enquire_link_failure) ->
    gen_fsm:start_timer(Time, enquire_link_failure);
start_timer(#timers_smpp{enquire_link_time = Time}, enquire_link_timer) ->
    gen_fsm:start_timer(Time, enquire_link_timer);
start_timer(#timers_smpp{session_init_time = Time}, session_init_timer) ->
    gen_fsm:start_timer(Time, session_init_timer);
start_timer(#timers_smpp{inactivity_time = Time}, inactivity_timer) ->
    gen_fsm:start_timer(Time, inactivity_timer).

%%%-----------------------------------------------------------------------------
%%% INTERNAL FUNCTIONS
%%%-----------------------------------------------------------------------------
default_addr() ->
    {ok, Host} = inet:gethostname(),
    {ok, Addr} = inet:getaddr(Host, inet),
    Addr.