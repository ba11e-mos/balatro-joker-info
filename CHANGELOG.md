# Changelog

## 1.0.0

Initial release.

- Adds a Jokers tab to Run Info with every active Joker.
- Per Joker: editions (with counts when stacked), stickers, debuff state and the
  Joker's current value.
- Reorder Jokers from the info screen by dragging them, including between rows.
  Arrow buttons appear as well when the board is large enough to be paged.
- Board totals: summed Chips / Mult and multiplied XMult / XChips across every
  Joker, debuffed ones excluded. Jokers that derive their value from run state
  (Bootstraps, Bull, Stone Joker, Blue Joker, Steel Joker, Abstract Joker,
  Erosion, Fortune Teller, Cloud 9) are computed live with vanilla's own formulas.
- Reads JokerDisplay's condition-aware values when that mod is installed.
- Joker slot counter in the header, pagination for large boards.
