unit nc_core_bridge;

{ The C ABI of cassotis_core.h. This is the only unit an embedding host sees:
  it stands where nc_unix_socket_server stands in the macOS engine. No Pascal
  exception may cross it. The host passes the one context id it created through
  unchanged, so no external/internal mapping is needed here. }

{$codepage utf8}
{$mode delphiunicode}
{$H+}

interface

function cassotis_core_open(dictionary_path, user_dictionary_path,
    resource_dir, data_dir: PAnsiChar): LongInt; cdecl;
function cassotis_core_dispatch(request: PByte; request_length: Cardinal;
    response: PByte; response_capacity: Cardinal): LongInt; cdecl;
function cassotis_core_last_error(buffer: PAnsiChar; capacity: Cardinal): Cardinal; cdecl;
procedure cassotis_core_trim(level: LongInt); cdecl;
procedure cassotis_core_close; cdecl;
function cassotis_core_set_option(name: PAnsiChar; value: LongInt): LongInt; cdecl;
function cassotis_core_cache_census(buffer: PAnsiChar; capacity: Cardinal): Cardinal; cdecl;

implementation

uses
    SysUtils,
    nc_cache_policy,
    nc_runtime_paths,
    nc_engine_service,
    nc_ipc_protocol,
    nc_ipc_dispatcher;

const
    c_ok = 0;
    c_err_state = -1;
    c_err_arg = -2;
    c_err_open = -3;
    c_err_frame = -4;
    c_err_exception = -5;

var
    g_service: TncEngineService = nil;
    g_dispatcher: TncIpcDispatcher = nil;
    g_last_error: UTF8String = '';

procedure set_error(const text: string);
begin
    g_last_error := UTF8Encode(text);
end;

function from_c(const value: PAnsiChar): string;
begin
    if value = nil then
        Exit('');
    Result := UTF8Decode(UTF8String(value));
end;

function cassotis_core_open(dictionary_path, user_dictionary_path,
    resource_dir, data_dir: PAnsiChar): LongInt; cdecl;
var
    dictionary: string;
begin
    try
        if g_service <> nil then
        begin
            set_error('engine is already open');
            Exit(c_err_state);
        end;
        dictionary := from_c(dictionary_path);
        if dictionary = '' then
        begin
            set_error('dictionary path is required');
            Exit(c_err_arg);
        end;
        nc_set_host_paths(from_c(resource_dir), from_c(data_dir));
        g_service := TncEngineService.Create(dictionary, '',
            from_c(user_dictionary_path));
        if not g_service.DictionaryReady then
        begin
            set_error('dictionary open failed: ' + g_service.DictionaryError);
            FreeAndNil(g_service);
            Exit(c_err_open);
        end;
        g_dispatcher := TncIpcDispatcher.Create(g_service);
        Result := c_ok;
    except
        on E: Exception do
        begin
            set_error(E.ClassName + ': ' + E.Message);
            FreeAndNil(g_dispatcher);
            FreeAndNil(g_service);
            Result := c_err_exception;
        end;
    end;
end;

function cassotis_core_dispatch(request: PByte; request_length: Cardinal;
    response: PByte; response_capacity: Cardinal): LongInt; cdecl;
var
    frame, reply: TBytes;
    envelope, answer: TncIpcEnvelope;
    consumed: SizeInt;
    decode_error: string;
begin
    try
        if g_dispatcher = nil then
            Exit(c_err_state);
        if (request = nil) or (request_length = 0) or
            (request_length > c_ipc_header_size + c_ipc_max_payload_size) then
            Exit(c_err_arg);
        SetLength(frame, request_length);
        Move(request^, frame[0], request_length);
        if not nc_try_decode_ipc_frame(frame, envelope, consumed, decode_error) then
        begin
            set_error(decode_error);
            Exit(c_err_frame);
        end;
        g_dispatcher.DispatchRequest(envelope, answer);
        reply := nc_encode_ipc_frame(answer);
        Result := Length(reply);
        if (response <> nil) and (Cardinal(Result) <= response_capacity) then
            Move(reply[0], response^, Result);
    except
        on E: Exception do
        begin
            set_error(E.ClassName + ': ' + E.Message);
            Result := c_err_exception;
        end;
    end;
end;

function cassotis_core_last_error(buffer: PAnsiChar; capacity: Cardinal): Cardinal; cdecl;
var
    count: Cardinal;
begin
    Result := Length(g_last_error);
    if (buffer = nil) or (capacity = 0) then
        Exit;
    count := Result;
    if count >= capacity then
        count := capacity - 1;
    if count > 0 then
        Move(g_last_error[1], buffer^, count);
    buffer[count] := #0;
end;

procedure cassotis_core_trim(level: LongInt); cdecl;
begin
    try
        if g_service <> nil then
            g_service.TrimMemory(level);
    except
        on E: Exception do
            set_error(E.ClassName + ': ' + E.Message);
    end;
end;

function cassotis_core_set_option(name: PAnsiChar; value: LongInt): LongInt; cdecl;
var
    key: AnsiString;
begin
    Result := c_ok;
    key := AnsiString(name);
    if key = 'cache_percent' then
        g_cache_percent := value
    else if key = 'sqlite_cache_kib' then
        g_sqlite_cache_kib := value
    else if key = 'sqlite_mmap_mib' then
        g_sqlite_mmap_mib := value
    else if key = 'query_path_on_demand' then
        g_query_path_on_demand := value <> 0
    else if key = 'deterministic_search' then
        g_deterministic_search := value <> 0
    else if key = 'compact_queues' then
        g_compact_queues := value <> 0
    else if key = 'prewarm_short_lookups' then
        g_prewarm_short_lookups := value <> 0
    else
        Result := c_err_arg;
end;

var
    g_census: UTF8String = '';

procedure census_line(const name: string; const count: Integer);
begin
    g_census := g_census + UTF8Encode(name) + '=' + UTF8String(IntToStr(count)) + #10;
end;

function cassotis_core_cache_census(buffer: PAnsiChar; capacity: Cardinal): Cardinal; cdecl;
var
    count: Cardinal;
begin
    Result := 0;
    try
        g_census := '';
        if g_service <> nil then
            g_service.CacheCensus(census_line);
        Result := Length(g_census);
        if (buffer <> nil) and (capacity > 0) then
        begin
            count := Result;
            if count >= capacity then
                count := capacity - 1;
            if count > 0 then
                Move(g_census[1], buffer^, count);
            buffer[count] := #0;
        end;
    except
        on E: Exception do
            set_error(E.ClassName + ': ' + E.Message);
    end;
end;

procedure cassotis_core_close; cdecl;
begin
    try
        FreeAndNil(g_dispatcher);
        FreeAndNil(g_service);
    except
        on E: Exception do
            set_error(E.ClassName + ': ' + E.Message);
    end;
end;

end.
