module EasyPlots
#  EasyPlots — A convenient, tabbed figure window for Plots.jl
#
# Architecture:
#   * A custom AbstractDisplay is pushed onto Julia's display stack.
#     It catches Plots.Plot objects and shows them as tabs in a GTK4
#     window. Everything else falls through to the normal REPL display.
#   * All Plots.jl function names (plot, plot!, sticks, title!, ...)
#     remain completely untouched. This module only adds names that
#     Plots doesn't have: figure(), gcf().
#
# Behavior:
#   plot(...)        -> draws into the current figure tab (replaces it)
#   plot!(...)       -> adds to the current figure tab ("hold on")
#   figure()         -> opens a new (empty) figure tab; next plot lands there
#   closeall()       -> closes all figure tabs
#   Toolbar          -> New Fig | Save... | Reset Zoom | Close | Close All
#   Resize window    -> plot re-renders to fit
#   Drag on plot     -> box zoom (Reset Zoom restores original limits)
#
# Then in your session (or atreplinit block):
#   using Plots; gr(); Plots.default(show = true); EasyPlots

using Gtk4
using Cairo
import Plots

export figure, closeall, gcf

# state

mutable struct FigTab
    plot::Union{Plots.Plot,Nothing}
    canvas::Any
    surface::Union{Cairo.CairoSurface,Nothing}
    rendered_size::Tuple{Int,Int}     # size of last render (0,0) = dirty
    baselims::Union{Nothing,Tuple}    # ((x1,x2),(y1,y2)) captured at first render
    label::String
end

mutable struct Shell
    window::Any                       # GtkWindow or nothing
    notebook::Any                     # GtkNotebook or nothing
    tabs::Vector{FigTab}
    counter::Int                      # for "Fig N" labels
end

const SHELL = Shell(nothing, nothing, FigTab[], 0)

struct GtkFigureDisplay <: AbstractDisplay end
const DISPLAY = GtkFigureDisplay()

# plumbing

"Find the FigTab that owns a given canvas widget."
function tab_for_canvas(c)
    for t in SHELL.tabs
        t.canvas === c && return t
    end
    return nothing
end

"Index of the currently selected notebook page, or 0."
function current_index()
    SHELL.notebook === nothing && return 0
    i = Gtk4.G_.get_current_page(SHELL.notebook)
    return Int(i) + 1
end

function current_tab()
    i = current_index()
    (i < 1 || i > length(SHELL.tabs)) && return nothing
    return SHELL.tabs[i]
end

# Rendering

"Render tab's plot to a PNG at (w,h) and load it as a Cairo surface."
function render!(t::FigTab, w::Integer, h::Integer)
    p = t.plot
    p === nothing && return
    p.attr[:size] = (w, h)
    io = IOBuffer()
    show(io, MIME("image/png"), p)
    seekstart(io)
    t.surface = Cairo.read_from_png(io)
    t.rendered_size = (w, h)
    if t.baselims === nothing
        t.baselims = try
            (Plots.xlims(p), Plots.ylims(p))
        catch
            nothing
        end
    end
    return nothing
end

"Attach the draw callback (fires on expose AND on resize)."
function hook_draw!(t::FigTab)
    @guarded draw(t.canvas) do c
        w = Gtk4.width(c)                          # CALIBRATE
        h = Gtk4.height(c)                         # CALIBRATE
        (w <= 1 || h <= 1) && return
        tt = tab_for_canvas(c)
        tt === nothing && return
        if tt.rendered_size != (w, h) && tt.plot !== nothing
            try
                render!(tt, w, h)
            catch err
                @warn "FigShell render failed" err
            end
        end
        ctx = getgc(c)
        # clear background
        Cairo.set_source_rgb(ctx, 1, 1, 1)
        Cairo.rectangle(ctx, 0, 0, w, h)
        Cairo.fill(ctx)
        if tt.surface !== nothing
            Cairo.set_source_surface(ctx, tt.surface, 0, 0)
            Cairo.paint(ctx)
        end
    end
