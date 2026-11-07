unit nc_runtime_paths;

{$mode delphiunicode}
{$codepage utf8}

interface
{ An embedded host (the iOS keyboard extension) has no useful ParamStr(0) or
  HOME: it hands the engine its read-only resource directory and its writable
  data directory before opening it. Without that, the desktop rules apply. }
procedure nc_set_host_paths(const resource_directory, data_directory: string);
function nc_host_data_directory: string;
function nc_module_directory: string;
function nc_model_directory(const fallback: string): string;
{ The nc_lm_* runtime library: libcassotis_ort.dylib (ONNX Runtime) or
  libcassotis_coreml.dylib (Core ML), from the bundle's Frameworks. }
function nc_runtime_library(const fallback: string;
    const name: string = 'libcassotis_ort.dylib'): string;

implementation
uses SysUtils;

var
    g_resource_directory: string = '';
    g_data_directory: string = '';

procedure nc_set_host_paths(const resource_directory, data_directory: string);
begin
    g_resource_directory := resource_directory;
    g_data_directory := data_directory;
end;

function nc_host_data_directory: string;
begin
    Result := g_data_directory;
end;

function nc_module_directory: string;
begin
    if g_resource_directory <> '' then Exit(g_resource_directory);
    Result := ExtractFileDir(ExpandFileName(ParamStr(0)));
end;

function nc_model_directory(const fallback: string): string;
var bundled: string;
begin
    Result := GetEnvironmentVariable('CASSOTIS_MODEL_DIRECTORY');
    if Result <> '' then Exit;
    bundled := ExpandFileName(IncludeTrailingPathDelimiter(fallback) +
        '../Resources/models');
    if DirectoryExists(bundled) then Result := bundled
    else Result := fallback;
end;

function nc_runtime_library(const fallback: string; const name: string): string;
var executable_directory, bundled: string;
begin
    executable_directory := nc_module_directory;
    bundled := ExpandFileName(IncludeTrailingPathDelimiter(executable_directory) +
        '../Frameworks/' + name);
    if FileExists(bundled) then Exit(bundled);
    Result := IncludeTrailingPathDelimiter(fallback) + name;
end;

end.
