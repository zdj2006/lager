-module(lager_file_writer).
-behaviour(gen_server).

-record(state, {
        file :: string(),
        fd :: file:io_device(),
        inode :: integer(),
        size = 0 :: non_neg_integer(),
        date,
        count,
        check_interval,
        sync_interval,
        sync_size,
        last_check = os:timestamp()
    }).

-export([start_link/7, write/2, write/3, sync_write/2, sync_write/3, close/1]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% public API
start_link(FileName, SyncSize, SyncInterval, CheckInterval, RotationSize, RotationDate, RotationCount) ->
    gen_server:start_link(?MODULE, [
            FileName, SyncSize,
            SyncInterval, CheckInterval,
            RotationSize, RotationDate, RotationCount], []).

write(Pid, Message) ->
    write(Pid, Message, os:timestamp()).

write(Pid, Message, Now) ->
    gen_server:call(Pid, {write, Message, Now}).

sync_write(Pid, Message) ->
    sync_write(Pid, Message, os:timestamp()).

sync_write(Pid, Message, Now) ->
    gen_server:call(Pid, {sync_write, Message, Now}).

close(Pid) ->
    gen_server:call(Pid, stop).

%% gen_server API
init([FileName, SyncSize, SyncInterval, CheckInterval,
        RotationSize, RotationDate, RotationCount]) ->
    case lager_util:open_logfile(FileName, {SyncSize, SyncInterval}) of
        {ok, {FD, Inode, _}} ->
            schedule_rotation(RotationDate),
            {ok, #state{fd=FD, inode=Inode, file=FileName, size=RotationSize,
                date=RotationDate, count=RotationCount, check_interval=CheckInterval,
                sync_interval=SyncInterval, sync_size=SyncSize}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({write, Msg, Now}, _From, State) ->
    write(Msg, Now, false, State);
handle_call({sync_write, Msg, Now}, _From, State) ->
    write(Msg, Now, true, State).

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(rotate, #state{file=File,count=Count,date=Date} = State) ->
    lager_util:rotate_logfile(File, Count),
    schedule_rotation(Date),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{fd=FD}) ->
    %% flush and close any file handles
    _ = file:datasync(FD),
    _ = file:close(FD),
    ok.

%% internal functions
schedule_rotation(undefined) ->
    ok;
schedule_rotation(Date) ->
    erlang:send_after(lager_util:calculate_next_rotation(Date) * 1000, self(), rotate),
    ok.

write(Msg, Timestamp, Sync, #state{file=Name, fd=FD, inode=Inode, size=RotSize,
        count=Count} = State) ->
    LastCheck = timer:now_diff(os:timestamp(), Timestamp) div 1000,
    case LastCheck >= State#state.check_interval orelse FD == undefined of
        true ->
            %% need to check for rotation
            case lager_util:ensure_logfile(Name, FD, Inode, {State#state.sync_size, State#state.sync_interval}) of
                {ok, {_, _, Size}} when RotSize /= 0, Size > RotSize ->
                    lager_util:rotate_logfile(Name, Count),
                    %% go around the loop again, we'll do another rotation check and hit the next clause here
                    write(Msg, Sync, State);
                {ok, {NewFD, NewInode, _}} ->
                    %% update our last check and try again
                    do_write(Msg, Sync, State#state{last_check=Timestamp, fd=NewFD, inode=NewInode});
                {error, Reason} ->
                    {reply, {open_error, Reason}, State}
            end;
        false ->
            do_write(Msg, Sync, State)
    end.

do_write(Msg, Sync, #state{fd=FD} = State) ->
    %% delayed_write doesn't report errors
    case file:write(FD, Msg) of
        ok ->
            case Sync of
                true ->
                    case file:datasync(FD) of
                        ok ->
                            {reply, ok, State};
                        {error, Reason} ->
                            {reply, {write_error, Reason}, State}
                    end;
                _ -> 
                    {reply, ok, State}
            end;
        {error, Reason} ->
            {reply, {write_error, Reason}, State}
    end.



