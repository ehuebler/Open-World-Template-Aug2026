class_name UIPalette
extends Resource

## Master colour tokens for the menus: the surface they are drawn on, and the
## fills and inks drawn onto it. The shader in shaders/cosmic/cosmic_ui.gdshader
## paints the surfaces from these values, while control states and spacing live
## beside them in main_theme.tres.
##
## Five source colours run the whole UI: Void Indigo #0a0a1e, Starlight #e6eaff,
## Ion Cyan #6fdcf2, Periwinkle #b3a5f7 and Nebula Rose #ff6188. Everything else
## here is a mix of two of them, so the UI stays in that family instead of
## drifting into greys of its own.
##
## The scheme is dark-surface: panes are the deep blue-violet of open space,
## interactive things are the bright colours, and type is starlight on the panes
## and void on the fills. **Every interactive surface carries a fill that its
## container does not**, which is the rule that stops a button from disappearing
## into the pane behind it.
##
## It was a warm plum-and-cream set drawn in coloured pencil until the menus went
## cosmic. The structure survived the change unaltered, which is the argument for
## having had tokens at all: every screen moved because twelve colours did.

@export_group("Surfaces")
## Void Indigo, the full-screen sheet the menus are drawn on.
@export var paper := Color("0a0a1e")
## A pane is lifted off the backdrop rather than recessed into it, so it reads as
## a sheet of lit air over open space: Void Indigo raised towards the nebula, and
## deepened again for the wells that rows, fields and inventory tiles sit in.
@export var paper_card := Color("171436")
@export var paper_shade := Color("0d0b22")

@export_group("Fills")
## Ion Cyan: the primary action of a screen, and the colour of headings.
@export var accent := Color("6fdcf2")
## Periwinkle: ordinary buttons and any secondary action. The default fill, and
## the reason a row of buttons never matches the pane under it.
@export var secondary := Color("b3a5f7")
## Nebula Rose, for leaving and for failing, and nothing else — it only keeps its
## warning weight while it stays rare.
@export var danger := Color("ff6188")

@export_group("Inks")
## Near-black indigo, for type sitting on the bright fills. All three of those
## fills are light enough to take it, which is what lets one ink cover them.
@export var ink := Color("0a0818")
@export var ink_soft := Color("3b3470")
## Starlight at full strength, saved for the one thing the player is working on:
## the ring around whatever holds focus. It is the only fill-weight use of this
## value, which is what keeps the focused control obvious on a screen of
## identical buttons.
@export var highlight := Color("eaf3ff")

@export_group("Typography")
## Starlight on the dark panes, stepped down twice for secondary and muted lines.
## Type sitting on a bright fill uses `ink` instead.
@export var text_primary := Color("e6eaff")
@export var text_secondary := Color("b0b6e2")
@export var text_muted := Color("7f86b4")
