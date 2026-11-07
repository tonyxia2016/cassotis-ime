unit nc_lm_runtime;

{ Which nc_lm_* runtime opens a character LM folder, with the checks of the
  assets it reads. Two runtimes export the same C functions over the same
  algorithms (native/nc_char_lm_ort.inc):

  - libcassotis_ort.dylib runs char_lm.onnx with ONNX Runtime on the CPU;
  - the Core ML runtime (native/nc_char_lm_coreml.mm) runs char_lm.mlmodelc,
    made from char_lm.onnx by scripts/char_lm_coreml.py, on the Neural Engine:
    libcassotis_coreml.dylib in the macOS bundle, linked into the embedding
    host on iOS (CASSOTIS_EMBEDDED), where nothing is loaded by path.

  A folder that holds char_lm.mlmodelc opens with Core ML where that runtime is
  present; if Core ML cannot open it (before macOS 15, say), the desktop build
  opens char_lm.onnx with ONNX Runtime as before.

  The manifest stays the one the ONNX export writes. ONNX Runtime checks the
  graph against its hash; Core ML checks the hash the converter recorded in the
  compiled model (metadata.json, cassotis_source_sha256) against the same
  entry, so a compiled model only opens with the vocabulary it was made with,
  without hashing its 170 MB of weights at every start. }

{$codepage utf8}
{$mode delphiunicode}
{$H+}

interface

uses SysUtils, Dynlibs, fpjson;

{ Opens the model of folder. Checks data_files and the model against the
  manifest's files, loads the runtime and calls nc_lm_create. Returns the
  handle; module is the library that holds the functions (0 where they are
  linked in) and runtime names it ("coreml" or "onnxruntime"). Raises
  EInvalidOp with the reason when no runtime opens it. }
function nc_lm_open_model(const folder: string; const files: TJSONObject;
    const data_files: array of string; const threads: Integer;
    out module: TLibHandle; out runtime: string): Pointer;

{ The address of one nc_lm_* function of the runtime nc_lm_open_model chose. }
function nc_lm_symbol(const module: TLibHandle; const name: string): Pointer;

implementation

uses jsonparser, nc_io_compat, nc_runtime_paths, nc_sha256;

type
    TCreateModel = function(directory: PAnsiChar; intra_threads: Integer;
        error_text: PAnsiChar; capacity: Integer): Pointer; cdecl;

const
    c_coreml_model = 'char_lm.mlmodelc';
    c_onnx_model = 'char_lm.onnx';

{$IFDEF CASSOTIS_EMBEDDED}
{ Linked into the host from nc_char_lm_coreml.mm. Only their addresses are
  taken here; the hosts call them through their own exact signatures. }
procedure nc_lm_create; cdecl; external;
procedure nc_lm_destroy; cdecl; external;
procedure nc_lm_score; cdecl; external;
procedure nc_lm_score_next; cdecl; external;
procedure nc_lm_score_next_query; cdecl; external;
procedure nc_lm_continue; cdecl; external;
procedure nc_lm_correct; cdecl; external;
procedure nc_lm_correct_with; cdecl; external;
{$ENDIF}

function nc_lm_symbol(const module: TLibHandle; const name: string): Pointer;
begin
    {$IFDEF CASSOTIS_EMBEDDED}
    if name = 'nc_lm_create' then Exit(@nc_lm_create);
    if name = 'nc_lm_destroy' then Exit(@nc_lm_destroy);
    if name = 'nc_lm_score' then Exit(@nc_lm_score);
    if name = 'nc_lm_score_next' then Exit(@nc_lm_score_next);
    if name = 'nc_lm_score_next_query' then Exit(@nc_lm_score_next_query);
    if name = 'nc_lm_continue' then Exit(@nc_lm_continue);
    if name = 'nc_lm_correct' then Exit(@nc_lm_correct);
    if name = 'nc_lm_correct_with' then Exit(@nc_lm_correct_with);
    Result := nil;
    {$ELSE}
    if module = 0 then Exit(nil);
    Result := GetProcedureAddress(module, AnsiString(name));
    {$ENDIF}
end;

function manifest_hash(const files: TJSONObject; const name: string): string;
var value: TJSONData;
begin
    value := files.Find(UTF8Encode(name));
    if (value = nil) or (value.JSONType <> jtString) then
        raise EInvalidOp.Create('Missing character LM asset hash: ' + name);
    Result := UTF8Decode(value.AsString);
end;

procedure verify_file(const folder: string; const files: TJSONObject; const name: string);
begin
    if not SameText(nc_sha256_file(IncludeTrailingPathDelimiter(folder) + name),
        manifest_hash(files, name)) then
        raise EInvalidOp.Create('Character LM asset hash mismatch: ' + name);
