--- Joker Run Info
--- Adds a "Jokers" tab to the Run Info overlay: every Joker currently in play,
--- with its editions, stickers, debuff state and current scaling value.
---
--- The tab is injected by wrapping create_tabs while G.UIDEF.run_info runs, so
--- tabs added by other mods are kept intact.

JokerRunInfo = {}
local JRI = JokerRunInfo

local CARD_SCALE = 0.7 -- joker sprite size in the grid (leaves room for the arrow row)
local PER_ROW = 6      -- columns per row
local MAX_ROWS = 2     -- rows per page (row height ~ CARD_H*scale + text lines)
local MAX_LINES = 3    -- modifier lines shown under one joker
local PER_PAGE = PER_ROW * MAX_ROWS

JRI.page = 1

--- localize() with a fallback, so a missing translation never prints ERROR
local function L(key, fallback, category)
    local s = localize(key, category)
    if not s or s == 'ERROR' or type(s) ~= 'string' then return fallback end
    return s
end

local function label_of(name)
    return L(name == 'holo' and 'holographic' or name, (name:gsub('^%l', string.upper)), 'labels')
end

local function fmt(v)
    if type(v) == 'number' then
        return number_format and number_format(v) or tostring(v)
    end
    -- Talisman big numbers carry their own formatter
    return number_format and number_format(v) or tostring(v)
end

--------------------------------------------------------------------------------
-- value extraction
--------------------------------------------------------------------------------

-- Which card fields feed which value, in priority order. A card contributes at
-- most one value per category, so a joker that mirrors its value (e.g. both
-- ability.x_mult and ability.extra.Xmult) is never counted twice.
--
-- t_chips / t_mult hold the value of the "if played hand contains ..." jokers
-- (Sly, Devious, Crafty, Jolly, ...) and s_mult the per-suit mult of the suit
-- jokers -- those are where most of vanilla's flat chips and mult actually live.
-- Increment fields (chip_mod, mult_mod) are deliberately absent: they are how
-- much a joker gains per trigger, not what it currently gives.
local CATEGORIES = {
    { name = 'chips',   neutral = 0, keys = { 'chips', 't_chips', 'h_chips' },
      prefix = '+', label = 'k_chips', colour = 'CHIPS' },
    { name = 'mult',    neutral = 0, keys = { 'mult', 't_mult', 's_mult', 'h_mult' },
      prefix = '+', label = 'k_mult', colour = 'RED' },
    { name = 'x_mult',  neutral = 1, keys = { 'x_mult', 'Xmult', 'xmult', 'h_x_mult' },
      prefix = 'X', label = 'k_mult', colour = 'RED' },
    { name = 'x_chips', neutral = 1, keys = { 'x_chips', 'Xchips', 'xchips' },
      prefix = 'X', label = 'k_chips', colour = 'CHIPS' },
}

local function pick(source, cat)
    if type(source) ~= 'table' then return nil end
    for _, key in ipairs(cat.keys) do
        local v = source[key]
        -- a Talisman/Amulet big number is always a real value
        if v ~= nil and (type(v) == 'table' or (v ~= cat.neutral and v ~= 0)) then return v end
    end
    return nil
end

--------------------------------------------------------------------------------
-- jokers that compute their value instead of storing it
--------------------------------------------------------------------------------

-- Some jokers never write their value to the card: it is derived from run state
-- every time they score, so the stored fields are absent or stale. Bootstraps is
-- the extreme case -- with $1.7e118 it gives +6.9e117 Mult while ability.mult
-- still holds whatever it was set to long ago.
--
-- These formulas mirror the ones vanilla uses for the card's own description
-- (the loc_vars chain in Card:generate_UIBox_ability_table), so they read run
-- state only and have no side effects.

-- Talisman/Amulet big numbers are tables with arithmetic metamethods; math.floor
-- and math.max would raise on them, so guard those two operations.
local function div_floor(a, b)
    if type(a) == 'table' or type(b) == 'table' then return a / b end
    return math.floor(a / b)
end

local function at_least_zero(v)
    if type(v) == 'table' then return v end
    return math.max(0, v)
end

