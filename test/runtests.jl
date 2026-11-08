using Test
using JSON
using ClaudeCodeStatusLine
using ClaudeCodeStatusLine: humanize, format_duration, progress_bar, pct_color,
    status_line, Payload, GREEN, YELLOW, RED

const CCSL = ClaudeCodeStatusLine

strip_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")

@testset "ClaudeCodeStatusLine" begin
    @testset "humanize" begin
        @test humanize(0) == "0"
        @test humanize(999) == "999"
        @test humanize(1_000) == "1.0k"
        @test humanize(12_345) == "12.3k"
        @test humanize(1_200_000) == "1.2M"
    end

    @testset "format_duration" begin
        @test format_duration(5_000) == "5s"
        @test format_duration(65_000) == "1m5s"
        @test format_duration(3_600_000 + 120_000) == "1h2m"
    end

    @testset "progress_bar" begin
        @test progress_bar(0.0) == "░"^10
        @test progress_bar(0.5) == "█"^5 * "░"^5
        @test progress_bar(1.0) == "█"^10
        @test progress_bar(2.0) == "█"^10   # clamp
        @test progress_bar(-1.0) == "░"^10  # clamp
    end

    @testset "pct_color" begin
        @test pct_color(0) == GREEN
        @test pct_color(49) == GREEN
        @test pct_color(50) == YELLOW
        @test pct_color(79) == YELLOW
        @test pct_color(80) == RED
    end

    @testset "render" begin
        info = StatusInfo(;
            model="Opus 5.5", dir="proj",
            context_tokens=100_000, context_window=200_000,
            output_tokens=1_234, cost_usd=0.504, duration_ms=65_000,
            lines_added=10, lines_removed=2,
        )
        plain = render(info; color=false)
        @test !occursin('\e', plain)
        @test occursin("🤖 Opus 5.5", plain)
        @test occursin("📁 proj", plain)
        @test occursin("100.0k/200.0k (50%)", plain)
        @test occursin("1.2k out", plain)
        @test occursin("\$0.5", plain)
        @test occursin("1m5s", plain)
        @test occursin("+10 -2", plain)

        colored = render(info)
        @test occursin('\e', colored)
        @test strip_ansi(colored) == plain

        minimal = render(StatusInfo(); color=false)
        @test minimal == "🤖 ?"
    end

    @testset "status_line" begin
        sample = """{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
        "workspace":{"current_dir":"/tmp/proj/"},
        "context_window":{"context_window_size":200000,"total_output_tokens":1234,
          "current_usage":{"input_tokens":10,"cache_read_input_tokens":5000,"cache_creation_input_tokens":200}},
        "cost":{"total_cost_usd":0.5,"total_duration_ms":65000,"total_lines_added":10,"total_lines_removed":2}}"""
        out = strip_ansi(status_line(sample))
        @test occursin("Opus 5.5", out)
        @test occursin("📁 proj", out)
        @test occursin("5.2k/200.0k (3%)", out)
        @test occursin("+10 -2", out)

        @test strip_ansi(status_line("{}")) == "🤖 ?"
        @test startswith(status_line("not json"), "statusline error:")
    end

    @testset "StatusInfo(Payload)" begin
        # display_name がなければ id、workspace がなければ cwd
        p = JSON.parse("""{"model":{"id":"claude-x"},"cwd":"/a/b"}""", Payload)
        info = StatusInfo(p)
        @test info.model == "claude-x"
        @test info.dir == "b"
        @test info.context_tokens === nothing

        # [1m] モデルは 1M コンテキスト
        p = JSON.parse("""{"model":{"id":"claude-opus-5-5[1m]"}}""", Payload)
        @test StatusInfo(p).context_window == 1_000_000

        # context_window_size 指定が優先される
        p = JSON.parse("""{"model":{"id":"x[1m]"},"context_window":{"context_window_size":123456}}""", Payload)
        @test StatusInfo(p).context_window == 123456
    end

    @testset "transcript_usage" begin
        mktempdir() do dir
            path = joinpath(dir, "t.jsonl")
            @test transcript_usage(path) === nothing  # ファイルなし

            open(path, "w") do io
                println(io, """{"message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":7}}}""")
                println(io, "garbage \"usage\" not json")
                println(io, """{"isSidechain":true,"message":{"usage":{"input_tokens":99999,"output_tokens":99999}}}""")
                println(io, """{"message":{"usage":{"input_tokens":20,"cache_read_input_tokens":200,"output_tokens":3}}}""")
                println(io, """{"type":"user","message":{}}""")
            end
            u = transcript_usage(path)
            @test u.context_tokens == 220     # 最後のメインスレッド usage
            @test u.output_tokens == 10       # 7 + 3 (sidechain は除外)

            # payload 経由で transcript にフォールバック
            p = JSON.parse("""{"transcript_path":"$(escape_string(path))"}""", Payload)
            info = StatusInfo(p)
            @test info.context_tokens == 220
            @test info.output_tokens == 10

            empty_path = joinpath(dir, "empty.jsonl")
            write(empty_path, "")
            @test transcript_usage(empty_path) === nothing
        end
    end

    @testset "main" begin
        out = IOBuffer()
        main(IOBuffer("""{"model":{"display_name":"M"}}"""), out)
        @test strip_ansi(String(take!(out))) == "🤖 M\n"
    end
end