end;

{ The compiled model names the char_lm.onnx it was converted from. }
procedure verify_coreml_source(const folder: string; const files: TJSONObject);
var
    root, value: TJSONData;
    recorded: string;
begin
    root := GetJSON(UTF8Encode(TncFile.ReadAllText(IncludeTrailingPathDelimiter(folder) +
        c_coreml_model + '/metadata.json', TEncoding.UTF8)));
    try
        recorded := '';
        if (root is TJSONArray) and (TJSONArray(root).Count > 0) and
            (TJSONArray(root).Items[0] is TJSONObject) then
        begin
            value := TJSONObject(TJSONArray(root).Items[0]).FindPath(
                'userDefinedMetadata.cassotis_source_sha256');
            if (value <> nil) and (value.JSONType = jtString) then
                recorded := UTF8Decode(value.AsString);
        end;
        if (recorded = '') or not SameText(recorded, manifest_hash(files, c_onnx_model)) then
            raise EInvalidOp.Create('Core ML character LM was not made from the manifest''s model');
    finally
        root.Free;
    end;
end;

function create_with(const create_model: Pointer; const folder: string;
    const threads: Integer): Pointer;
var
    folder_utf8: UTF8String;
    error_text: array[0..1023] of AnsiChar;
begin
    if create_model = nil then
        raise EInvalidOp.Create('Character LM runtime must be rebuilt');
    folder_utf8 := UTF8Encode(folder);
    FillChar(error_text, SizeOf(error_text), 0);
    Result := TCreateModel(create_model)(PAnsiChar(folder_utf8), threads, @error_text[0],
        Length(error_text));
    if Result = nil then
        raise EInvalidOp.Create(UTF8Decode(UTF8String(PAnsiChar(@error_text[0]))));
end;

function nc_lm_open_model(const folder: string; const files: TJSONObject;
    const data_files: array of string; const threads: Integer;
    out module: TLibHandle; out runtime: string): Pointer;
var
    name, coreml_error: string;
    {$IFNDEF CASSOTIS_EMBEDDED}
    library_path: string;
    {$ENDIF}
begin
    Result := nil;
    module := 0;
    runtime := '';
    if files = nil then
        raise EInvalidOp.Create('Incomplete character LM manifest');
    for name in data_files do
        verify_file(folder, files, name);
    coreml_error := '';
    if DirectoryExists(IncludeTrailingPathDelimiter(folder) + c_coreml_model) then
    begin
        try
            verify_coreml_source(folder, files);
            {$IFDEF CASSOTIS_EMBEDDED}
            Result := create_with(nc_lm_symbol(0, 'nc_lm_create'), folder, threads);
            {$ELSE}
            library_path := nc_runtime_library(ExtractFileDir(ParamStr(0)), 'libcassotis_coreml.dylib');
            if not FileExists(library_path) then
                raise EInvalidOp.Create('Core ML runtime not installed');
            module := LoadLibrary(UTF8Encode(library_path));
            if module = 0 then
                raise EInvalidOp.Create('Core ML runtime unavailable: ' + GetLoadErrorStr);
            Result := create_with(nc_lm_symbol(module, 'nc_lm_create'), folder, threads);
            {$ENDIF}
            runtime := 'coreml';
            Exit;
        except
            on E: Exception do
            begin
                coreml_error := E.Message;
                {$IFNDEF CASSOTIS_EMBEDDED}
                if module <> 0 then UnloadLibrary(module);
                module := 0;
                {$ENDIF}
            end;
        end;
    end;
    {$IFDEF CASSOTIS_EMBEDDED}
    if coreml_error = '' then coreml_error := 'missing ' + c_coreml_model;
    raise EInvalidOp.Create(coreml_error);
    {$ELSE}
    try
        verify_file(folder, files, c_onnx_model);
        module := LoadLibrary(UTF8Encode(nc_runtime_library(ExtractFileDir(ParamStr(0)))));
        if module = 0 then
            raise EInvalidOp.Create('Character LM runtime unavailable: ' + GetLoadErrorStr);
        Result := create_with(nc_lm_symbol(module, 'nc_lm_create'), folder, threads);
        runtime := 'onnxruntime';
    except
        on E: Exception do
        begin
            if module <> 0 then UnloadLibrary(module);
            module := 0;
            if coreml_error <> '' then
                raise EInvalidOp.Create(E.Message + ' (Core ML: ' + coreml_error + ')');
            raise;
        end;
    end;
    {$ENDIF}
end;

end.
