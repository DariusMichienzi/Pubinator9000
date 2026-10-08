#!/usr/bin/env julia
#=
Pubinator: a weighted pub randomiser with a spinning wheel.

Each pub's weight is

    w = p * (1 - 1/x)^y

  p = popularity: number of form submissions naming that pub (all responses)
  x = draws since the pub was last chosen (1 = chosen last draw)
  y = total number of times the pub has been chosen

Pubs never chosen have y = 0, so w = p. A pub chosen last draw (x = 1) gets
w = 0 and can't come up twice in a row. Pubs with no submissions (p = 0)
are never picked.

x is counted in draws, not calendar time: each saved pick in the history file
is one draw. Dates are recorded for reference only, so skipping weeks or
drawing twice in one week both work as expected.

How a draw works:
  1. The terminal shows the odds table only. The result is never printed.
  2. Your browser opens the wheel (served by this script on 127.0.0.1).
     Wedges are sized by probability.
  3. Spin. The result and who suggested it are revealed on the page.
  4. Veto removes that pub from the wheel and spins again (odds of the
     remaining pubs are rescaled). Veto as often as you like.
  5. "Lock it in" saves the final pub to the history and the script exits.
     Closing the page or pressing Ctrl+C saves nothing.

The veto order is drawn up front in Julia (weighted draws without
replacement), so --seed reproduces everything and refreshing the page
doesn't re-roll.

Usage:
    julia pubinator.jl responses.csv [options]

Options:
    --pubs FILE          Pub list, one per line (default: pubs.txt, looked for
                         in the current folder, then next to the responses
                         CSV, then next to this script). Submissions
                         not on the list are reported and ignored. Use
                         --pubs none to accept any pub named in the form.
    --history FILE       Past picks, one per line as "date,pub" (default:
                         history.csv, looked for like pubs.txt; created in the
                         current folder if not found). Hand edits are fine:
                         header optional, date optional, , ; or tab.
    --column NAME        Form question holding the pub (default: first column
                         whose header contains "pub", otherwise the last column).
    --name-column NAME   Form question holding the person's name (default:
                         first header containing "name", else "email").
    --addition-column NAME
                         Form question for suggested additions to the pub list
                         (default: header containing "addition", else the
                         second-to-last column). A suggestion made by two or
                         more different people joins the draw, with popularity
                         = number of people who suggested it.
    --port N             Port for the wheel page (default: first free from 8765).
    --no-open            Don't open the browser; just print the address.
    --dry-run            Spin and veto as normal, but don't save to history.
    --odds               Show the odds table only; no wheel.
    --seed N             Fix the random seed (reproducible draws).

Only Julia's standard library is used; no packages needed.
=#

using Dates, Random, Printf, Sockets

# ---------- CSV helpers (handles quoted fields, e.g. "The Crown, Clifton") ----------

