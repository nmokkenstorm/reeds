-module(reeds_hostname_ffi).
-export([hostname/0]).

hostname() ->
    case inet:gethostname() of
        {ok, Host} -> unicode:characters_to_binary(Host);
        _ -> <<"unknown">>
    end.