end

"Force a redraw of a tab, invalidating the render cache."
function refresh!(t::FigTab)
    t.rendered_size = (0, 0)
    t.canvas !== nothing && draw(t.canvas)
    return nothing
end

# ------------------------------------------------- pixel -> data mapping --

"""
Map a canvas pixel (px,py) to data coordinates of the plot in tab `t`.
Uses Plots' plotarea bounding box (reported in mm; Plots renders at
p.attr[:dpi], default 100 px/inch). Falls back to whole-canvas proportional
mapping if the bbox probing fails.
"""
function px_to_data(t::FigTab, px::Real, py::Real)
    p  = t.plot
    w, h = t.rendered_size
    xl = Plots.xlims(p)
    yl = Plots.ylims(p)
    left = 0.0; top = 0.0; aw = float(w); ah = float(h)
    try
        sp  = p.subplots[end] # TODO: Handle more than 1 subplot
        bb  = Plots.plotarea(sp)
        dpi = get(p.attr, :dpi, 100)
        mm2px(x) = Float64(x.value) / 25.4 * dpi    # CALIBRATE (Measures internals)
        left = mm2px(Plots.left(bb))
        top  = mm2px(Plots.top(bb))
        aw   = mm2px(Plots.width(bb))
        ah   = mm2px(Plots.height(bb))
    catch
        # fall back to proportional mapping over the whole canvas
    end
    fx = clamp((px - left) / aw, 0.0, 1.0)
    fy = clamp((py - top)  / ah, 0.0, 1.0)
    dx = xl[1] + fx * (xl[2] - xl[1])
    dy = yl[2] - fy * (yl[2] - yl[1])   # y axis is inverted in pixel space
    return dx, dy
end

"Apply box zoom given two canvas-pixel corners."
function apply_boxzoom!(t::FigTab, x0, y0, x1, y1)
    t.plot === nothing && return
    (abs(x1 - x0) < 5 || abs(y1 - y0) < 5) && return   # ignore tiny drags
    a = px_to_data(t, min(x0, x1), min(y0, y1))
    b = px_to_data(t, max(x0, x1), max(y0, y1))
    xmin, xmax = min(a[1], b[1]), max(a[1], b[1])
    ymin, ymax = min(a[2], b[2]), max(a[2], b[2])
    p = t.plot
    Plots.xlims!(p, xmin, xmax)
    Plots.ylims!(p, ymin, ymax)
    refresh!(t)
    return nothing
end

function reset_zoom!(t::FigTab)
    (t.plot === nothing || t.baselims === nothing) && return
    (xl, yl) = t.baselims
    Plots.xlims!(t.plot, xl...)
    Plots.ylims!(t.plot, yl...)
    refresh!(t)
    return nothing
end

"Attach a drag gesture for box zoom."
function hook_zoom!(t::FigTab)
    try
        g = GtkGestureDrag()
        Gtk4.G_.add_controller(t.canvas, g)
        start = Ref((0.0, 0.0))
        signal_connect(g, "drag-begin") do _, x, y
            start[] = (x, y)
            nothing
        end
        signal_connect(g, "drag-end") do _, dx, dy
            (x0, y0) = start[]
            apply_boxzoom!(t, x0, y0, x0 + dx, y0 + dy)
            nothing
        end
    catch err
        @warn "FigShell: box-zoom gesture unavailable (use Reset Zoom button)" err
    end
    return nothing
end

# ----------------------------------------------------------- tabs/window --

function new_tab()
    ensure_window()
    SHELL.counter += 1
    label = "Fig $(SHELL.counter)"
    canvas = GtkCanvas()
    canvas.hexpand = true
    canvas.vexpand = true
    t = FigTab(nothing, canvas, nothing, (0, 0), nothing, label)
    push!(SHELL.tabs, t)
    push!(SHELL.notebook, canvas, label)
    hook_draw!(t)
    hook_zoom!(t)
    # select the new tab
    Gtk4.G_.set_current_page(SHELL.notebook, length(SHELL.tabs) - 1)
    return t
