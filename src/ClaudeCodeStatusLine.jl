module ClaudeCodeStatusLine

using JSON
using PrecompileTools

export main, render, StatusInfo, transcript_usage

const DEFAULT_CONTEXT_WINDOW = 200_000

# ANSI カラー
const RESET = "\e[0m"
const DIM = "\e[2m"
const CYAN = "\e[36m"
const BLUE = "\e[34m"
const GREEN = "\e[32m"
const YELLOW = "\e[33m"
const RED = "\e[31m"
const MAGENTA = "\e[35m"

"""
    StatusInfo

ステータスラインに表示する情報。
"""
Base.@kwdef struct StatusInfo
    model::String = "?"
    dir::String = ""
    context_tokens::Union{Int,Nothing} = nothing
    context_window::Int = DEFAULT_CONTEXT_WINDOW
    output_tokens::Union{Int,Nothing} = nothing
    cost_usd::Union{Float64,Nothing} = nothing
    duration_ms::Union{Int,Nothing} = nothing
    lines_added::Union{Int,Nothing} = nothing
    lines_removed::Union{Int,Nothing} = nothing
end

# --- 入力 JSON の型 (trim 可能にするため、Dict ではなく具体的な struct で受ける) ---
const Opt{T} = Union{T,Nothing}

struct ModelPayload
    id::Opt{String}
    display_name::Opt{String}
end

struct WorkspacePayload
    current_dir::Opt{String}
end

struct UsagePayload
    input_tokens::Opt{Int}
    cache_read_input_tokens::Opt{Int}
    cache_creation_input_tokens::Opt{Int}
    output_tokens::Opt{Int}
end

struct ContextWindowPayload
    context_window_size::Opt{Int}
    total_output_tokens::Opt{Int}
    current_usage::Opt{UsagePayload}
end

struct CostPayload
    total_cost_usd::Opt{Float64}
    total_duration_ms::Opt{Int}
    total_lines_added::Opt{Int}
    total_lines_removed::Opt{Int}
end

struct Payload
    model::Opt{ModelPayload}
    workspace::Opt{WorkspacePayload}
    cwd::Opt{String}
    transcript_path::Opt{String}
    context_window::Opt{ContextWindowPayload}
    cost::Opt{CostPayload}
end

# transcript (JSONL) の 1 行
struct MessagePayload
    usage::Opt{UsagePayload}
end

struct TranscriptEntry
    isSidechain::Opt{Bool}
    message::Opt{MessagePayload}
end

input_total(u::UsagePayload) =
    something(u.input_tokens, 0) +
    something(u.cache_read_input_tokens, 0) +
    something(u.cache_creation_input_tokens, 0)

"""
    transcript_usage(path) -> Union{NamedTuple,Nothing}

transcript (JSONL) を読み、メインスレッドの最後の assistant メッセージの
`usage` から現在のコンテキスト使用量を返す。
戻り値は `(context_tokens, output_tokens)`。
"""
function transcript_usage(path::String)
    isfile(path) || return nothing
    total_output = 0
    last_ctx = -1
    for line in eachline(path)
        occursin("\"usage\"", line) || continue
        entry = try
            JSON.parse(line, TranscriptEntry)
        catch
            continue
        end
        entry.isSidechain === true && continue
        msg = entry.message
        msg === nothing && continue
        usage = msg.usage
        usage === nothing && continue
        last_ctx = input_total(usage)
        total_output += something(usage.output_tokens, 0)
    end
    last_ctx < 0 && return nothing
    return (context_tokens=last_ctx, output_tokens=total_output)
end

function context_window_size(p::Payload)
    cw = p.context_window
    if cw !== nothing
        sz = cw.context_window_size
        sz !== nothing && sz > 0 && return sz
    end
    m = p.model
    if m !== nothing
        id = m.id
        id !== nothing && occursin("[1m]", id) && return 1_000_000
    end
    return DEFAULT_CONTEXT_WINDOW
end

