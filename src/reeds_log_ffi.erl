-module(reeds_log_ffi).
-export([handler_config/3, install/3, raise_level/0, log/2]).

-define(HANDLER, reeds_file).

%% sync == drop keeps logging asynchronous: past the queue limit lines are
%% dropped instead of blocking the caller, which is the daemon.
handler_config(Path, MaxBytes, MaxFiles) ->
    #{
        level => info,
        filters => [{no_progress, {fun logger_filters:progress/2, stop}}],
        config => #{
            file => unicode:characters_to_list(Path),
            max_no_bytes => MaxBytes,
            max_no_files => MaxFiles,
            compress_on_rotate => true,
            sync_mode_qlen => 2000,
            drop_mode_qlen => 2000,
            flush_qlen => 5000
        },
        formatter =>
            {logger_formatter, #{
                template => [time, " ", level, " ", msg, "\n"],
                time_offset => "Z"
            }}
    }.

%% The default stdout handler goes only once the file handler is up, so a bad
%% path leaves the daemon logging to stdout instead of nowhere.
install(Path, MaxBytes, MaxFiles) ->
    raise_level(),
    Added =
        case filelib:ensure_dir(unicode:characters_to_list(Path)) of
            ok -> logger:add_handler(?HANDLER, logger_std_h, handler_config(Path, MaxBytes, MaxFiles));
            Error -> Error
        end,
    case Added of
        ok ->
            logger:remove_handler(default),
            {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% OTP's default primary level is notice, which drops every info line.
raise_level() ->
    logger:set_primary_config(level, info),
    nil.

log(Level, Message) ->
    logger:log(Level, Message),
    nil.
