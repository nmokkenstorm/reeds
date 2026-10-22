-module(reeds_mailbox_ffi).
-export([len/1]).

len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> {ok, N};
        undefined -> {error, nil}
    end.
