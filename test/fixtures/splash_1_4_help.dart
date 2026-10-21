// Captured from GhostSplash 5b4096b server --help on 2026-10-21.
const splash14Help =
    r'''usage: -c [-h] --model OWNER/REPO [--chat-template FILE] [--port PORT]
          [--binary BINARY] [--host ADDRESS] [--allowed-host HOST]
          [--allowed-origin ORIGIN] [--api-key KEY] [--no-webui]
          [--max-memory SIZE] [--experimental-quantized-ffn {on,off}]
          [--max-context TOKENS] [--ple-memory SIZE] [--expert-memory SIZE]
          [--sparse-kv-memory SIZE]
          [--kv-format {int8,bf16,q4h,q4_0,q4_0_unrotated}]
          [--state-format {fp32,bf16}] [--idle-release DURATION]
          [--max-cache-disk SIZE] [--max-cache-disk-writes SIZE]
          [--persistent-cache] [--cache-dir DIRECTORY]
          [--served-model-name NAME] [--announce-served-name]
          [--default-reasoning-effort EFFORT] [--thinking-token-budget N]
          [--thinking-end-text TEXT] [--max-request-size SIZE]
          [--max-image-pixels PIXELS] [--request-timeout DURATION]
          [--queue-size REQUESTS] [--decode-share SHARE] [--disable-ane]
          [--ane-ffn-share auto|SHARE] [--ane-ffn-minimum-rows ROWS]
          [--ane-power-recovery {on,off}]
          [--ane-power-reference off|auto|WATTS]
          [--ane-recovery-idle-watts WATTS]
          [--ane-recovery-max-power-percent PERCENT]
          [--prompt-lookup {on,off}] [--prompt-lookup-min-match {2,3,4}]
          [--compact-draft-head {on,off}] [--compact-draft-capacity ROWS]
          [--compact-draft-ranking FILE] [--encoder-submit-batch-size {1,2,4}]
          [--encoder-option-queries {on,off}] [--fast-topk {on,off}]
          [--verify-rows {auto,all}] [--allow-idle-sleep]
          MODEL_DIRECTORY

positional arguments:
  MODEL_DIRECTORY       the directory of a model Splash prepared, or a
                        selection link to one: the server holds and serves the
                        directory it names at startup

options:
  -h, --help            show this help message and exit
  --model OWNER/REPO
  --chat-template FILE  override the chat template in memory; tokenizer files
                        still come from the held model
  --port PORT
  --binary BINARY

network and access:
  --host ADDRESS        HTTP bind address (default: 127.0.0.1; 0.0.0.0 for all
                        IPv4 interfaces); clients use an IP address, localhost
                        or a name given with --allowed-host
  --allowed-host HOST   additional HTTP Host name to accept, e.g. mymac.local;
                        does not change the bind address (repeatable)
  --allowed-origin ORIGIN
                        origin whose pages may call the API from a browser or
                        webview, e.g. tauri://localhost; '*' for any
                        (repeatable)
  --api-key KEY         require this key as a bearer token or x-api-key on
                        every route but the chat page, /health and /ready
                        (default: SPLASH_API_KEY)
  --no-webui            disable the chat page

memory and context:
  --max-memory SIZE     Metal memory budget, e.g. 28G; it can only lower the
                        automatic budget (default: auto)
  --experimental-quantized-ffn {on,off}
                        experimental Qwen3.5-4B generation only: retain
                        quantized FFN weights without a resident full FP16 FFN
                        cache (default: off)
  --max-context TOKENS  context token limit, e.g. 100K or 1M (K = 1024 tokens,
                        M = 1000000 tokens), up to 1010000; past the model's
                        256K native window it turns on YaRN, which is static
                        and changes answers at every length, so pass more than
                        256K only when a request needs it (default: auto, the
                        native window when memory holds it)
  --ple-memory SIZE     RAM row cache of the PLE n-gram table of a
                        Qwen3.8-Flash-Next GGUF, e.g. 2G, which streams the
                        rest from the SSD; off loads the whole table, tens of
                        GB (default: auto, which streams it where memory
                        cannot hold it)
  --expert-memory SIZE  RAM slots of the routed experts of a MoE model, e.g.
                        16G, which reads the others from the SSD when a token
                        routes them; off loads every expert (default: auto,
                        which loads them all where memory holds them and
                        otherwise gives them what the context leaves)
  --sparse-kv-memory SIZE
                        RAM cache of the KV blocks a block-sparse model such
                        as Qwen3.8-Flash-Next reads of requests whose KV is on
                        the SSD, e.g. 1200M; never below its floor (default:
                        auto, its floor)
  --kv-format {int8,bf16,q4h,q4_0,q4_0_unrotated}
                        target KV cache storage (default: int8); q4_0 uses
                        fixed rotation, q4_0_unrotated is its validation
                        control, q4h is experimental
  --state-format {fp32,bf16}
                        recurrent state storage (default: fp32); bf16 halves
                        each state, so memory and the SSD cache hold about
                        twice as many
  --idle-release DURATION
                        time without a request before the engine unwires its
                        memory and frees the weights: seconds, or with an s, m
                        or h suffix, e.g. 30m (default: 10m); off keeps both,
                        though POST /v1/memory/release still frees the weights

SSD cache:
  --max-cache-disk SIZE
                        SSD quota for cached KV pages and states: auto follows
                        the volume, a quarter of its free space beyond a floor
                        of 10G (5% of a volume under 200G), at most 32G; a
                        size such as 16G is held as given while the volume
                        keeps that floor; 0 disables (default: auto)
  --max-cache-disk-writes SIZE
                        the most the SSD cache writes a day, e.g. 200G; the
                        state a conversation resumes from and KV pages pass it
                        (default: 0, no limit)
  --persistent-cache    keep the SSD cache across restarts
  --cache-dir DIRECTORY
                        where --persistent-cache keeps its files; needs
                        --persistent-cache (default:
                        ~/Library/Caches/Splash/prefix-cache)

API:
  --served-model-name NAME
                        additional API model name (repeatable); responses
                        report the loaded model ID unless --announce-served-
                        name
  --announce-served-name
                        report the first --served-model-name in API responses
                        and list it first in /v1/models; /status keeps the
                        loaded model ID (needs --served-model-name)
  --default-reasoning-effort EFFORT
                        effort of Chat and Responses requests that set none:
                        none, minimal, low, medium, high, xhigh or max
                        (default: SPLASH_DEFAULT_REASONING_EFFORT, else the
                        model template's)
  --thinking-token-budget N
                        thinking tokens of a thinking request that sets no
                        thinking_token_budget, after which its thinking closes
                        (default: SPLASH_THINKING_TOKEN_BUDGET, else no cap)
  --thinking-end-text TEXT
                        text that ends thinking where a thinking budget runs
                        out, such as a sentence that turns to the answer, then
                        </think> as its last token; at most 64 tokens
                        (default: SPLASH_THINKING_END_TEXT, else </think>
                        alone)

requests:
  --max-request-size SIZE
                        maximum HTTP request body size, e.g. 128M (default:
                        128M); shared input budget is max(512M, twice this
                        limit)
  --max-image-pixels PIXELS
                        maximum resized pixels per image, 65536–4194304
                        (default: 4194304); bounds the vision scratch one
                        image needs
  --request-timeout DURATION
                        time before a queued or in-flight request expires with
                        504: seconds, or with an s, m or h suffix, e.g. 30m
                        (default: none)
  --queue-size REQUESTS
                        requests admitted at once, running or waiting; more
                        get 503 (default: 32)
  --decode-share SHARE  decode time owed per unit of prefill time while other
                        requests decode (default: 0.5; 0 alternates one
                        command each)
  --disable-ane         prefill on the GPU alone (default: a dense model's
                        long prompts also use the Neural Engine when that is
                        faster)
  --ane-ffn-share auto|SHARE
                        ANE channel share: auto calibrates, 0 disables,
                        otherwise 0..1
  --ane-ffn-minimum-rows ROWS
                        minimum prefill rows for a fixed ANE share (default:
                        512)
  --ane-power-recovery {on,off}
                        retry after a performance backoff when ANE power is
                        quiet (default: off)
  --ane-power-reference off|auto|WATTS
                        ANE power reference: off, startup measurement or
                        positive watts (default: off)
  --ane-recovery-idle-watts WATTS
                        absolute ANE recovery power threshold (default: 0.05
                        W)
  --ane-recovery-max-power-percent PERCENT
                        recovery threshold relative to the power reference,
                        0..100; overrides watts
  --prompt-lookup {on,off}
                        reuse matching prompt continuations (default: off)
  --prompt-lookup-min-match {2,3,4}
                        minimum lookup match length (default: 2)
  --compact-draft-head {on,off}
                        enable validated compact draft head with --compact-
                        draft-ranking FILE (default: off)
  --compact-draft-capacity ROWS
                        compact vocabulary capacity (default: 98304)
  --compact-draft-ranking FILE
                        explicit public draft ranking file; does not enable
                        compact by itself
  --encoder-submit-batch-size {1,2,4}
                        maximum short encoder requests per Metal submission
                        (default: 4)
  --encoder-option-queries {on,off}
                        ModernBERT final-head option query selection (default:
                        on)
  --fast-topk {on,off}  use optional fast top-k sampling (default: off)
  --verify-rows {auto,all}
                        rows of each draft block decode verifies: all verifies
                        every row, so a MoE model's greedy and seeded outputs
                        repeat as a dense model's do (default: auto, where a
                        verify budget learned from earlier cycles chooses a
                        MoE model's rows, which is faster but lets those
                        outputs differ from run to run)
  --allow-idle-sleep    let the Mac sleep automatically while requests run
                        (default: it stays awake until they finish; the
                        display may still sleep)
''';