end

function close_tab!(i::Int)
    (i < 1 || i > length(SHELL.tabs)) && return
    Gtk4.G_.remove_page(SHELL.notebook, i - 1)
    deleteat!(SHELL.tabs, i)
    return nothing
end

function do_save()
    t = current_tab()
    (t === nothing || t.plot === nothing) && return
    save_dialog("Save figure as…", SHELL.window) do fname   # CALIBRATE (async dialog)
        fname === nothing && return
        isempty(String(fname)) && return
        f = String(fname)
        # default to png if no extension given
        occursin(r"\.[A-Za-z0-9]+$", f) || (f *= ".png")
        try
            Plots.savefig(t.plot, f)
            @info "FigShell: saved" f
        catch err
            @warn "FigShell: save failed" err
        end
    end
    return nothing
end

function build_toolbar()
    bar = GtkBox(:h)
    bnew   = GtkButton("New Fig")
    bsave  = GtkButton("Save…")
    breset = GtkButton("Reset Zoom")
    bclose = GtkButton("Close")
    ball   = GtkButton("Close All")
    for b in (bnew, bsave, breset, bclose, ball)
        push!(bar, b)
    end
    signal_connect(bnew,  "clicked") do _; figure(); nothing; end
    signal_connect(bsave, "clicked") do _; do_save(); nothing; end
    signal_connect(breset,"clicked") do _
        t = current_tab(); t !== nothing && reset_zoom!(t); nothing
    end
    signal_connect(bclose,"clicked") do _
        i = current_index(); i > 0 && close_tab!(i); nothing
    end
    signal_connect(ball,  "clicked") do _; closeall(); nothing; end
    return bar
end

function ensure_window()
    SHELL.window !== nothing && return
    win = GtkWindow("Julia Figures", 900, 650)
    vbox = GtkBox(:v)
    push!(vbox, build_toolbar())
    nb = GtkNotebook()
    nb.hexpand = true                                      # CALIBRATE
    nb.vexpand = true
    push!(vbox, nb)
    push!(win, vbox)                                       # CALIBRATE (sets window child)
    signal_connect(win, "close-request") do _
        SHELL.window = nothing
        SHELL.notebook = nothing
        empty!(SHELL.tabs)
        return false   # allow the window to close
    end
    SHELL.window = win
    SHELL.notebook = nb
    show(win)                                              # CALIBRATE (may be automatic)
    return nothing
end

# ------------------------------------------------------------ public API --

"""
    figure()

Open a new (empty) figure tab, MATLAB-style. The next `plot(...)` call
draws into it. Returns nothing.
"""
function figure()
    new_tab()
    return nothing
end

"""
    closeall()

Close all figure tabs (window stays open). MATLAB's `close all`.
"""
function closeall()
    SHELL.notebook === nothing && return nothing
    while !isempty(SHELL.tabs)
        close_tab!(length(SHELL.tabs))
    end
    return nothing
end

"""
    gcf()

Return the `Plots.Plot` shown in the current figure tab (or `nothing`).
"""
gcf() = (t = current_tab(); t === nothing ? nothing : t.plot)

# --------------------------------------------------------- display hook --

function Base.display(::GtkFigureDisplay, p::Plots.Plot)
    ensure_window()
    t = current_tab()
    t === nothing && (t = new_tab())
    if t.plot !== p
        # MATLAB semantics: a NEW plot object replaces the current figure's
        # content. plot!/title! mutate the same object -> just refresh.
        t.plot = p
        t.baselims = nothing
    end
    refresh!(t)
    return nothing
end

function __init__()
    pushdisplay(DISPLAY)
    return nothing
end
end # module