"""
    StatusInfo(p::Payload)

Claude Code から stdin で渡される JSON (パース済み) から `StatusInfo` を作る。
"""
function StatusInfo(p::Payload)
    model = "?"
    m = p.model
    if m !== nothing
        dn = m.display_name
        model = dn !== nothing ? dn : something(m.id, "?")
    end
    ws = p.workspace
    wdir = ws === nothing ? nothing : ws.current_dir
    cwd = wdir !== nothing ? wdir : something(p.cwd, "")

    ctx = nothing
    out = nothing
    cw = p.context_window
    # 新しめの Claude Code は context_window.current_usage を渡してくる
    if cw !== nothing && cw.current_usage !== nothing
        ctx = input_total(cw.current_usage)
        out = cw.total_output_tokens
    end
    # なければ transcript から計算
    if ctx === nothing
        tp = p.transcript_path
        if tp !== nothing
            u = transcript_usage(tp)
            if u !== nothing
                ctx = u.context_tokens
                out = u.output_tokens
            end
        end
    end

    cost = p.cost
    return StatusInfo(;
        model=model,
        dir=basename(rstrip(cwd, '/')),
        context_tokens=ctx,
        context_window=context_window_size(p),
        output_tokens=out,
        cost_usd=cost === nothing ? nothing : cost.total_cost_usd,
        duration_ms=cost === nothing ? nothing : cost.total_duration_ms,
        lines_added=cost === nothing ? nothing : cost.total_lines_added,
        lines_removed=cost === nothing ? nothing : cost.total_lines_removed,
    )
end

"""
    humanize(n) -> String

`12345 -> "12.3k"`, `1_200_000 -> "1.2M"`
"""
function humanize(n::Integer)
    n < 1_000 && return string(n)
    n < 1_000_000 && return string(round(n / 1_000; digits=1), "k")
    return string(round(n / 1_000_000; digits=1), "M")
end

function format_duration(ms::Integer)
    s = ms ÷ 1000
    h, s = divrem(s, 3600)
    m, s = divrem(s, 60)
    h > 0 && return "$(h)h$(m)m"
    m > 0 && return "$(m)m$(s)s"
    return "$(s)s"
end

function progress_bar(ratio::Real; width::Int=10)
    filled = clamp(round(Int, ratio * width), 0, width)
    io = IOBuffer()
    for i in 1:width
        print(io, i <= filled ? '█' : '░')
    end
    return String(take!(io))
end

pct_color(p) = p < 50 ? GREEN : p < 80 ? YELLOW : RED

"""
    render(info::StatusInfo; color=true) -> String

ステータスラインの文字列を作る。
"""
function render(info::StatusInfo; color::Bool=true)
    c(code, s) = color ? string(code, s, RESET) : string(s)
    sep = c(DIM, " │ ")
    parts = String[]

    push!(parts, c(CYAN, "🤖 " * info.model))
    isempty(info.dir) || push!(parts, c(BLUE, "📁 " * info.dir))

    if info.context_tokens !== nothing
        ratio = info.context_tokens / info.context_window
        pct = round(Int, 100ratio)
        push!(parts, c(pct_color(pct),
            "🧠 $(progress_bar(ratio)) $(humanize(info.context_tokens))/$(humanize(info.context_window)) ($(pct)%)"))
    end
    if info.output_tokens !== nothing
        push!(parts, c(MAGENTA, "✍️ $(humanize(info.output_tokens)) out"))
    end
    if info.cost_usd !== nothing
        push!(parts, c(YELLOW, "💰 \$" * string(round(info.cost_usd; digits=2))))
    end
    if info.duration_ms !== nothing
        push!(parts, c(DIM, "⏱ " * format_duration(info.duration_ms)))
    end
    if info.lines_added !== nothing || info.lines_removed !== nothing
        a = something(info.lines_added, 0)
        r = something(info.lines_removed, 0)
        push!(parts, c(GREEN, "+$a") * c(RED, " -$r"))
    end
    return join(parts, sep)
end

"""
    main(io_in=stdin, io_out=stdout)

stdin から Claude Code のステータス JSON を読み、1 行のステータスラインを出力する。
"""
function status_line(raw::String)::String
    try
        return render(StatusInfo(JSON.parse(raw, Payload)))
    catch err
        return "statusline error: " * string(typeof(err))
    end
end

function main(io_in::IO=stdin, io_out::IO=stdout)
    println(io_out, status_line(read(io_in, String)))
    return nothing
end

function (@main)(args::Vector{String})::Cint
    raw = read("/dev/stdin", String)
    println(Core.stdout, status_line(raw))
    return 0
end

@setup_workload begin
    sample = """{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
    "workspace":{"current_dir":"/tmp/proj"},
    "context_window":{"context_window_size":200000,"total_output_tokens":1234,
      "current_usage":{"input_tokens":10,"cache_read_input_tokens":5000,"cache_creation_input_tokens":200}},
    "cost":{"total_cost_usd":0.5,"total_duration_ms":65000,"total_lines_added":10,"total_lines_removed":2}}"""
    @compile_workload begin
        main(IOBuffer(sample), IOBuffer())
        render(StatusInfo(JSON.parse(sample, Payload)); color=false)
        main(IOBuffer("{}"), IOBuffer())
    end
end

end # module ClaudeCodeStatusLine
