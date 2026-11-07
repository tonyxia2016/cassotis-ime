library cassotis_core;

{ Built with -Cn: the compiler stops before its own linker and the objects go
  into a static archive. A "library" rather than a "program" because that gets
  the tables (INITFINAL, thread variables, resource strings) plus _FPC_LIBMAIN in
  __mod_init_func, so dyld initialises the runtime for us, with signal handlers
  restored, and the Swift host keeps its own main. }

{$codepage utf8}
{$mode delphiunicode}
{$H+}

uses
    {$IFDEF CASSOTIS_CMEM}cmem,{$ENDIF}
    cthreads,
    cwstring,
    nc_core_bridge;

exports
    cassotis_core_open,
    cassotis_core_dispatch,
    cassotis_core_last_error,
    cassotis_core_trim,
    cassotis_core_close,
    cassotis_core_set_option,
    cassotis_core_cache_census,
    cassotis_core_model_state;

begin
end.