function parse_csv_line(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    inquotes = false
    chars = collect(line)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if inquotes
            if c == '"'
                if i < length(chars) && chars[i+1] == '"'
                    write(buf, '"'); i += 1          # escaped quote ""
                else
                    inquotes = false
                end
            else
                write(buf, c)
            end
        else
            if c == '"'
                inquotes = true
            elseif c == ','
                push!(fields, String(take!(buf)))
            else
                write(buf, c)
            end
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end

function read_csv(path::AbstractString)
    lines = filter(!isempty, strip.(readlines(path), Ref(['\r', '﻿', ' '])))
    isempty(lines) && return String[], Vector{Vector{String}}()
    header = parse_csv_line(lines[1])
    rows = [parse_csv_line(l) for l in lines[2:end]]
    return header, rows
end

csv_escape(s) = occursin(r"[\",]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s

# ---------- History file ----------
#
# Read leniently, because people edit it by hand:
#  - the "date,pub" header is optional (a first line that is a real pick is kept)
#  - commas, semicolons (Excel in some locales) or tabs all work
#  - a line with just a pub name (no date) counts too
#  - blank lines and lines starting with # are skipped

function read_history(path)
    entries = Tuple{String,String}[]
    isfile(path) || return entries
    for (i, line) in enumerate(readlines(path))
        l = strip(line, ['\r', '﻿', ' ', '\t'])
        (isempty(l) || startswith(l, "#")) && continue
        delim = occursin(',', l) ? ',' : occursin(';', l) ? ';' : occursin('\t', l) ? '\t' : nothing
        fields = delim === nothing ? [String(l)] :
                 delim == ',' ? parse_csv_line(l) : String.(split(l, delim))
        fields = [String(strip(f)) for f in fields]
        date, pub = length(fields) >= 2 ? (fields[1], fields[2]) : ("", fields[1])
        isempty(pub) && continue
        # skip a header line such as "date,pub"
        (lowercase(pub) in ("pub", "pubs", "name") && lowercase(date) in ("", "date", "when")) && continue
        push!(entries, (date, pub))
    end
    return entries
end

function append_history(path, pub)
    needs_header = !isfile(path) || filesize(path) == 0
    # if the file was hand-edited without a final newline, add one first
    needs_newline = !needs_header && begin
        open(path, "r") do io
            seekend(io); skip(io, -1); read(io, UInt8) != UInt8('\n')
        end
    end
    open(path, "a") do io
        needs_header && println(io, "date,pub")
        needs_newline && println(io)
        println(io, string(today()), ",", csv_escape(pub))
    end
end

# Default file lookup: current folder, then the responses CSV's folder, then
# the script's folder. Falls back to the current folder (where it'll be created).
function locate(name, responses)
    for dir in (pwd(), dirname(abspath(responses)), @__DIR__)
        p = joinpath(dir, name)
        isfile(p) && return p
    end
    return joinpath(pwd(), name)
end

# Normalise column headers so " Pub? " and "pub?" match.
normname(s) = lowercase(join(split(strip(s)), " "))

# Normalise pub names: ignore capitals, "the", apostrophes/full stops, hyphens,
# and "&" vs "and". So "The King's Head", "kings head" and "Kings-Head" match.
function pubkey(s)
    t = lowercase(strip(s))
    t = replace(t, "&" => " and ")
    t = replace(t, r"['’‘`.,!?\"]" => "")
    t = replace(t, r"[-_/]" => " ")
    return join(filter(w -> w != "the", split(t)), " ")
end

# Show "jo.bloggs" rather than "jo.bloggs@bristol.ac.uk" when only emails are collected.
display_person(s) = occursin('@', s) ? String(first(split(s, '@'))) : String(strip(s))

# ---------- Minimal JSON writer ----------

function jstr(s)
    s = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n",
                "\r" => "", "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026")
    return "\"" * s * "\""
end
jval(x::AbstractString) = jstr(x)
jval(x::Bool) = x ? "true" : "false"
jval(x::Integer) = string(x)
jval(x::AbstractFloat) = isfinite(x) ? string(x) : "0"
jval(::Nothing) = "null"
jval(v::AbstractVector) = "[" * join(jval.(v), ",") * "]"
jval(d::AbstractDict) = "{" * join([jstr(k) * ":" * jval(v) for (k, v) in d], ",") * "}"

# ---------- Core ----------

"""
    pub_weight(p, x, y)

Weight p(1 - 1/x)^y. Returns 0 for p == 0 or x == 0 (chosen this draw).
x may be `nothing` for a pub never chosen (then y == 0 and w = p).
"""
function pub_weight(p::Integer, x, y::Integer)
    p == 0 && return 0.0
    y == 0 && return float(p)
    x == 0 && return 0.0
    return p * (1 - 1 / float(x))^y
end

"""
    draw_order(names, weights)

Weighted draws without replacement: element 1 is the pick, element 2 is what
you'd get after vetoing it, and so on. Only positive weights take part.
"""
function draw_order(names, weights)
    pool = [(n, w) for (n, w) in zip(names, weights) if w > 0]
    order = String[]
    while !isempty(pool)
        r = rand() * sum(last, pool)
        acc = 0.0
        idx = length(pool)
        for (j, (_, w)) in enumerate(pool)
            acc += w
            if r < acc
                idx = j
                break
            end
        end
        push!(order, pool[idx][1])
        deleteat!(pool, idx)
    end
    return order
end

function open_in_browser(url)
    try
        if Sys.isapple()
            run(`open $url`; wait = false)
        elseif Sys.iswindows()
            run(`cmd /c start "" $url`; wait = false)
        else
            run(pipeline(`xdg-open $url`; stdout = devnull, stderr = devnull); wait = false)
        end
    catch
        println("Couldn't open a browser automatically; open the address above.")
    end
end

# ---------- Tiny local web server (stdlib Sockets) ----------

function respond(sock, status, ctype, body)
    write(sock, "HTTP/1.1 $status\r\nContent-Type: $ctype\r\nContent-Length: $(sizeof(body))\r\n" *
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n", body)
end

function handle(sock, html, on_confirm)
    try
        reqline = readline(sock)
        parts = split(reqline)
        length(parts) >= 2 || return
        method, path = parts[1], parts[2]
        len = 0
        while true
            l = readline(sock)
            isempty(l) && break
            m = match(r"^content-length:\s*(\d+)"i, l)
            m !== nothing && (len = parse(Int, m[1]))
        end
        body = len > 0 ? String(read(sock, len)) : ""

        if method == "GET" && (path == "/" || startswith(path, "/?") || path == "/index.html")
            respond(sock, "200 OK", "text/html; charset=utf-8", html)
        elseif method == "POST" && path == "/confirm"
            respond(sock, "200 OK", "application/json", on_confirm(body))
        elseif path == "/favicon.ico"
            respond(sock, "204 No Content", "text/plain", "")
        else
            respond(sock, "404 Not Found", "text/plain", "Not found")
        end
    catch e
        e isa Base.IOError || @warn "Request failed" exception = e
    finally
        close(sock)
    end
end

function main(args)
    responses = nothing
    pubs_file = nothing
    history_file = nothing
    column = nothing
    name_column = nothing
    addition_column = nothing
    port = nothing
    auto_open = true
    dry_run = false
    odds_only = false
    seed = nothing
    site_dir = nothing
    lockin_url = ""

    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--pubs";            pubs_file = args[i+=1]
        elseif a == "--history";     history_file = args[i+=1]
        elseif a == "--column";      column = args[i+=1]
        elseif a == "--name-column"; name_column = args[i+=1]
        elseif a == "--addition-column"; addition_column = args[i+=1]
        elseif a == "--port";        port = parse(Int, args[i+=1])
        elseif a == "--seed";        seed = parse(Int, args[i+=1])
        elseif a == "--site";        site_dir = args[i+=1]
        elseif a == "--lockin-url";  lockin_url = args[i+=1]
        elseif a == "--no-open";     auto_open = false
        elseif a == "--dry-run";     dry_run = true
        elseif a == "--odds";        odds_only = true
        elseif a in ("-h", "--help")
            println("Usage: julia pubinator.jl responses.csv [--pubs FILE] [--history FILE] [--column NAME] [--name-column NAME] [--addition-column NAME] [--port N] [--no-open] [--dry-run] [--odds] [--seed N] [--site DIR --lockin-url URL]")
            return
        elseif startswith(a, "--"); error("Unknown option $a")
        else responses = a
        end
        i += 1
    end
    responses === nothing && error("Give the path to the Google Form responses CSV.")
    seed !== nothing && Random.seed!(seed)
    pubs_file = something(pubs_file, locate("pubs.txt", responses))
    history_file = something(history_file, locate("history.csv", responses))

    # --- Pub list: canonical display names keyed by normalised name ---
    canon = Dict{String,String}()
    use_list = pubs_file != "none"
    if use_list
        isfile(pubs_file) || error("Pub list '$pubs_file' not found (use --pubs none to skip).")
        for l in readlines(pubs_file)
            s = strip(l)
            (isempty(s) || startswith(s, "#")) && continue
            canon[pubkey(s)] = s
        end
    end

    # --- Form responses: pub, name and addition columns ---
    header, rows = read_csv(responses)
    col = if column !== nothing
        findfirst(h -> normname(h) == normname(column), header)
    else
        something(findfirst(h -> occursin("pub", lowercase(h)), header), length(header))
    end
    col === nothing && error("Column '$column' not found. Columns: $(join(header, " | "))")

    acol = if addition_column !== nothing
        c = findfirst(h -> normname(h) == normname(addition_column), header)
        c === nothing && error("Addition column '$addition_column' not found. Columns: $(join(header, " | "))")
        c
    else
        c = findfirst(j -> j != col && occursin("addition", lowercase(header[j])), eachindex(header))
        if c === nothing && length(header) >= 3 && length(header) - 1 != col
            c = length(header) - 1
        end
        c
    end

    ncol = if name_column !== nothing
        c = findfirst(h -> normname(h) == normname(name_column), header)
        c === nothing && error("Name column '$name_column' not found. Columns: $(join(header, " | "))")
        c
    else
        others = [j for j in eachindex(header) if j != col && j != acol]
        c = findfirst(j -> occursin("name", lowercase(header[j])), others)
        c === nothing && (c = findfirst(j -> occursin("email", lowercase(header[j])), others))
        c === nothing ? nothing : others[c]
    end

    person_of(r) = (ncol !== nothing && ncol <= length(r) && !isempty(strip(r[ncol]))) ?
                   display_person(r[ncol]) : nothing

    popularity = Dict{String,Int}()
    suggesters = Dict{String,Vector{Pair{String,Int}}}()   # pub => [person => count]
    function credit!(k, person)
        person === nothing && return
        list = get!(suggesters, k, Pair{String,Int}[])
        j = findfirst(pr -> lowercase(pr.first) == lowercase(person), list)
        j === nothing ? push!(list, person => 1) : (list[j] = list[j].first => list[j].second + 1)
    end

    # --- Suggested additions: 2+ different people => joins the draw ---
    add_people = Dict{String,Set{String}}()        # pub key => distinct people
    add_names  = Dict{String,Vector{String}}()     # pub key => their display names
    add_spell  = Dict{String,Vector{String}}()     # pub key => spellings used
    if acol !== nothing
        for (ri, r) in enumerate(rows)
            acol <= length(r) || continue
            raw = String(strip(r[acol]))
            k = pubkey(raw)
            isempty(k) && continue
            haskey(canon, k) && continue                   # already on the list
            person = person_of(r)
            id = person === nothing ? "row $ri" : lowercase(person)
            ids = get!(add_people, k, Set{String}())
            if !(id in ids)
                push!(ids, id)
                person !== nothing && push!(get!(add_names, k, String[]), person)
            end
            push!(get!(add_spell, k, String[]), raw)
        end
    end
    added = Set{String}()
    waiting = String[]
    for (k, ids) in add_people
        spellings = add_spell[k]
        name = argmax(s -> count(==(s), spellings), unique(spellings))   # most common spelling
        if length(ids) >= 2
            canon[k] = name
            push!(added, k)
        else
            push!(waiting, name)
        end
    end

    # --- Weekly nominations ---
    people_seen = Set{String}()
    unknown = Dict{String,Int}()
    n_valid = 0
    for r in rows
        person = person_of(r)
        person !== nothing && push!(people_seen, lowercase(person))
        col <= length(r) || continue
        raw = strip(r[col])
        isempty(raw) && continue
        k = pubkey(raw)
        if use_list && !haskey(canon, k)
            unknown[raw] = get(unknown, raw, 0) + 1
            continue
        end
        use_list || (canon[k] = get(canon, k, raw))
        popularity[k] = get(popularity, k, 0) + 1
        n_valid += 1
        credit!(k, person)
    end
    for k in added
        popularity[k] = get(popularity, k, 0) + length(add_people[k])
        foreach(pn -> credit!(k, pn), get(add_names, k, String[]))
    end

    # --- History: y (times chosen) and x (draws since last chosen) ---
    entries = read_history(history_file)          # [(date, pub)], oldest first
    history = String[]                            # normalised pub names, oldest first
    unmatched = String[]
    for (_, pub) in entries
        k = pubkey(pub)
        push!(history, k)
        if !haskey(canon, k)
            canon[k] = pub
            push!(unmatched, pub)
        end
    end
    n = length(history)
    times_chosen = Dict{String,Int}()
    last_idx = Dict{String,Int}()
    for (j, k) in enumerate(history)
        times_chosen[k] = get(times_chosen, k, 0) + 1
        last_idx[k] = j
    end

    # --- Weights ---
    keys_ = collect(use_list ? keys(canon) : keys(popularity))
    stats = map(keys_) do k
        p = get(popularity, k, 0)
        y = get(times_chosen, k, 0)
        x = haskey(last_idx, k) ? n + 1 - last_idx[k] : nothing
        (key = k, name = canon[k], p = p, x = x, y = y, w = pub_weight(p, x, y), isnew = k in added)
    end
    total = sum(s.w for s in stats; init = 0.0)
    sort!(stats, by = s -> (-s.w, s.name))
    draw = n + 1
    in_running = count(s -> s.w > 0, stats)

    # --- Overview + odds table (never the result) ---
    println()
    println("  THE PUBINATOR  ·  Draw $draw  ·  ", Dates.format(today(), "e d U yyyy"))
    println("  ", "─"^62)
    println("  Pub choices from:  \"$(header[col])\"")
    println("  Names from:        ", ncol === nothing ? "(none found; use --name-column)" : "\"$(header[ncol])\"")
    println("  Additions from:    ", acol === nothing ? "(none found; use --addition-column)" : "\"$(header[acol])\"")
    println("  Submissions:       $n_valid", ncol === nothing ? "" : " from $(length(people_seen)) people")
    println("  Pubs in the running: $in_running of $(length(stats))")
    println("  History:           $(abspath(history_file))",
            isfile(history_file) ? "" : "  (not found yet: it will be created)")
    println("  Draws so far:      $n", n == 0 ? "" :
            "   (latest: " * join(reverse([isempty(d) ? p : "$p, $d" for (d, p) in entries[max(1, end-2):end]]), "; ") * ")")
    if !isempty(unmatched)
        println("  WARNING: history names not on the pub list (typo?): ", join(unique(unmatched), ", "))
    end
    if !isempty(added)
        println("  New from suggestions: ",
                join(["$(canon[k]) ($(length(add_people[k])) people)" for k in sort(collect(added))], ", "))
    end
    if !isempty(waiting)
        println("  Suggested once, needs a second: ", join(sort(waiting), ", "))
    end
    if !isempty(unknown)
        println("  Ignored (not on pub list): ",
                join(["$nm ($c)" for (nm, c) in sort(collect(unknown), by = last, rev = true)], ", "))
    end
    println()
    println("  Odds   weight = p(1 - 1/x)^y   p = popularity, x = draws since, y = times visited")
    @printf("  %-30s %10s %11s %13s %8s %7s\n", "Pub", "popularity", "draws since", "times visited", "weight", "chance")
    for s in stats
        xs = s.x === nothing ? "-" : string(s.x)
        chance = total > 0 ? 100 * s.w / total : 0.0
        nm = s.isnew ? first(s.name, 24) * " (new)" : first(s.name, 30)
        @printf("  %-30s %10d %11s %13d %8.3f %6.1f%%\n", nm, s.p, xs, s.y, s.w, chance)
    end
    println()

    odds_only && return
    total > 0 || error("Every pub has zero weight: no submissions yet, or only the last pub picked was nominated.")

    # --- Draw the full veto order up front ---
    order = draw_order([s.name for s in stats], [s.w for s in stats])

    data = Dict(
        "draw"     => draw,
        "date"     => Dates.format(today(), "e d U yyyy"),
        "dryRun"   => dry_run,
        "hasNames" => ncol !== nothing,
        "order"    => order,
        "pubs"     => [Dict("name" => s.name, "p" => s.p, "x" => s.x, "y" => s.y,
                            "w" => s.w, "chance" => s.w / total, "new" => s.isnew,
                            "suggesters" => [Dict("name" => nm, "count" => c)
                                             for (nm, c) in sort(get(suggesters, s.key, Pair{String,Int}[]),
                                                                 by = pr -> (-pr.second, lowercase(pr.first)))])
                       for s in stats],
    )
    # --- Website mode: write a static page; the order is kept out of it ---
    # encrypt.mjs then locks the order with the day's password, puts it in the
    # page in place of "__LOCK__", and deletes order.json.
    if site_dir !== nothing
        isempty(lockin_url) && error("--site needs --lockin-url (the Apps Script web app URL).")
        mkpath(site_dir)
        data["mode"] = "site"
        data["lockinUrl"] = lockin_url
        data["lock"] = "__LOCK__"
        delete!(data, "order")
        write(joinpath(site_dir, "index.html"), replace(WHEEL_TEMPLATE, "__PUB_DATA__" => jval(data)))
        write(joinpath(site_dir, "order.json"), jval(Dict("draw" => draw, "order" => order)))
        write(joinpath(site_dir, "odds.json"),
              jval(Dict("draw" => draw, "pubs" => [Dict("name" => s.name, "chance" => s.w / total)
                                                    for s in stats if s.w > 0])))
        println("  Site written to $(abspath(site_dir)) (order still to be encrypted).")
        return
    end
    data["mode"] = "local"

    html = replace(WHEEL_TEMPLATE, "__PUB_DATA__" => jval(data))

    # --- Serve the wheel and wait for "Lock it in" ---
    done = Channel{Bool}(1)
    locked = Ref(false)
    on_confirm = function (body)
        name = strip(body)
        name in order || return "{\"ok\":false,\"error\":\"unknown pub\"}"
        if !locked[]
            locked[] = true
            dry_run || append_history(history_file, String(name))
            put!(done, true)
        end
        return "{\"ok\":true,\"saved\":$(dry_run ? "false" : "true")}"
    end

    server = if port === nothing
        last(listenany(ip"127.0.0.1", 8765))
    else
        listen(ip"127.0.0.1", port)
    end
    port = Int(getsockname(server)[2])
    @async while isopen(server)
        sock = try
            accept(server)
        catch
            break
        end
        @async handle(sock, html, on_confirm)
    end

    url = "http://127.0.0.1:$port/"
    println("  Wheel is ready at $url")
    println("  Spin, veto if you must, then press \"Lock it in\" on the page.")
    println("  (Ctrl+C to quit without saving.)")
    auto_open && open_in_browser(url)

    try
        take!(done)
    catch e
        e isa InterruptException || rethrow()
        println("\n  Stopped. Nothing saved.")
        close(server)
        return
    end
    sleep(0.5)                     # let the page receive its reply
    close(server)
    println(dry_run ? "\n  Locked in (dry run: history not changed). Cheers!" :
                      "\n  Locked in and saved to $history_file. Cheers!")
end

# ---------- Wheel page template (raw string: no $ interpolation) ----------

const WHEEL_TEMPLATE = raw"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pubinator</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><circle cx='32' cy='34' r='30' fill='%234a3526'/><path d='M32 34L32.0 7.0A27 27 0 0 1 55.4 20.5Z' fill='%23c0392b'/><path d='M32 34L55.4 20.5A27 27 0 0 1 55.4 47.5Z' fill='%23d9a441'/><path d='M32 34L55.4 47.5A27 27 0 0 1 32.0 61.0Z' fill='%232e7d5b'/><path d='M32 34L32.0 61.0A27 27 0 0 1 8.6 47.5Z' fill='%233b6ea5'/><path d='M32 34L8.6 47.5A27 27 0 0 1 8.6 20.5Z' fill='%238e4b8f'/><path d='M32 34L8.6 20.5A27 27 0 0 1 32.0 7.0Z' fill='%23c8662b'/><circle cx='32' cy='34' r='7' fill='%231b1410' stroke='%23d9a441' stroke-width='2.5'/><path d='M24 0H40L32 13Z' fill='%23d9a441' stroke='%231b1410' stroke-width='1.5' stroke-linejoin='round'/></svg>">
<style>
  :root {
    --bg: #1b1410; --panel: #261c16; --ink: #f4ead8; --muted: #b9a78d;
    --line: #3d2e24; --brass: #d9a441; --brass-dim: #8a6a2c; --veto: #c0392b;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: var(--bg); color: var(--ink);
    font-family: "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, serif; }
  body { min-height: 100vh; display: flex; flex-direction: column; align-items: center;
    padding: 28px 16px 48px; }
  header { text-align: center; margin-bottom: 18px; }
  h1 { margin: 0; font-size: clamp(30px, 6vw, 48px); letter-spacing: .04em; color: var(--brass);
    font-variant: small-caps; }
  .sub { color: var(--muted); margin-top: 4px; font-size: 15px; }
  .dry { display: inline-block; margin-left: 8px; padding: 1px 8px; border: 1px solid var(--brass-dim);
    border-radius: 99px; font-size: 12px; color: var(--brass); font-family: system-ui, sans-serif; }
  main { display: grid; gap: 24px 32px; justify-content: center; align-items: start; width: 100%;
    max-width: 1100px; grid-template-columns: minmax(0, 560px) minmax(0, 380px);
    grid-template-areas: "left odds" "how odds"; }
  .left { grid-area: left; min-width: 0; }
  aside { grid-area: odds; }
  .how { grid-area: how; }
  @media (max-width: 1000px) {
    main { grid-template-columns: minmax(0, 560px); grid-template-areas: "left" "odds" "how"; }
  }
  .rankings { display: flex; align-items: center; justify-content: space-between; gap: 12px;
    text-decoration: none; color: var(--ink); font-family: system-ui, sans-serif; font-size: 14px;
    padding: 14px 20px; transition: border-color .2s, background .2s; }
  .rankings:hover { border-color: var(--brass-dim); background: #2d2119; }
  .rankings .go { color: var(--brass); font-weight: 600; white-space: nowrap; }
  .stage { position: relative; width: 100%; aspect-ratio: 1; }
  canvas#wheel { width: 100%; height: 100%; display: block; }
  .pointer { position: absolute; left: 50%; top: -6px; transform: translateX(-50%);
    width: 0; height: 0; border-left: 18px solid transparent; border-right: 18px solid transparent;
    border-top: 34px solid var(--brass); filter: drop-shadow(0 3px 3px rgba(0,0,0,.5)); z-index: 2; }
  button { font-family: inherit; cursor: pointer; }
  button#spin { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
    width: 22%; aspect-ratio: 1; border-radius: 50%; border: 3px solid var(--brass);
    background: radial-gradient(circle at 35% 30%, #3a2a1f, #140e0a); color: var(--brass);
    font-weight: 700; font-size: clamp(14px, 3vw, 20px); letter-spacing: .08em;
    box-shadow: 0 4px 18px rgba(0,0,0,.6); z-index: 2; }
  button#spin:hover:not(:disabled) { filter: brightness(1.2); }
  button#spin:disabled { cursor: default; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; }
  .card h2 { margin: 0 0 10px; font-size: 16px; color: var(--muted); font-weight: 400;
    font-family: system-ui, sans-serif; letter-spacing: .06em; text-transform: uppercase; }
  table { width: 100%; border-collapse: collapse; font-family: system-ui, sans-serif; font-size: 13px; }
  th { text-align: right; color: var(--muted); font-weight: 500; padding: 4px 4px 6px; border-bottom: 1px solid var(--line); }
  th:first-child, td:first-child { text-align: left; }
  td { padding: 5px 4px; text-align: right; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums;
    transition: color .3s; }
  td .sw { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 7px; vertical-align: -1px; }
  tr.zero td { color: #7a6a57; }
  tr.vetoed td { color: #7a6a57; }
  tr.vetoed td:first-child span.nm { text-decoration: line-through; text-decoration-color: var(--veto); }
  tr.vetoed td .tag { color: var(--veto); font-size: 11px; margin-left: 6px; text-transform: uppercase; letter-spacing: .06em; }
  tr.win td { color: var(--brass); font-weight: 600; }
  aside { display: flex; flex-direction: column; gap: 18px; }
  th.rot { vertical-align: bottom; padding: 4px 6px 8px; width: 1%; }
  th.rot span { writing-mode: vertical-rl; transform: rotate(180deg); white-space: nowrap;
    display: inline-block; line-height: 1.1; }
  th.pubh { vertical-align: bottom; }
  td { padding-left: 6px; padding-right: 6px; }
  .newtag { display: inline-block; font-family: system-ui, sans-serif; font-size: 10px; font-weight: 600;
    text-transform: uppercase; letter-spacing: .06em; color: #7fc79b; border: 1px solid #3f7a57;
    border-radius: 99px; padding: 0 6px; margin-left: 6px; vertical-align: 1px; line-height: 15px; }
  .how math { font-family: "Latin Modern Math", "STIX Two Math", "Cambria Math", "Cambria", serif;
    color: var(--ink); font-size: 26px; margin: 6px 0 4px; }
  .how math.chance-eq { font-size: 17px; color: var(--muted); margin: 0 0 12px; }
  .how dl { margin: 0; display: grid; grid-template-columns: 22px 1fr; gap: 8px 6px;
    font-family: system-ui, sans-serif; font-size: 13px; line-height: 1.45; }
  .how dt { font-family: "Latin Modern Math", "STIX Two Math", Georgia, serif; font-size: 17px; color: var(--brass); }
  .how dd { margin: 0; color: var(--muted); }
  .how dd b { color: var(--ink); font-weight: 600; }
  .how .note { margin: 12px 0 0; font-family: system-ui, sans-serif; font-size: 12px; color: var(--muted); }
  #result { display: none; margin-top: 18px; text-align: center; }
  #result.show { display: block; animation: rise .6s ease-out; }
  @keyframes rise { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
  #result .label { color: var(--muted); font-family: system-ui, sans-serif; font-size: 13px;
    text-transform: uppercase; letter-spacing: .12em; }
  #result .pub { font-size: clamp(28px, 5vw, 40px); color: var(--brass); margin: 4px 0 10px; }
  #result .who { font-size: 17px; line-height: 1.5; }
  #result .who b { color: var(--ink); }
  .actions { display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; margin-top: 16px; }
  .actions button { padding: 10px 18px; border-radius: 10px; font-size: 16px; font-weight: 600; border: 2px solid; }
  #veto { background: transparent; color: #e8836f; border-color: var(--veto); }
  #veto:hover:not(:disabled) { background: rgba(192,57,43,.15); }
  #lock { background: var(--brass); color: #1b1410; border-color: var(--brass); }
  #lock:hover:not(:disabled) { filter: brightness(1.1); }
  .actions button:disabled { opacity: .4; cursor: default; }
  #status { margin-top: 12px; font-family: system-ui, sans-serif; font-size: 14px; color: var(--muted); min-height: 1.2em; }
  #status.ok { color: #7fc79b; }
  #status.err { color: #e8836f; }
  #unlock { display: none; margin-top: 18px; text-align: center; }
  #unlock.show { display: block; }
  #unlock .label { color: var(--muted); font-family: system-ui, sans-serif; font-size: 13px;
    text-transform: uppercase; letter-spacing: .12em; margin-bottom: 10px; }
  .pwrow { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
  #pw { flex: 1 1 220px; max-width: 320px; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line);
    background: #140e0a; color: var(--ink); font-size: 16px; font-family: ui-monospace, Menlo, monospace; }
  #pw:focus { outline: 2px solid var(--brass-dim); }
  #unlockBtn { padding: 10px 18px; border-radius: 10px; font-size: 16px; font-weight: 600;
    background: var(--brass); color: #1b1410; border: 2px solid var(--brass); }
  #unlockBtn:disabled { opacity: .5; cursor: default; }
  #pwmsg { margin-top: 10px; min-height: 1.2em; font-family: system-ui, sans-serif; font-size: 14px; color: #e8836f; }
  .stale { display: block; margin-top: 6px; color: #e8836f; font-family: system-ui, sans-serif; font-size: 14px; }
  #confetti { position: fixed; inset: 0; pointer-events: none; z-index: 5; }
</style>
</head>
<body>
<canvas id="confetti"></canvas>
<header>
  <h1>The Pubinator</h1>
  <div class="sub" id="sub"></div>
</header>
<main>
  <div class="left">
    <div class="stage">
      <div class="pointer"></div>
      <canvas id="wheel"></canvas>
      <button id="spin">SPIN</button>
    </div>
    <form id="unlock" class="card" autocomplete="off">
      <div class="label">Enter today's password to spin</div>
      <div class="pwrow">
        <input id="pw" type="password" placeholder="word-word-word-word-00" autocapitalize="none" spellcheck="false">
        <button type="submit" id="unlockBtn">Unlock</button>
      </div>
      <div id="pwmsg"></div>
    </form>
    <div id="result" class="card">
      <div class="label" id="rlabel">We're going to</div>
      <div class="pub" id="rpub"></div>
      <div class="who" id="rwho"></div>
      <div class="actions">
        <button id="veto">Veto &amp; spin again</button>
        <button id="lock">Lock it in</button>
      </div>
      <div id="status"></div>
    </div>
  </div>
  <aside>
    <a class="card rankings" href="https://tomhigginson.github.io/PubLeaderboard/PubRankings_Extra.html"
       target="_blank" rel="noopener">
      <span>For pub rankings, see</span><span class="go">Pub Leaderboard &rarr;</span>
    </a>
    <div class="card">
      <h2>This draw's odds</h2>
      <table>
        <thead><tr>
          <th class="pubh">Pub</th>
          <th class="rot"><span>Popularity</span></th>
          <th class="rot"><span>Draws since</span></th>
          <th class="rot"><span>Times visited</span></th>
          <th class="rot"><span>Chance</span></th>
        </tr></thead>
        <tbody id="odds"></tbody>
      </table>
    </div>
  </aside>
  <div class="card how">
    <h2>How the odds work</h2>
    <math display="block">
      <mi>w</mi><mo>=</mo><mi>p</mi>
      <msup>
        <mrow><mo stretchy="true">(</mo><mn>1</mn><mo>&minus;</mo>
          <mfrac><mn>1</mn><mi>x</mi></mfrac>
        <mo stretchy="true">)</mo></mrow>
        <mi>y</mi>
      </msup>
    </math>
    <math display="block" class="chance-eq">
      <mtext>chance</mtext><mo>=</mo>
      <mfrac><mi>w</mi><mrow><mo>&sum;</mo><msub><mi>w</mi><mtext>all&nbsp;pubs</mtext></msub></mrow></mfrac>
    </math>
    <dl>
      <dt><i>p</i></dt><dd><b>Popularity</b>: how many times the pub has been nominated on the form. Pubs tagged <span class="newtag">new</span> joined from the suggested additions and count one per person who suggested them.</dd>
      <dt><i>x</i></dt><dd><b>Draws since</b> it was last picked, counted from the history (dates don't matter, so skipped weeks or two draws in one week are fine). Picked last draw means <i>x</i>&nbsp;=&nbsp;1, so <i>w</i>&nbsp;=&nbsp;0 and it can't come up twice in a row. The longer since the last visit, the closer the factor gets to 1.</dd>
      <dt><i>y</i></dt><dd><b>Times visited</b> in total. Each visit multiplies in another factor below 1. Never visited means <i>w</i>&nbsp;=&nbsp;<i>p</i>.</dd>
    </dl>
    <p class="note">After a veto, that pub is removed and the rest are rescaled so their chances add up to 100% again.</p>
  </div>
</main>
<script>
const DATA = __PUB_DATA__;
const SITE = DATA.mode === "site";
let ORDER = DATA.order || null;         // site mode: unlocked with the password
let PASSWORD = null;

const PALETTE = ["#c0392b","#d9a441","#2e7d5b","#3b6ea5","#8e4b8f","#c8662b",
                 "#5a8f3a","#a33f5f","#2f8a8a","#7b5ea7","#b5873a","#4f6d3a"];
const TAU = Math.PI * 2;
const pubs = DATA.pubs;
const byName = Object.fromEntries(pubs.map(p => [p.name, p]));
const live = pubs.filter(p => p.w > 0);          // everything that can appear on the wheel
live.forEach((p, i) => {
  p.color = PALETTE[i % PALETTE.length];
  if (i === live.length - 1 && i > 0 && p.color === live[0].color) p.color = PALETTE[(i + 1) % PALETTE.length];
  p.dw = p.w;                                      // displayed weight (animates to 0 on veto)
});

let step = 0;              // index into ORDER
let current = null;        // pub currently shown as the result
let busy = false, lockedIn = false;
const vetoed = [];

function londonToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(new Date());
}
const STALE = SITE && DATA.lock && DATA.lock.date !== londonToday();
document.getElementById("sub").innerHTML =
  `Draw ${DATA.draw} &middot; ${SITE ? esc(DATA.lock.label) : DATA.date}` +
  (DATA.dryRun ? `<span class="dry">dry run</span>` : "") +
  (STALE ? `<span class="stale">This page was built for ${esc(DATA.lock.label)}. Today's version is on its way, so check back later.</span>` : "");

function esc(s) { return s.replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

// ---- odds table ----
const tbody = document.getElementById("odds");
for (const p of pubs) {
  const tr = document.createElement("tr");
  if (p.w <= 0) tr.className = "zero";
  const sw = `<span class="sw" style="background:${p.color || "transparent"}"></span>`;
  const nt = p.new ? `<span class="newtag" title="Added from suggestions">new</span>` : "";
  tr.innerHTML = `<td>${sw}<span class="nm">${esc(p.name)}</span>${nt}<span class="tag"></span></td>` +
                 `<td>${p.p}</td><td>${p.x ?? "&ndash;"}</td><td>${p.y}</td><td class="ch"></td>`;
  p.row = tr; tbody.appendChild(tr);
}
function fmtPct(c) { return (c * 100).toFixed(c > 0 && c < 0.01 ? 2 : 1) + "%"; }
function updateTable() {
  const tot = live.filter(p => !p.gone).reduce((s, p) => s + p.w, 0);
  for (const p of pubs) {
    const c = (p.w > 0 && !p.gone) ? p.w / tot : 0;
    p.row.querySelector(".ch").textContent = fmtPct(c);
    p.row.classList.toggle("vetoed", !!p.gone);
    p.row.querySelector(".tag").textContent = p.gone ? "vetoed" : "";
  }
}
updateTable();

// ---- wedge geometry from displayed weights, clockwise from the top ----
function layout() {
  const tot = live.reduce((s, p) => s + p.dw, 0);
  let a = 0;
  for (const p of live) { p.start = a; a += tot > 0 ? p.dw / tot * TAU : 0; p.end = a; }
}
layout();

// ---- wheel drawing ----
const cv = document.getElementById("wheel"), ctx = cv.getContext("2d");
let size = 0, rot = 0;
function resize() {
  const r = cv.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
  size = r.width; cv.width = size * dpr; cv.height = size * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0); draw();
}
function draw() {
  const c = size / 2, R = c - 10;
  ctx.clearRect(0, 0, size, size);
  ctx.beginPath(); ctx.arc(c, c, R + 7, 0, TAU); ctx.fillStyle = "#4a3526"; ctx.fill();
  ctx.save(); ctx.translate(c, c); ctx.rotate(rot);
  const shown = live.filter(p => p.end - p.start > 1e-4);
  for (const p of shown) {
    const s = p.start - Math.PI / 2, e = p.end - Math.PI / 2;
    ctx.beginPath(); ctx.moveTo(0, 0); ctx.arc(0, 0, R, s, e); ctx.closePath();
    ctx.fillStyle = p.color; ctx.fill();
    if (shown.length > 1) { ctx.strokeStyle = "rgba(20,14,10,.55)"; ctx.lineWidth = 2; ctx.stroke(); }
    const span = p.end - p.start, mid = (s + e) / 2;
    const fs = Math.max(11, Math.min(18, size / 30));
    if (span * R * 0.62 > fs * 1.1) {
      const flip = Math.cos(mid + rot) < 0;      // keep text upright
      ctx.save(); ctx.rotate(flip ? mid + Math.PI : mid);
      ctx.fillStyle = "#fffaf0"; ctx.font = `600 ${fs}px Georgia, serif`;
      ctx.textAlign = flip ? "left" : "right"; ctx.textBaseline = "middle";
      ctx.shadowColor = "rgba(0,0,0,.45)"; ctx.shadowBlur = 3;
      let label = p.name; const maxW = R * 0.66;
      while (ctx.measureText(label).width > maxW && label.length > 3) label = label.slice(0, -2) + "…";
      ctx.fillText(label, flip ? -(R - 14) : R - 14, 0);
      ctx.restore();
    }
  }
  ctx.restore();
  for (let i = 0; i < 24; i++) {
    const t = i / 24 * TAU;
    ctx.beginPath(); ctx.arc(c + Math.cos(t) * (R + 3.5), c + Math.sin(t) * (R + 3.5), 2.2, 0, TAU);
    ctx.fillStyle = "#d9a441"; ctx.fill();
  }
}
window.addEventListener("resize", resize);
resize();

// ---- sound ----
let audio = null;
function tick() {
  try {
    audio = audio || new (window.AudioContext || window.webkitAudioContext)();
    const o = audio.createOscillator(), g = audio.createGain();
    o.type = "square"; o.frequency.value = 1400;
    g.gain.setValueAtTime(0.05, audio.currentTime);
    g.gain.exponentialRampToValueAtTime(0.0001, audio.currentTime + 0.03);
    o.connect(g).connect(audio.destination); o.start(); o.stop(audio.currentTime + 0.035);
  } catch (e) {}
}

// ---- spin ----
const btn = document.getElementById("spin");
const resultEl = document.getElementById("result");
const vetoBtn = document.getElementById("veto"), lockBtn = document.getElementById("lock");
const statusEl = document.getElementById("status");

function wedgeUnderPointer(r) {
  const at = ((-r % TAU) + TAU) % TAU;
  return live.findIndex(p => !p.gone && at >= p.start && at < p.end);
}

function spin() {
  if (busy || lockedIn) return;
  if (!ORDER) { showUnlock(); return; }
  busy = true; btn.disabled = true; btn.textContent = "…";
  resultEl.classList.remove("show");
  pubs.forEach(p => p.row.classList.remove("win"));
  const target = byName[ORDER[step]];
  const span = target.end - target.start;
  const landAt = target.start + span * (0.15 + 0.7 * Math.random());
  const from = ((rot % TAU) + TAU) % TAU;
  const turns = 6 + Math.floor(Math.random() * 3);
  const to = turns * TAU + ((TAU - landAt) % TAU);
  const dur = 6500, t0 = performance.now();
  let last = wedgeUnderPointer(from);
  const ease = t => 1 - Math.pow(1 - t, 4);
  function frame(now) {
    const t = Math.min(1, (now - t0) / dur);
    rot = from + (to - from) * ease(t);
    draw();
    const w = wedgeUnderPointer(rot);
    if (w !== last && live.length - vetoed.length > 1) { tick(); last = w; }
    if (t < 1) requestAnimationFrame(frame); else reveal(target);
  }
  requestAnimationFrame(frame);
}
btn.addEventListener("click", spin);

function reveal(p) {
  current = p; busy = false;
  btn.textContent = "🍺";
  document.getElementById("rlabel").textContent =
    vetoed.length ? `After ${vetoed.length} veto${vetoed.length > 1 ? "es" : ""}, we're going to` : "We're going to";
  document.getElementById("rpub").textContent = p.name;
  const who = document.getElementById("rwho");
  if (!DATA.hasNames) {
    who.textContent = "";
  } else if (p.suggesters.length === 0) {
    who.textContent = "Nobody nominated it on the form. The wheel works in mysterious ways.";
  } else {
    const names = p.suggesters.map(s => `<b>${esc(s.name)}</b>` + (s.count > 1 ? ` &times;${s.count}` : ""));
    const list = names.length === 1 ? names[0]
      : names.slice(0, -1).join(", ") + " and " + names[names.length - 1];
    who.innerHTML = `Suggested by ${list}.`;
  }
  const left = ORDER.length - step - 1;
  vetoBtn.disabled = left === 0;
  vetoBtn.textContent = left === 0 ? "Nothing left to veto" : "Veto & spin again";
  lockBtn.disabled = false;
  statusEl.textContent = ""; statusEl.className = "";
  resultEl.classList.add("show");
  p.row.classList.add("win");
  confetti();
}

// ---- veto: shrink the wedge away, rescale the odds, spin again ----
vetoBtn.addEventListener("click", () => {
  if (busy || lockedIn || !current || step >= ORDER.length - 1) return;
  busy = true;
  const p = current; p.gone = true; vetoed.push(p.name); current = null;
  p.row.classList.remove("win");
  resultEl.classList.remove("show");
  updateTable();
  const w0 = p.dw, t0 = performance.now(), dur = 700;
  (function shrink(now) {
    const t = Math.min(1, (now - t0) / dur);
    p.dw = w0 * (1 - t) * (1 - t);
    layout(); draw();
    if (t < 1) requestAnimationFrame(shrink);
    else { p.dw = 0; layout(); draw(); step += 1; busy = false; setTimeout(spin, 350); }
  })(t0);
});

// ---- site mode: unlock the day's order with the password ----
const enc = new TextEncoder();
const unlockEl = document.getElementById("unlock"), pwEl = document.getElementById("pw");
const pwMsg = document.getElementById("pwmsg"), unlockBtn = document.getElementById("unlockBtn");
function b64(s) { return Uint8Array.from(atob(s), c => c.charCodeAt(0)); }
function normPw(s) { return s.trim().toLowerCase().replace(/[\s_]+/g, "-").replace(/-+/g, "-"); }
function showUnlock() {
  if (STALE) { pwMsg.textContent = "This page is out of date. Check back once today's version is up."; }
  unlockEl.classList.add("show"); pwEl.focus();
}
async function tryUnlock(pw) {
  const L = DATA.lock;
  const base = await crypto.subtle.importKey("raw", enc.encode(pw), "PBKDF2", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey(
    { name: "PBKDF2", salt: b64(L.salt), iterations: L.iter, hash: "SHA-256" },
    base, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64(L.iv) }, key, b64(L.ct));
  return JSON.parse(new TextDecoder().decode(plain));
}
unlockEl.addEventListener("submit", async ev => {
  ev.preventDefault();
  const pw = normPw(pwEl.value);
  if (!pw) return;
  if (!(window.crypto && crypto.subtle)) {
    pwMsg.textContent = "This page needs a secure (https://) address to unlock.";
    return;
  }
  unlockBtn.disabled = true; pwMsg.textContent = "Checking…";
  try {
    const o = await tryUnlock(pw);
    if (o.draw !== DATA.draw) throw new Error("mismatch");
    ORDER = o.order; PASSWORD = pw;
    try { sessionStorage.setItem("pubinator-pw-" + DATA.lock.date, pw); } catch (e) {}
    unlockEl.classList.remove("show"); pwMsg.textContent = "";
    spin();
  } catch (e) {
    pwMsg.textContent = STALE ? "That doesn't unlock this (old) page. Check back once today's version is up."
                              : "That isn't today's password.";
  } finally { unlockBtn.disabled = false; }
});
// remember the password for this tab, so a refresh doesn't ask again
if (SITE && !STALE) {
  try {
    const saved = sessionStorage.getItem("pubinator-pw-" + DATA.lock.date);
    if (saved) tryUnlock(saved).then(o => { if (o.draw === DATA.draw) { ORDER = o.order; PASSWORD = saved; } }).catch(() => {});
  } catch (e) {}
}
async function proofFor(pub) {
  const k = await crypto.subtle.importKey("raw", enc.encode(PASSWORD), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, enc.encode(`${DATA.lock.date}|${DATA.draw}|${pub}`));
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, "0")).join("");
}

// ---- lock in: local mode tells the Julia script; site mode tells the gatekeeper ----
lockBtn.addEventListener("click", async () => {
  if (busy || lockedIn || !current) return;
  vetoBtn.disabled = true; lockBtn.disabled = true;
  statusEl.className = ""; statusEl.textContent = "Saving…";
  if (SITE) {
    try {
      const body = JSON.stringify({ date: DATA.lock.date, draw: DATA.draw, pub: current.name,
                                    proof: await proofFor(current.name) });
      const res = await fetch(DATA.lockinUrl, { method: "POST",
        headers: { "Content-Type": "text/plain;charset=utf-8" }, body });
      const j = await res.json();
      if (!j.ok) {
        statusEl.className = "err"; statusEl.textContent = j.error || "Not saved.";
        vetoBtn.disabled = step >= ORDER.length - 1; lockBtn.disabled = false;
        return;
      }
      lockedIn = true;
      statusEl.className = "ok";
      statusEl.textContent = `Locked in as draw ${j.draw}. See you there! The site will update with new odds in a few minutes.`;
      lockBtn.textContent = "Locked in ✓";
      vetoBtn.style.display = "none";
      try { sessionStorage.removeItem("pubinator-pw-" + DATA.lock.date); } catch (e) {}
    } catch (e) {
      statusEl.className = "err";
      statusEl.textContent = "Couldn't reach the gatekeeper. Check your connection and try again.";
      vetoBtn.disabled = step >= ORDER.length - 1; lockBtn.disabled = false;
    }
    return;
  }
  try {
    const res = await fetch("/confirm", { method: "POST", body: current.name });
    const j = await res.json();
    if (!j.ok) throw new Error(j.error || "not saved");
    lockedIn = true;
    statusEl.className = "ok";
    statusEl.textContent = j.saved ? `Locked in and saved as draw ${DATA.draw}. See you there!`
                                   : "Locked in (dry run, history not changed).";
    lockBtn.textContent = "Locked in ✓";
    vetoBtn.style.display = "none";
  } catch (e) {
    statusEl.className = "err";
    statusEl.textContent = "Couldn't reach the Pubinator script. Is it still running in the terminal?";
    vetoBtn.disabled = step >= ORDER.length - 1; lockBtn.disabled = false;
  }
});

// ---- confetti ----
function confetti() {
  const cc = document.getElementById("confetti"), x = cc.getContext("2d");
  const dpr = window.devicePixelRatio || 1;
  cc.width = innerWidth * dpr; cc.height = innerHeight * dpr; x.setTransform(dpr, 0, 0, dpr, 0, 0);
  const bits = Array.from({length: 160}, () => ({
    x: innerWidth / 2, y: innerHeight * 0.35,
    vx: (Math.random() - 0.5) * 14, vy: -Math.random() * 13 - 4,
    s: 5 + Math.random() * 6, r: Math.random() * TAU, vr: (Math.random() - 0.5) * 0.4,
    c: PALETTE[Math.floor(Math.random() * PALETTE.length)]
  }));
  const t0 = performance.now();
  (function stepC(now) {
    x.clearRect(0, 0, innerWidth, innerHeight);
    for (const b of bits) {
      b.vy += 0.35; b.vx *= 0.99; b.x += b.vx; b.y += b.vy; b.r += b.vr;
      x.save(); x.translate(b.x, b.y); x.rotate(b.r); x.fillStyle = b.c;
      x.fillRect(-b.s / 2, -b.s / 4, b.s, b.s / 2); x.restore();
    }
    if (now - t0 < 3500) requestAnimationFrame(stepC); else x.clearRect(0, 0, innerWidth, innerHeight);
  })(t0);
}
</script>
</body>
</html>
"""

main(ARGS)