local function money()
    if not G.GAME then return 0 end
    return (G.GAME.dollars or 0) + (G.GAME.dollar_buffer or 0)
end

local DYNAMIC = {
    -- +Mult equal to $X worth of dollars
    j_bootstraps = function(a)
        return { mult = a.extra.mult * div_floor(money(), a.extra.dollars) }
    end,
    -- +Chips per dollar held
    j_bull = function(a)
        return { chips = a.extra * at_least_zero(G.GAME and G.GAME.dollars or 0) }
    end,
    -- +Chips per Stone Card in the full deck
    j_stone = function(a)
        return { chips = a.extra * (a.stone_tally or 0) }
    end,
    -- +Chips per remaining card in deck
    j_blue_joker = function(a)
        return { chips = a.extra * ((G.deck and G.deck.cards) and #G.deck.cards or 52) }
    end,
    -- XMult scaling with Steel Cards in the deck
    j_steel_joker = function(a)
        return { x_mult = 1 + a.extra * (a.steel_tally or 0) }
    end,
    -- +Mult per Joker in play
    j_abstract = function(a)
        return { mult = a.extra * (G.jokers and G.jokers.cards and #G.jokers.cards or 0) }
    end,
    -- +Mult per card below the starting deck size
    j_erosion = function(a)
        local missing = (G.GAME and G.GAME.starting_deck_size or 52)
            - (G.playing_cards and #G.playing_cards or 52)
        return { mult = at_least_zero(a.extra * missing) }
    end,
    -- +Mult per Tarot used this run
    j_fortune_teller = function(a)
        return { mult = (G.GAME and G.GAME.consumeable_usage_total
            and G.GAME.consumeable_usage_total.tarot) or 0 }
    end,
    -- +Chips per 9 in the deck
    j_cloud_9 = function(a)
        return { chips = a.extra * (a.nine_tally or 0) }
    end,
}

--- Live value for a joker that computes rather than stores, or nil.
local function dynamic_value(card, cat)
    local fn = DYNAMIC[card.config and card.config.center and card.config.center.key]
    if not fn or type(card.ability) ~= 'table' then return nil end
    local ok, values = pcall(fn, card.ability)
    if not ok or type(values) ~= 'table' then return nil end
    local v = values[cat.name]
    if v == nil then return nil end
    if type(v) ~= 'table' and (v == cat.neutral or v == 0) then return nil end
    return v
end

--- The card's own value for one category, ignoring its editions.
--- JokerDisplay (nh6574) computes condition-aware values per joker and stores
--- them on the card, so prefer those when it is installed. Then this mod's own
--- formulas for computed jokers, then the stored fields.
local function card_value(card, cat)
    local ability = card.ability
    return pick(JokerDisplay and card.joker_display_values, cat)
        or dynamic_value(card, cat)
        or pick(ability, cat)
        or pick(ability and ability.extra, cat)
end

--------------------------------------------------------------------------------
-- modifier extraction
--------------------------------------------------------------------------------

local function edition_lines(card, out)
    if not card.edition then return end
    local stack
    if StackedEditions then
        stack = StackedEditions.stack(card)
    else
        stack = { card.edition.key or ('e_' .. (card.edition.type or '')) }
    end
    local counts, order = {}, {}
    for _, key in ipairs(stack) do
        if not counts[key] then
            order[#order + 1] = key
            counts[key] = 0
        end
        counts[key] = counts[key] + 1
    end
    for _, key in ipairs(order) do
        local label = label_of(key:sub(3))
        if counts[key] > 1 then label = counts[key] .. 'X ' .. label end

        -- spell out what the edition actually gives (Foil +50, 2X Polychrome X2.25),
        -- taken from the edition's own config so modded editions work too
        local config = (G.P_CENTERS[key] or {}).config
        for _, cat in ipairs(CATEGORIES) do
            local v = pick(config, cat)
            if v then
                if cat.neutral == 1 then
                    local base = v
                    for _ = 2, counts[key] do v = v * base end
                else
                    v = v * counts[key]
                end
                label = label .. ' ' .. cat.prefix .. fmt(v)
                break
            end
        end

        -- DARK_EDITION is black, unreadable on the panel; EDITION is white
        out[#out + 1] = { text = label, colour = G.C.EDITION }
    end
end

local function sticker_lines(card, out)
    local handled = {}
    for _, key in ipairs(SMODS.Sticker and SMODS.Sticker.obj_buffer or {}) do
        if card.ability[key] then
            handled[key] = true
            local label = label_of(key)
            if key == 'perishable' and card.ability.perish_tally then
                label = label .. ' (' .. card.ability.perish_tally .. ')'
            end
            out[#out + 1] = { text = label, colour = G.C.FILTER }
        end
    end
    -- vanilla fallback if the sticker registry is unavailable
    for _, key in ipairs({ 'eternal', 'perishable', 'rental' }) do
        if card.ability[key] and not handled[key] then
            out[#out + 1] = { text = label_of(key), colour = G.C.FILTER }
        end
    end
    if card.pinned then
        out[#out + 1] = { text = label_of('pinned_left'), colour = G.C.FILTER }
    end
    if card.debuff then
        out[#out + 1] = { text = L('jrinfo_debuffed', 'Debuffed'), colour = G.C.RED }
    end
end

--- The joker's own contribution, editions excluded (they get their own lines).
--- XMult first, since that is what matters most at a glance.
local function value_line(card, out)
    local order = { 'x_mult', 'x_chips', 'mult', 'chips' }
    for _, name in ipairs(order) do
        for _, cat in ipairs(CATEGORIES) do
            if cat.name == name then
                local v = card_value(card, cat)
                if v then
                    out[#out + 1] = {
                        text = cat.prefix .. fmt(v) .. ' ' .. L(cat.label, cat.name == 'chips' and 'Chips' or 'Mult'),
                        colour = G.C[cat.colour],
                    }
                    return
                end
            end
        end
    end
    local dollars = card.ability and card.ability.dollars
    if dollars and (type(dollars) == 'table' or dollars ~= 0) then
        out[#out + 1] = { text = '$' .. fmt(dollars), colour = G.C.MONEY }
    end
end

--- Every modifier line for one joker, most important first.
function JRI.modifiers(card)
    local out = {}
    edition_lines(card, out)
    sticker_lines(card, out)
    value_line(card, out)
    return out
end

--- Summed chips / mult and multiplied XMult across the given jokers.
--- These are the values the cards currently hold, so conditional jokers are
--- counted even when their condition is not met -- an upper bound on what the
--- board adds, not a prediction of the next hand. Jokers whose value is only
--- computed at score time (Baseball Card, Bull, Supernova) contribute nothing.
function JRI.totals(jokers)
    local t = { chips = 0, mult = 0, x_mult = 1, x_chips = 1 }
    for _, joker in ipairs(jokers) do
        if not joker.debuff then
            for _, cat in ipairs(CATEGORIES) do
                local v = card_value(joker, cat)
                if v then
                    if cat.neutral == 1 then t[cat.name] = t[cat.name] * v else t[cat.name] = t[cat.name] + v end
                end
                local ev = pick(joker.edition, cat)
                if ev then
                    if cat.neutral == 1 then t[cat.name] = t[cat.name] * ev else t[cat.name] = t[cat.name] + ev end
                end
            end
        end
    end
    return t
end

local function total_parts(t)
    local out = {}
    local function nonzero(v, neutral)
        if v == nil then return false end
        if type(v) == 'table' then return true end
        return v ~= neutral
    end
    if nonzero(t.chips, 0) then
        out[#out + 1] = { text = '+' .. fmt(t.chips) .. ' ' .. L('k_chips', 'Chips'), colour = G.C.CHIPS }
    end
    if nonzero(t.mult, 0) then
        out[#out + 1] = { text = '+' .. fmt(t.mult) .. ' ' .. L('k_mult', 'Mult'), colour = G.C.RED }
    end
    if nonzero(t.x_mult, 1) then
        out[#out + 1] = { text = 'X' .. fmt(t.x_mult) .. ' ' .. L('k_mult', 'Mult'), colour = G.C.RED }
    end
    if nonzero(t.x_chips, 1) then
        out[#out + 1] = { text = 'X' .. fmt(t.x_chips) .. ' ' .. L('k_chips', 'Chips'), colour = G.C.CHIPS }
    end
    return out
end

--------------------------------------------------------------------------------
-- tab UI
--------------------------------------------------------------------------------

local function text_row(line, scale)
    return { n = G.UIT.R, config = { align = 'cm' }, nodes = {
        { n = G.UIT.T, config = { text = line.text, scale = scale, colour = line.colour or G.C.UI.TEXT_LIGHT } },
    } }
end

--------------------------------------------------------------------------------
-- reordering
--------------------------------------------------------------------------------

--- Swap the joker at `index` with its neighbour in direction `dir` (-1 / 1).
--- Joker order lives in G.jokers.cards; align_cards() recomputes each card's x
--- from its new index before it re-sorts by x (cardarea.lua:509), so swapping
--- the table entries and realigning is all that is needed. Returns the joker's
--- new index, or nil if the move was not possible.
function JRI.move(index, dir)
    local cards = G.jokers and G.jokers.cards
    if not cards then return nil end
    local target = index + dir
    if not cards[index] or not cards[target] then return nil end

    cards[index], cards[target] = cards[target], cards[index]
    G.jokers:set_ranks()
    G.jokers:align_cards()
    return target
end

--- Write the visible order back into G.jokers, replacing the page's slice.
local function apply_page_order(order)
    local jokers = G.jokers and G.jokers.cards
    if not jokers then return false end
    local first = JRI.page_first or 1
    -- guards against acting on copies from an already-rebuilt page
    if #order ~= (JRI.page_count or #order) then return false end

    -- the new order must be a permutation of exactly the jokers on this page
    local slice = {}
    for i = first, first + #order - 1 do
        if not jokers[i] then return false end
        slice[jokers[i]] = true
    end
    for _, joker in ipairs(order) do
        if not slice[joker] then return false end
    end

    local changed = false
    for k, joker in ipairs(order) do
        if jokers[first + k - 1] ~= joker then changed = true end
        jokers[first + k - 1] = joker
    end
    if not changed then return false end

    G.jokers:set_ranks()
    G.jokers:align_cards()
    play_sound('cardSlide1', 1, 0.4)
    JRI.rebuild(true)
    return true
end

--- A quiet riffle tick, played when cards shift to make room for a dragged card.
--- Same sound the drop uses, lower and softer, rate limited so waving a card
--- around does not machine-gun it.
function JRI.riffle(slot)
    local now = (G.TIMERS and G.TIMERS.REAL) or 0
    if JRI.last_tick and now - JRI.last_tick < 0.05 then return end
    JRI.last_tick = now
    -- pitch derived from the slot, so sweeping across a row sounds like a riffle
    play_sound('cardSlide1', 0.85 + 0.04 * ((slot or 1) % 5), 0.18)
end

--- The copy currently being dragged, if any.
function JRI.dragged_copy()
    local target = G.CONTROLLER and G.CONTROLLER.dragging and G.CONTROLLER.dragging.target
    if target and target.jrinfo_source and target.states.drag.is then return target end
end

--- Which slot of `area` a card's x lands on (1 .. slots+1).
--- Derived from the slot pitch rather than from the other cards' positions, so it
--- does not wobble as they move out of the way.
function JRI.slot_at(area, card, card_w)
    local offset = (card.T.x + card.T.w / 2) - area.T.x
    local slot = math.floor(offset / card_w) + 1
    local count = #area.cards
    for _, other in ipairs(area.cards) do
        if other.states.drag.is then count = count - 1 end
    end
    return math.max(1, math.min(slot, count + 1))
end

--- Same, but nil when the card is nowhere near this row vertically.
function JRI.slot_over(area, card, card_w)
    local card_y = card.T.y + card.T.h / 2
    if card_y < area.T.y - area.T.h * 0.6 or card_y > area.T.y + area.T.h * 1.6 then
        return nil
    end
    return JRI.slot_at(area, card, card_w)
end

--- Resolve a dropped card into a new page order.
--- A card can only ever belong to the CardArea it was emplaced in, so dragging
--- between rows is resolved here instead: the target row is the one whose centre
--- is closest vertically to where the card was let go, and the insertion index
--- comes from its x against the other cards in that row.
function JRI.drop(dragged)
    local rows_of_cards, areas = {}, {}
    for _, area in ipairs(JRI.areas or {}) do
        if area.jrinfo_drag then areas[#areas + 1] = area end
    end
    if #areas == 0 then return false end
    table.sort(areas, function(a, b) return a.T.y < b.T.y end)

    -- each row without the dragged card; align_cards already x-sorted them
    for ri, area in ipairs(areas) do
        rows_of_cards[ri] = {}
        for _, card in ipairs(area.cards) do
            if card ~= dragged then
                rows_of_cards[ri][#rows_of_cards[ri] + 1] = card
            end
        end
    end

    local card_y = dragged.T.y + dragged.T.h / 2
    local target, best = 1, nil
    for ri, area in ipairs(areas) do
        local dist = math.abs((area.T.y + area.T.h / 2) - card_y)
        if not best or dist < best then best, target = dist, ri end
    end

    -- same slot maths the preview gap uses, so the card lands where it looked like
    local area = areas[target]
    local index = JRI.slot_at(area, dragged, area.config.card_w or G.CARD_W)
    index = math.max(1, math.min(index, #rows_of_cards[target] + 1))
    table.insert(rows_of_cards[target], index, dragged)

    local order = {}
    for _, row in ipairs(rows_of_cards) do
        for _, card in ipairs(row) do
            if card.jrinfo_source then order[#order + 1] = card.jrinfo_source end
        end
    end
    return apply_page_order(order)
end

-- Node:stop_drag (engine/node.lua:254) is what the controller calls when the
-- cursor is released, whether or not anything was dropped on a valid target.
local card_stop_drag_ref = Card.stop_drag
function Card:stop_drag()
    if card_stop_drag_ref then card_stop_drag_ref(self) end
    if self.jrinfo_source and self.area and self.area.jrinfo_drag then
        JRI.drop(self)
    end
end

local function arrow_button(index, dir, enabled)
    local label = dir < 0 and '<' or '>'
    if not enabled then
        return { n = G.UIT.C, config = { align = 'cm', minw = 0.36, minh = 0.32, r = 0.08,
            colour = G.C.UI.BACKGROUND_INACTIVE }, nodes = {
            { n = G.UIT.T, config = { text = label, scale = 0.3, colour = G.C.UI.TEXT_INACTIVE } },
        } }
    end
    return { n = G.UIT.C, config = {
        align = 'cm', minw = 0.36, minh = 0.32, r = 0.08,
        colour = G.C.RED, hover = true, shadow = true, button = 'jrinfo_move',
        ref_table = { index = index, dir = dir },
        focus_args = { type = 'none' },
    }, nodes = {
        { n = G.UIT.T, config = { text = label, scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
    } }
end

--- One column: the joker's sprite in its own CardArea plus its modifier lines.
--- CardArea:align_cards() positions cards from self.card_w, which defaults to
--- the unscaled G.CARD_W (cardarea.lua:14) -- leaving it alone shifts a scaled
--- card right by 0.5*G.CARD_W*(1-scale). Pass the real width instead.
--- type 'title_2' is invisible (no frame, no x/y counter) and centres a single
--- card inside its area, which is how vanilla builds its own joker grids.
local function make_copy(joker, scale, silent)
    local copy = copy_card(joker, nil, scale, nil, false)
    copy.sticker = joker.sticker
    copy.sticker_run = joker.sticker_run
    copy.jrinfo_source = joker
    if JRI.instant then
        -- rebuilt after a move: appear in place, no materialise animation
        copy.states.visible = true
    else
        copy:start_materialize(nil, silent)
    end
    return copy
end

--- The modifier lines under one joker, capped at MAX_LINES.
local function modifier_nodes(joker)
    local nodes = {}
    local lines = JRI.modifiers(joker)
    for i = 1, math.min(#lines, MAX_LINES) do
        nodes[#nodes + 1] = text_row(lines[i], 0.26)
    end
    if #lines > MAX_LINES then
        nodes[#nodes + 1] = text_row({
            text = string.format(L('jrinfo_more', '+%s more'), #lines - MAX_LINES),
            colour = G.C.UI.TEXT_INACTIVE,
        }, 0.24)
    end
    return nodes
end

--- One row of jokers: a single shared CardArea holding this row's cards, with a
--- matching row of text columns underneath.
---
--- All the cards of a row live in ONE CardArea because that is the only way a
--- card can be dragged: align_cards() recomputes each card's x from its index
--- and then re-sorts the area by x (cardarea.lua:509-528), which is exactly what
--- reorders jokers on the board. Dragging across rows is handled in JRI.drop.
local function joker_row(jokers, first, last, scale, silent, show_arrows)
    local card_w, card_h = G.CARD_W * scale, G.CARD_H * scale
    local count = last - first + 1

    -- the row is always PER_ROW slots wide, so a half-full row keeps the same
    -- slot positions as a full one instead of bunching up in the middle
    local area = CardArea(
        G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h,
        card_w * PER_ROW, card_h,
        {
            card_limit = PER_ROW, type = 'title_2', highlight_limit = 0,
            collection = true, card_w = card_w,
        }
    )
    area.jrinfo_drag = true
    JRI.areas[#JRI.areas + 1] = area

    -- Vanilla's alignment either spreads the cards over the full width or centres
    -- the group (cardarea.lua:509-528), and it adds a per-card tilt. Neither keeps
    -- cards on fixed slots, so this area places them itself: slot k, no tilt.
    --
    -- It also opens a gap while a card is dragged over the row, and closes the one
    -- the dragged card left behind, so both rows react during a cross-row drag.
    -- The x-sort at the end is what makes dragging reorder a row.
    area.align_cards = function(self)
        local drag = JRI.dragged_copy()

        -- the dragged card holds no slot: its own row closes up, and whichever row
        -- the cursor is over opens a gap where the card would land
        local visible = 0
        for _, card in ipairs(self.cards) do
            if not card.states.drag.is then visible = visible + 1 end
        end
        local gap = drag and JRI.slot_over(self, drag, card_w) or nil

        -- cards only shift when the gap appears or moves, so that is when the
        -- riffle tick plays
        if gap ~= self.jrinfo_gap then
            if gap then JRI.riffle(gap) end
            self.jrinfo_gap = gap
        end

        -- a full row plus a gap is one slot too wide for the box, so the pitch
        -- tightens just enough to keep every card inside it: it has to fit
        -- (slots - 1) steps plus one full card width
        local slots = visible + (gap and 1 or 0)
        local pitch = math.min(card_w, (self.T.w - card_w) / math.max(slots - 1, 1))

        local pending = gap
        local slot = 0
        for _, card in ipairs(self.cards) do
            if not card.states.drag.is then
                slot = slot + 1
                if pending and slot >= pending then slot = slot + 1; pending = nil end
                card.T.x = self.T.x + (slot - 1) * pitch
                card.T.y = self.T.y + 0.5 * (self.T.h - card.T.h)
                card.T.r = 0
            end
        end

        table.sort(self.cards, function(a, b)
            return a.T.x + a.T.w / 2 < b.T.x + b.T.w / 2
        end)
    end

    local columns = {}
    for i = first, last do
        area:emplace(make_copy(jokers[i], scale, silent))
        silent = true

        local nodes = {}
        if show_arrows then
            nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
                arrow_button(i, -1, i > 1),
                { n = G.UIT.C, config = { align = 'cm', minw = 0.22 }, nodes = {
                    { n = G.UIT.T, config = { text = tostring(i), scale = 0.22, colour = G.C.UI.TEXT_INACTIVE } },
                } },
                arrow_button(i, 1, i < #jokers),
            } }
        end
        for _, node in ipairs(modifier_nodes(jokers[i])) do nodes[#nodes + 1] = node end

        -- maxw makes the engine scale the column's contents down to fit instead of
        -- widening the column (engine/ui.lua:165-170). Without it a long line such
        -- as "2X Holographic +20" pushes every following column out of line with
        -- the card slots above.
        columns[#columns + 1] = { n = G.UIT.C,
            config = { align = 'tm', padding = 0.01, minw = card_w, maxw = card_w },
            nodes = nodes }
    end
    -- empty slots keep the text columns under the right cards
    for _ = count + 1, PER_ROW do
        columns[#columns + 1] = { n = G.UIT.C,
            config = { align = 'tm', padding = 0.01, minw = card_w, maxw = card_w },
            nodes = {} }
    end

    return {
        { n = G.UIT.R, config = { align = 'cl' }, nodes = {
            { n = G.UIT.O, config = { object = area } },
        } },
        { n = G.UIT.R, config = { align = 'tl', padding = 0.02, no_fill = true }, nodes = columns },
    }, silent
end

function JRI.tab()
    JRI.areas = {}
    local jokers = (G.jokers and G.jokers.cards) or {}

    if #jokers == 0 then
        return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR, minh = 4, minw = 8 }, nodes = {
            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                { n = G.UIT.O, config = { object = DynaText({
                    string = { L('jrinfo_none', 'No Jokers') },
                    colours = { G.C.UI.TEXT_LIGHT },
                    bump = true,
                    scale = 0.6,
                }) } },
            } },
        } }
    end

    local pages = math.max(1, math.ceil(#jokers / PER_PAGE))
    if JRI.page > pages or JRI.page < 1 then JRI.page = 1 end
    local first = (JRI.page - 1) * PER_PAGE + 1
    local last = math.min(#jokers, first + PER_PAGE - 1)
    JRI.page_first = first
    JRI.page_count = last - first + 1

    -- rows of PER_ROW jokers, each row draggable; arrows only stay around when
    -- there are pages, since dragging cannot cross a page boundary
    local rows = {}
    local silent = false
    for row_first = first, last, PER_ROW do
        local row_last = math.min(last, row_first + PER_ROW - 1)
        local nodes
        nodes, silent = joker_row(jokers, row_first, row_last, CARD_SCALE, silent, pages > 1)
        for _, node in ipairs(nodes) do rows[#rows + 1] = node end
    end

    -- card_limit already includes slots granted by Negative editions
    local slots = ('%s: %s/%s'):format(L('jrinfo_slots', 'Slots'), #jokers, G.jokers.config.card_limit)

    local page_cycle = nil
    if pages > 1 then
        local options = {}
        for i = 1, pages do
            options[i] = L('k_page', 'Page') .. ' ' .. i .. '/' .. pages
        end
        page_cycle = create_option_cycle({
            options = options,
            current_option = JRI.page,
            w = 4.5,
            scale = 0.8,
            opt_callback = 'jrinfo_page',
            colour = G.C.RED,
            no_pips = true,
            -- no cycle_shoulders: run_info's tab strip already owns the shoulder buttons
            focus_args = { snap_to = true, nav = 'wide' },
        })
    end

    -- totals across the whole board, not just the visible page
    local total_nodes = {
        { n = G.UIT.T, config = {
            text = L('jrinfo_totals', 'Total') .. ':',
            scale = 0.42,
            colour = G.C.UI.TEXT_LIGHT,
        } },
    }
    for _, part in ipairs(total_parts(JRI.totals(jokers))) do
        total_nodes[#total_nodes + 1] = { n = G.UIT.C, config = { align = 'cm', minw = 0.18 }, nodes = {} }
        total_nodes[#total_nodes + 1] = { n = G.UIT.T, config = {
            text = part.text, scale = 0.42, colour = part.colour,
        } }
    end
    total_nodes[#total_nodes + 1] = { n = G.UIT.C, config = { align = 'cm', minw = 0.25 }, nodes = {} }
    total_nodes[#total_nodes + 1] = { n = G.UIT.T, config = {
        text = L('jrinfo_totals_note', '(ignores conditions)'),
        scale = 0.28,
        colour = G.C.UI.TEXT_INACTIVE,
    } }

    return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR, padding = 0.1 }, nodes = {
        { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
            { n = G.UIT.T, config = { text = slots, scale = 0.45, colour = G.C.UI.TEXT_LIGHT } },
            { n = G.UIT.C, config = { align = 'cm', minw = 0.3 }, nodes = {} },
            { n = G.UIT.T, config = {
                text = pages > 1
                    and L('jrinfo_drag_hint_pages', 'drag to reorder, < > to move across pages')
                    or L('jrinfo_drag_hint', 'drag cards to reorder'),
                scale = 0.3,
                colour = G.C.UI.TEXT_INACTIVE,
            } },
        } },
        { n = G.UIT.R, config = { align = 'cm', colour = G.C.BLACK, r = 0.1, padding = 0.1, emboss = 0.05 }, nodes = {
            { n = G.UIT.R, config = { align = 'cm' }, nodes = rows },
            { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = total_nodes },
        } },
        page_cycle and { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { page_cycle } } or nil,
    } }
end

--- Rebuild the tab body in place. create_tabs stores the active tab's UIBox on
--- the UIE with id 'tab_contents' (UI_definitions.lua), and G.FUNCS.change_tab
--- swaps it exactly like this. Removing the old UIBox also removes the CardAreas
--- and card copies it held (UIElement:remove -> config.object:remove).
--- The buttons that trigger a rebuild live inside the UIBox being replaced, so
--- the swap is deferred by one event tick: UIElement:click() keeps touching the
--- clicked element after the callback returns (engine/ui.lua:989-995).
--- `instant` skips the materialise animation on the new copies, so reordering
--- does not make every card pop in again.
function JRI.rebuild(instant)
    if JRI.rebuilding or JRI.rebuild_queued then return end
    JRI.rebuild_queued = true

    G.E_MANAGER:add_event(Event({
        trigger = 'immediate',
        blocking = false,
        blockable = false,
        -- Run Info pauses the game; without this the event would be pause-skipped
        -- (engine/event.lua:50) if it was queued while unpaused.
        pause_force = true,
        func = function()
            JRI.rebuild_queued = nil
            local tab_contents = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID('tab_contents')
            if not tab_contents then return true end

            JRI.rebuilding = true
            JRI.instant = instant or nil
            if tab_contents.config.object then tab_contents.config.object:remove() end
            tab_contents.config.object = UIBox({
                definition = JRI.tab(),
                config = { offset = { x = 0, y = 0 }, parent = tab_contents, type = 'cm' },
            })
            tab_contents.UIBox:recalculate()
            JRI.instant = nil
            JRI.rebuilding = false
            return true
        end,
    }))
end

--- Page cycle callback.
G.FUNCS.jrinfo_page = function(args)
    if not args or not args.cycle_config or JRI.rebuilding then return end
    if args.cycle_config.current_option == JRI.page then return end
    JRI.page = args.cycle_config.current_option
    JRI.rebuild()
end

--- Arrow button callback: move a joker one slot and follow it across pages.
G.FUNCS.jrinfo_move = function(e)
    if JRI.rebuilding then return end
    local ref = e and e.config and e.config.ref_table
    if not ref then return end

    local new_index = JRI.move(ref.index, ref.dir)
    if not new_index then return end

    JRI.page = math.floor((new_index - 1) / PER_PAGE) + 1
    play_sound('cardSlide1', 1, 0.4)
    JRI.rebuild(true)
end

--------------------------------------------------------------------------------
-- inject the tab into Run Info
--------------------------------------------------------------------------------

local create_tabs_ref = create_tabs
function create_tabs(args)
    if JRI.injecting and type(args) == 'table' and type(args.tabs) == 'table' then
        -- only the outermost tab set of run_info gets the extra tab; a tab
        -- definition function that builds nested tabs must not inherit it
        JRI.injecting = false
        args.tabs[#args.tabs + 1] = {
            label = L('jrinfo_tab', 'Jokers'),
            tab_definition_function = JRI.tab,
        }
    end
    return create_tabs_ref(args)
end

local run_info_ref = G.UIDEF.run_info
function G.UIDEF.run_info(...)
    JRI.injecting = true
    JRI.page = 1
    local ok, ret = pcall(run_info_ref, ...)
    JRI.injecting = false
    if not ok then error(ret) end
    return ret
end
