unit nc_unix_socket_server;

{$codepage utf8}
{$mode delphiunicode}
{$H+}

interface

{$IFNDEF UNIX}
{$FATAL This unit is only available on Unix platforms}
{$ENDIF}

uses
    SysUtils,
    Contnrs,
    nc_engine_service;

type
    EncUnixSocketServerError = class(Exception);

    TncUnixSocketServer = class
    private
        FSocketPath: string;
        FEngine: TncEngineService;
        FListenSocket: LongInt;
        FLockFile: LongInt;
        FOwnsSocketPath: Boolean;
        FShutdownRequested: Boolean;
        FClients: TObjectList;
        FNextInternalContextId: QWord;
        FParentPid: LongInt;
        // TncPollWatcher, with char_lm_deferred.
        FPollWatcher: TObject;
        procedure PrepareSocketDirectory;
        procedure OpenSocket;
        procedure CloseSocket;
        procedure AcceptClient;
        function AllocateInternalContextId: QWord;
        function ProcessClient(const client: TObject): Boolean;
        procedure BeginPoll(const client: TObject);
    public
        constructor Create(const socket_path: string;
            const engine: TncEngineService; const parent_pid: LongInt = 0);
        destructor Destroy; override;
        procedure Run;
    end;

implementation

uses
    BaseUnix,
    Unix,
    Sockets,
    Classes,
    nc_types,
    nc_cache_policy,
    nc_ipc_protocol,
    nc_ipc_payload,
    nc_ipc_dispatcher;

{$IFDEF DARWIN}
const SO_NOSIGPIPE = $1022;
{$ENDIF}

const
    c_socket_backlog = 16;
    c_maximum_clients = 16;
    c_maximum_contexts_per_client = 256;
    c_receive_buffer_size = 64 * 1024;

type
    TncContextMapping = record
        external_id: QWord;
        internal_id: QWord;
    end;
    TncContextMappings = array of TncContextMapping;

    TncUnixClientConnection = class
    private
        FSocket: LongInt;
        FEngine: TncEngineService;
        FDispatcher: TncIpcDispatcher;
        FInputBuffer: TBytes;
        FContexts: TncContextMappings;
        function FindContextIndex(const external_id: QWord): Integer;
    public
        constructor Create(const socket_handle: LongInt;
            const engine: TncEngineService);
        destructor Destroy; override;
        function ReadAvailable: Boolean;
        function TryExtractFrame(out frame: TBytes;
            out invalid_frame: Boolean): Boolean;
        function WriteFrame(const frame: TBytes): Boolean;
        function ResolveContext(const external_id: QWord;
            out internal_id: QWord): Boolean;
        function AddContext(const external_id: QWord;
            const internal_id: QWord): Boolean;
        procedure RemoveContextMapping(const external_id: QWord);
        procedure DestroyMappedContext(const external_id: QWord);
        property SocketHandle: LongInt read FSocket;
        property Dispatcher: TncIpcDispatcher read FDispatcher;
        { Whether what was read but not yet served begins with a letter or a
          backspace (FrameIsEditingKey). }
        function BufferedEditingKey: Boolean;
    end;

    { While a poll reruns a key's candidates with the character LM
      (char_lm_deferred), a thread watches the clients' sockets. A pinyin letter
      or a backspace arriving there ends the pass early (InterruptCharLmPass), as
      the iOS keyboard does in process, and is served as soon as the poll
      returns. The server is single-threaded and reads nothing during a request;
      the watcher only peeks. A commit key waits for the pass, so that what it
      commits is what the model ranked. }
    TncPollWatcher = class(TThread)
    private
        FEngine: TncEngineService;
        FLock: TRTLCriticalSection;
        FWake: PRTLEvent;
        FSockets: array of LongInt;
        FWatching: LongInt;
    protected
        procedure Execute; override;
    public
        constructor Create(const engine: TncEngineService);
        destructor Destroy; override;
        procedure Watch(const sockets: array of LongInt);
        procedure Unwatch;
    end;

function ReadUInt32Le(const value: TBytes; const offset: SizeInt): Cardinal;
var
    index: Integer;
begin
    Result := 0;
    for index := 0 to 3 do
        Result := Result or
            (Cardinal(value[offset + index]) shl (index * 8));
end;

