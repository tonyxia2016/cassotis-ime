unit nc_cache_policy;

{ Memory policy of an embedded host. The desktop engine sizes its caches for a
  process with no memory limit; a keyboard extension is killed near 77 MB. Every
  bounded cache asks here for its bound, so one number moves them together and a
  host can sweep it without a rebuild. All of them are memo tables: a smaller
  bound must cost time, never change a candidate (bench/replay's digest checks). }

{$mode delphiunicode}
{$codepage utf8}

interface

uses
    Generics.Collections;

type
    TncCensusSink = procedure(const name: string; const count: Integer);

var
    // Percent of the desktop bounds. 100 keeps the macOS behaviour.
    g_cache_percent: Integer = 100;
    // PRAGMA cache_size in KiB for the base dictionary (macOS: 8192).
    g_sqlite_cache_kib: Integer = 8192;
    // PRAGMA mmap_size in MiB for the base dictionary (macOS: 128).
    g_sqlite_mmap_mib: Integer = 128;
    // Keep dict_base_query_path out of the heap: ask SQLite per query instead.
    g_query_path_on_demand: Boolean = False;
    // Read every single-character weight at open (2 MB) instead of on first use.
    g_prewarm_short_lookups: Boolean = True;
    // Ignore the engine's wall-clock budgets, so that two runs differ only by their
    // settings and not by how busy the machine was. For measurements only.
    g_deterministic_search: Boolean = False;
    // Off reproduces FPC's growing TQueue, to prove the fix changes nothing else.
    g_compact_queues: Boolean = True;
    // The shared character LM and the repair that uses it (<resources>/char_lm).
    // Off keeps the engine without models, as before they ran on Core ML.
    g_char_lm_enabled: Boolean = True;
    // The LM work whose results a frontend polls for (Tab continuation, one-key
    // rerank): queued after every key, run on worker threads. A host that does
    // not poll leaves it off, or it only takes the Neural Engine from the keys.
    g_char_lm_async: Boolean = False;
    // Keys run without the character LM and return at once, marked pending;
    // the frontend's next poll (request 17) reruns the candidates with it.
    // Only for a host that polls, or keys never get the model's ranking.
    g_char_lm_deferred: Boolean = False;

function nc_cache_limit(const desktop_limit: Integer): Integer;

// FPC 3.2.2's TQueue.Dequeue only moves a low mark: unless the queue empties, the
// slots below it are never reused and the array grows without bound, 8 bytes per
// Enqueue and by half each step. A cache evicting first-in-first-out never empties.
function nc_dequeue(const queue: TQueue<string>): string;

implementation

function nc_cache_limit(const desktop_limit: Integer): Integer;
begin
    Result := (Int64(desktop_limit) * g_cache_percent) div 100;
    if Result < 64 then
        Result := 64;
end;

function nc_dequeue(const queue: TQueue<string>): string;
begin
    Result := queue.Dequeue;
    if g_compact_queues and (queue.Capacity > 2 * queue.Count + 1024) then
        queue.TrimExcess;
end;

end.
