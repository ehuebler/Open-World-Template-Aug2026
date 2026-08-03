class_name UIPalette
extends Resource

## Master colour tokens for the menus: the surface they are drawn on, and the
## fills and inks drawn onto it. The shader in shaders/pencil/pencil_ui.gdshader
## paints the surfaces from these values, while control states and spacing live
## beside them in main_theme.tres.
##
## Five source colours run the whole UI: Midnight Violet #2d1e2f, Vanilla Custard
## #fcf6b1, Sunflower Gold #f7b32b, Celadon #a9e5bb and Burnt Tangerine #e3170a.
## Everything else here is a mix of two of them, so the UI stays in that family
## instead of drifting into greys of its own.
##
## The scheme is dark-surface: panels are violet, interactive things are the
## bright colours, and type is custard on the panels and violet on the fills.
## **Every interactive surface carries a fill that its container does not**, which
## is the rule that stops a button from disappearing into the card behind it.

@export_group("Surfaces")
## Midnight Violet, the full-screen sheet the menus are drawn on.
@export var paper := Color("2d1e2f")
## A card is lifted off the backdrop rather than recessed into it, so a panel
## reads as a sheet laid on top: Midnight Violet lightened, and deepened again
## for the wells that rows, fields and inventory tiles sit in.
@export var paper_card := Color("3c2a3f")
@export var paper_shade := Color("221624")

@export_group("Fills")
## Sunflower Gold: the primary action of a screen, and the colour of headings.
@export var accent := Color("f7b32b")
## Celadon: ordinary buttons and any secondary action. The default fill, and the
## reason a row of buttons never matches the card under it.
@export var secondary := Color("a9e5bb")
## Burnt Tangerine, for leaving and for failing, and nothing else — it only keeps
## its warning weight while it stays rare.
@export var danger := Color("e3170a")

@export_group("Pencils")
## Deep violet, for strokes and borders drawn onto the bright fills, and for type
## sitting on them.
@export var ink := Color("1a1119")
@export var ink_soft := Color("4a3a4d")
## Vanilla Custard, saved for the one thing the player is working on: the ring
## around whatever holds focus. It is the only fill-weight use of custard, which
## is what keeps the focused control obvious on a screen of identical buttons.
@export var highlight := Color("fcf6b1")

@export_group("Typography")
## Custard on the violet surfaces, stepped down twice for secondary and muted
## lines. Type sitting on a bright fill uses `ink` instead.
@export var text_primary := Color("fcf6b1")
@export var text_secondary := Color("c8c090")
@export var text_muted := Color("9f9577")