{ Whether bytes begin with a whole key frame for a pinyin letter or a backspace:
  a key that edits the composition and so makes a running candidate pass stale. }
function FrameIsEditingKey(const bytes: TBytes; const count: SizeInt): Boolean;
var
    frame: TBytes;
    envelope: TncIpcEnvelope;
    consumed: SizeInt;
    error_text: string;
    key_event: TncKeyEvent;
    first: Char;
begin
    Result := False;
    if count < c_ipc_header_size then
        Exit;
    frame := Copy(bytes, 0, count);
    if not nc_try_decode_ipc_frame(frame, envelope, consumed, error_text) or
        (envelope.message_type <> imt_process_key) or
        not nc_try_decode_key_event_payload(envelope.payload, key_event, error_text) or
        key_event.is_release or
        (key_event.modifiers * [km_shift, km_control, km_alt, km_super] <> []) then
        Exit;
    if key_event.special_key = sk_backspace then
        Exit(True);
    if (key_event.special_key <> sk_none) or (Length(key_event.text) <> 1) then
        Exit;
    first := key_event.text[1];
    Result := ((first >= 'a') and (first <= 'z')) or (first = '''');
end;

constructor TncPollWatcher.Create(const engine: TncEngineService);
begin
    FEngine := engine;
    InitCriticalSection(FLock);
    FWake := RTLEventCreate;
    FWatching := 0;
    inherited Create(False);
end;

destructor TncPollWatcher.Destroy;
begin
    Terminate;
    InterlockedExchange(FWatching, 0);
    RTLEventSetEvent(FWake);
    WaitFor;
    RTLEventDestroy(FWake);
    DoneCriticalSection(FLock);
    inherited Destroy;
end;

procedure TncPollWatcher.Watch(const sockets: array of LongInt);
var
    index: Integer;
begin
    EnterCriticalSection(FLock);
    SetLength(FSockets, Length(sockets));
    for index := 0 to High(sockets) do
        FSockets[index] := sockets[index];
    LeaveCriticalSection(FLock);
    InterlockedExchange(FWatching, 1);
    RTLEventSetEvent(FWake);
end;

procedure TncPollWatcher.Unwatch;
begin
    InterlockedExchange(FWatching, 0);
end;

procedure TncPollWatcher.Execute;
var
    fds: array of pollfd;
    peeked: TBytes;
    index: Integer;
    received: ssize_t;
    arriving: Boolean;
begin
    SetLength(peeked, 4096);
    while not Terminated do
    begin
        RTLEventWaitFor(FWake);
        if Terminated then
            Break;
        EnterCriticalSection(FLock);
        SetLength(fds, Length(FSockets));
        for index := 0 to High(FSockets) do
        begin
            fds[index].fd := FSockets[index];
            fds[index].events := POLLIN;
        end;
        LeaveCriticalSection(FLock);
        while (InterlockedCompareExchange(FWatching, 0, 0) = 1) and not Terminated do
        begin
            if Length(fds) = 0 then
            begin
                Sleep(2);
                Continue;
            end;
            for index := 0 to High(fds) do
                fds[index].revents := 0;
            if fpPoll(@fds[0], Length(fds), 2) <= 0 then
                Continue;
            arriving := False;
            for index := 0 to High(fds) do
            begin
                if (fds[index].fd < 0) or ((fds[index].revents and POLLIN) = 0) then
                    Continue;
                received := fpRecv(fds[index].fd, @peeked[0], Length(peeked), MSG_PEEK);
                if received <= 0 then
                begin
                    fds[index].fd := -1;  // closed: the server will notice
                    Continue;
                end;
                if (received < c_ipc_header_size) or
                    (received < c_ipc_header_size + SizeInt(ReadUInt32Le(peeked, 40))) then
                begin
                    arriving := True;  // the rest of the frame is on its way
                    Continue;
                end;
                if FrameIsEditingKey(peeked, received) then
                begin
                    FEngine.InterruptCharLmPass;
                    InterlockedExchange(FWatching, 0);
                    Break;
                end;
                fds[index].fd := -1;  // a commit or anything else waits for the pass
            end;
            if arriving then
                Sleep(1);
        end;
    end;
end;

function TncUnixClientConnection.BufferedEditingKey: Boolean;
begin
    Result := FrameIsEditingKey(FInputBuffer, Length(FInputBuffer));
end;

function ResponseSucceeded(const response: TncIpcEnvelope): Boolean;
begin
    Result := (response.message_type <> imt_error) and
        ((response.flags and c_ipc_flag_error) = 0);
end;

constructor TncUnixClientConnection.Create(const socket_handle: LongInt;
    const engine: TncEngineService);
var enabled: LongInt;
begin
    inherited Create;
    FSocket := socket_handle;
    {$IFDEF DARWIN}
    enabled := 1;
    if fpSetSockOpt(FSocket, SOL_SOCKET, SO_NOSIGPIPE, @enabled, SizeOf(enabled)) <> 0 then
        raise EncUnixSocketServerError.Create('SO_NOSIGPIPE failed');
    {$ENDIF}
    FEngine := engine;
    FDispatcher := TncIpcDispatcher.Create(engine);
    FInputBuffer := nil;
    FContexts := nil;
end;

destructor TncUnixClientConnection.Destroy;
var
    index: Integer;
begin
    for index := 0 to High(FContexts) do
        FEngine.DestroyContext(FContexts[index].internal_id);
    FContexts := nil;
    FInputBuffer := nil;
    FDispatcher.Free;
    if FSocket >= 0 then
    begin
        fpClose(FSocket);
        FSocket := -1;
    end;
    inherited Destroy;
end;

function TncUnixClientConnection.FindContextIndex(
    const external_id: QWord): Integer;
var
    index: Integer;
begin
    for index := 0 to High(FContexts) do
        if FContexts[index].external_id = external_id then
            Exit(index);
    Result := -1;
end;

function TncUnixClientConnection.ReadAvailable: Boolean;
var
    receive_buffer: array[0..c_receive_buffer_size - 1] of Byte;
    bytes_read: SizeInt;
    previous_length: SizeInt;
begin
    bytes_read := fpRecv(FSocket, @receive_buffer[0],
        SizeOf(receive_buffer), 0);
    if bytes_read = 0 then
        Exit(False);
    if bytes_read < 0 then
    begin
        if fpGetErrNo = ESysEINTR then
            Exit(True);
        Exit(False);
    end;
    previous_length := Length(FInputBuffer);
    if previous_length > c_ipc_header_size + c_ipc_max_payload_size -
        bytes_read then
        Exit(False);
    SetLength(FInputBuffer, previous_length + bytes_read);
    Move(receive_buffer[0], FInputBuffer[previous_length], bytes_read);
    Result := True;
end;

function TncUnixClientConnection.TryExtractFrame(out frame: TBytes;
    out invalid_frame: Boolean): Boolean;
var
    payload_length: Cardinal;
    frame_length: SizeInt;
    remaining_length: SizeInt;
begin
    frame := nil;
    invalid_frame := False;
    if Length(FInputBuffer) < c_ipc_header_size then
        Exit(False);
    payload_length := ReadUInt32Le(FInputBuffer, 40);
    if payload_length > c_ipc_max_payload_size then
    begin
        invalid_frame := True;
        Exit(False);
    end;
    frame_length := c_ipc_header_size + SizeInt(payload_length);
    if Length(FInputBuffer) < frame_length then
        Exit(False);
    SetLength(frame, frame_length);
    Move(FInputBuffer[0], frame[0], frame_length);
    remaining_length := Length(FInputBuffer) - frame_length;
    if remaining_length > 0 then
        Move(FInputBuffer[frame_length], FInputBuffer[0], remaining_length);
    SetLength(FInputBuffer, remaining_length);
    Result := True;
end;

function TncUnixClientConnection.WriteFrame(const frame: TBytes): Boolean;
var
    bytes_written: SizeInt;
    total_written: SizeInt;
begin
    total_written := 0;
    while total_written < Length(frame) do
    begin
        bytes_written := fpSend(FSocket, @frame[total_written],
            Length(frame) - total_written, {$IFDEF DARWIN}0{$ELSE}MSG_NOSIGNAL{$ENDIF});
        if bytes_written < 0 then
        begin
            if fpGetErrNo = ESysEINTR then
                Continue;
            Exit(False);
        end;
        if bytes_written = 0 then
            Exit(False);
        Inc(total_written, bytes_written);
    end;
    Result := True;
end;

function TncUnixClientConnection.ResolveContext(const external_id: QWord;
    out internal_id: QWord): Boolean;
var
    index: Integer;
begin
    index := FindContextIndex(external_id);
    Result := index >= 0;
    if Result then
        internal_id := FContexts[index].internal_id
    else
        internal_id := 0;
end;

function TncUnixClientConnection.AddContext(const external_id: QWord;
    const internal_id: QWord): Boolean;
var
    index: Integer;
begin
    Result := (external_id <> 0) and (internal_id <> 0) and
        (Length(FContexts) < c_maximum_contexts_per_client) and
        (FindContextIndex(external_id) < 0);
    if not Result then
        Exit;
    index := Length(FContexts);
    SetLength(FContexts, index + 1);
    FContexts[index].external_id := external_id;
    FContexts[index].internal_id := internal_id;
end;

procedure TncUnixClientConnection.RemoveContextMapping(
    const external_id: QWord);
var
    index: Integer;
    last_index: Integer;
begin
    index := FindContextIndex(external_id);
    if index < 0 then
        Exit;
    last_index := High(FContexts);
    if index < last_index then
        Move(FContexts[index + 1], FContexts[index],
            (last_index - index) * SizeOf(TncContextMapping));
    SetLength(FContexts, last_index);
end;

procedure TncUnixClientConnection.DestroyMappedContext(
    const external_id: QWord);
var
    internal_id: QWord;
begin
    if ResolveContext(external_id, internal_id) then
        FEngine.DestroyContext(internal_id);
    RemoveContextMapping(external_id);
end;

constructor TncUnixSocketServer.Create(const socket_path: string;
    const engine: TncEngineService; const parent_pid: LongInt);
begin
    inherited Create;
    if socket_path = '' then
        raise EncUnixSocketServerError.Create('socket path must not be empty');
    if engine = nil then
        raise EncUnixSocketServerError.Create('engine must not be nil');
    FSocketPath := socket_path;
    FEngine := engine;
    FListenSocket := -1;
    FLockFile := -1;
    FOwnsSocketPath := False;
    FShutdownRequested := False;
    FClients := TObjectList.Create(True);
    FNextInternalContextId := 1;
    FParentPid := parent_pid;
    FPollWatcher := nil;
end;

destructor TncUnixSocketServer.Destroy;
begin
    FPollWatcher.Free;
    FClients.Free;
    CloseSocket;
    inherited Destroy;
end;

procedure TncUnixSocketServer.PrepareSocketDirectory;
var
    socket_directory: string;
    encoded_directory: UTF8String;
begin
    socket_directory := ExtractFileDir(FSocketPath);
    if socket_directory = '' then
        raise EncUnixSocketServerError.Create('socket directory is missing');
    if (not DirectoryExists(socket_directory)) and
        (not ForceDirectories(socket_directory)) then
        raise EncUnixSocketServerError.CreateFmt(
            'unable to create socket directory: %s', [socket_directory]);
    encoded_directory := UTF8Encode(socket_directory);
    if fpChmod(encoded_directory, &700) <> 0 then
        raise EncUnixSocketServerError.CreateFmt(
            'unable to secure socket directory: %s', [socket_directory]);
end;

procedure TncUnixSocketServer.OpenSocket;
var
    socket_address: TUnixSockAddr;
    socket_address_length: LongWord;
    encoded_path: UTF8String;
    encoded_lock_path: UTF8String;
    probe_socket: LongInt;
begin
    PrepareSocketDirectory;
    encoded_path := UTF8Encode(FSocketPath);
    if Length(encoded_path) > High(socket_address.path) then
        raise EncUnixSocketServerError.Create('socket path is too long');

    // Serialize the probe, stale-path cleanup, and bind operation. Without
    // this lock, concurrent adapters can both see no listener and each bind
    // after unlinking the other process's socket path.
    encoded_lock_path := UTF8Encode(FSocketPath + '.lock');
    FLockFile := fpOpen(encoded_lock_path, O_CREAT or O_RDWR, &600);
    if FLockFile < 0 then
        raise EncUnixSocketServerError.CreateFmt(
            'unable to open engine lock for %s: %s',
            [FSocketPath, SysErrorMessage(fpGetErrNo)]);
    if fpFlock(FLockFile, LOCK_EX or LOCK_NB) <> 0 then
        raise EncUnixSocketServerError.CreateFmt(
            'another engine is starting or listening on %s', [FSocketPath]);

    socket_address := Default(TUnixSockAddr);
    socket_address.family := AF_UNIX;
    if Length(encoded_path) > 0 then
        Move(encoded_path[1], socket_address.path[0], Length(encoded_path));
    socket_address_length := (PtrUInt(@socket_address.path[0]) -
        PtrUInt(@socket_address)) +
        Length(encoded_path) + 1;

    probe_socket := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    if probe_socket >= 0 then
    begin
        if fpConnect(probe_socket, PSockAddr(@socket_address),
            socket_address_length) = 0 then
        begin
            fpClose(probe_socket);
            raise EncUnixSocketServerError.CreateFmt(
                'another engine is already listening on %s', [FSocketPath]);
        end;
        fpClose(probe_socket);
    end;
    fpUnlink(encoded_path);
    FListenSocket := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    if FListenSocket < 0 then
        raise EncUnixSocketServerError.CreateFmt('socket() failed: %s',
            [SysErrorMessage(fpGetErrNo)]);

    if fpBind(FListenSocket, PSockAddr(@socket_address),
        socket_address_length) <> 0 then
        raise EncUnixSocketServerError.CreateFmt('bind() failed for %s: %s',
            [FSocketPath, SysErrorMessage(fpGetErrNo)]);
    FOwnsSocketPath := True;
    if fpChmod(encoded_path, &600) <> 0 then
        raise EncUnixSocketServerError.CreateFmt(
            'unable to secure socket: %s', [FSocketPath]);
    if fpListen(FListenSocket, c_socket_backlog) <> 0 then
        raise EncUnixSocketServerError.CreateFmt('listen() failed: %s',
            [SysErrorMessage(fpGetErrNo)]);
end;

procedure TncUnixSocketServer.CloseSocket;
var
    encoded_path: UTF8String;
begin
    if FListenSocket >= 0 then
    begin
        fpClose(FListenSocket);
        FListenSocket := -1;
    end;
    if FOwnsSocketPath then
    begin
        encoded_path := UTF8Encode(FSocketPath);
        fpUnlink(encoded_path);
        FOwnsSocketPath := False;
    end;
    if FLockFile >= 0 then
    begin
        fpFlock(FLockFile, LOCK_UN);
        fpClose(FLockFile);
        FLockFile := -1;
    end;
end;

procedure TncUnixSocketServer.AcceptClient;
var
    client_socket: LongInt;
begin
    client_socket := fpAccept(FListenSocket, nil, nil);
    if client_socket < 0 then
    begin
        if fpGetErrNo = ESysEINTR then
            Exit;
        raise EncUnixSocketServerError.CreateFmt('accept() failed: %s',
            [SysErrorMessage(fpGetErrNo)]);
    end;
    if (FClients.Count >= c_maximum_clients) or
        (client_socket >= SizeOf(TFDSet) * 8) then
    begin
        fpClose(client_socket);
        Exit;
    end;
    FClients.Add(TncUnixClientConnection.Create(client_socket, FEngine));
end;

function TncUnixSocketServer.AllocateInternalContextId: QWord;
begin
    Result := FNextInternalContextId;
    Inc(FNextInternalContextId);
    if FNextInternalContextId = 0 then
        FNextInternalContextId := 1;
end;

function TncUnixSocketServer.ProcessClient(const client: TObject): Boolean;
var
    connection: TncUnixClientConnection;
    request_frame: TBytes;
    response_frame: TBytes;
    request: TncIpcEnvelope;
    response: TncIpcEnvelope;
    consumed: SizeInt;
    decode_error: string;
    invalid_frame: Boolean;
    external_context_id: QWord;
    internal_context_id: QWord;
    mapping_created: Boolean;
begin
    connection := TncUnixClientConnection(client);
    if not connection.ReadAvailable then
        Exit(False);
    while connection.TryExtractFrame(request_frame, invalid_frame) do
    begin
        if not nc_try_decode_ipc_frame(request_frame, request, consumed,
            decode_error) then
            Exit(False);
        external_context_id := request.context_id;
        mapping_created := False;
        case request.message_type of
            imt_create_context:
                begin
                    if not connection.ResolveContext(external_context_id,
                        internal_context_id) then
                    begin
                        internal_context_id := AllocateInternalContextId;
                        mapping_created := connection.AddContext(
                            external_context_id, internal_context_id);
                        if not mapping_created then
                            internal_context_id := 0;
                    end;
                    request.context_id := internal_context_id;
                end;
            imt_destroy_context, imt_reset_context, imt_set_active,
            imt_set_surrounding, imt_process_key, imt_poll_result,
            imt_remove_candidate, imt_candidate_action, imt_candidate_pages:
                begin
                    if not connection.ResolveContext(external_context_id,
                        internal_context_id) then
                        internal_context_id := 0;
                    request.context_id := internal_context_id;
                end;
        end;

        if request.message_type = imt_poll_result then
            BeginPoll(connection);
        connection.Dispatcher.DispatchRequest(request, response);
        if (request.message_type = imt_poll_result) and (FPollWatcher <> nil) then
            TncPollWatcher(FPollWatcher).Unwatch;
        if mapping_created and (not ResponseSucceeded(response)) then
            connection.DestroyMappedContext(external_context_id)
        else if (request.message_type = imt_destroy_context) and
            ResponseSucceeded(response) then
            connection.RemoveContextMapping(external_context_id);
        response.context_id := external_context_id;
        response_frame := nc_encode_ipc_frame(response);
        if not connection.WriteFrame(response_frame) then
            Exit(False);
        if connection.Dispatcher.ShutdownRequested then
        begin
            FShutdownRequested := True;
            Break;
        end;
    end;
    if invalid_frame then
        Exit(False);
    Result := True;
end;

procedure TncUnixSocketServer.BeginPoll(const client: TObject);
var
    sockets: array of LongInt;
    index: Integer;
begin
    if FPollWatcher = nil then
        Exit;
    // A letter already read behind this poll would make its pass stale: skip it.
    if TncUnixClientConnection(client).BufferedEditingKey then
    begin
        FEngine.SkipNextPoll;
        Exit;
    end;
    SetLength(sockets, FClients.Count);
    for index := 0 to FClients.Count - 1 do
        sockets[index] := TncUnixClientConnection(FClients[index]).SocketHandle;
    TncPollWatcher(FPollWatcher).Watch(sockets);
end;

procedure TncUnixSocketServer.Run;
var
    read_sockets: TFDSet;
    maximum_socket: LongInt;
    selected_count: LongInt;
    client_index: Integer;
    connection: TncUnixClientConnection;
    timeout: TTimeVal;
begin
    OpenSocket;
    if g_char_lm_deferred then
        FPollWatcher := TncPollWatcher.Create(FEngine);
    WriteLn('cassotis-engine listening on ', FSocketPath);
    while not FShutdownRequested do
    begin
        if (FParentPid > 1) and (fpGetPPid <> FParentPid) then Break;
        fpFD_ZERO(read_sockets);
        fpFD_SET(FListenSocket, read_sockets);
        maximum_socket := FListenSocket;
        for client_index := 0 to FClients.Count - 1 do
        begin
            connection := TncUnixClientConnection(FClients[client_index]);
            fpFD_SET(connection.SocketHandle, read_sockets);
            if connection.SocketHandle > maximum_socket then
                maximum_socket := connection.SocketHandle;
        end;
        timeout.tv_sec := 1;
        timeout.tv_usec := 0;
        selected_count := fpSelect(maximum_socket + 1, @read_sockets,
            nil, nil, @timeout);
        if selected_count = 0 then Continue;
        if selected_count < 0 then
        begin
            if fpGetErrNo = ESysEINTR then
                Continue;
            raise EncUnixSocketServerError.CreateFmt('select() failed: %s',
                [SysErrorMessage(fpGetErrNo)]);
        end;
        if fpFD_ISSET(FListenSocket, read_sockets) <> 0 then
            AcceptClient;
        for client_index := FClients.Count - 1 downto 0 do
        begin
            connection := TncUnixClientConnection(FClients[client_index]);
            if (fpFD_ISSET(connection.SocketHandle, read_sockets) <> 0) and
                (not ProcessClient(connection)) then
                FClients.Delete(client_index);
            if FShutdownRequested then
                Break;
        end;
    end;
    FClients.Clear;
    FEngine.ClearContexts;
end;

end.
