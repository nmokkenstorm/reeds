-module(reeds_rescue_ffi).
-export([rescue/1]).

%% gleam_httpc's normalise_error raises on transport errors it does not
%% recognise (socket_closed_remotely, {shutdown, server_closed}), which kills
%% the polling actor. Catch anything a thunk throws and hand it back as data.
rescue(F) ->
    try
        {ok, F()}
    catch
        Class:Reason ->
            Detail = io_lib:format("~p:~p", [Class, Reason]),
            {error, unicode:characters_to_binary(Detail)}
    end.
