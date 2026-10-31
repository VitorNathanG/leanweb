import LeanHttp.Wire.Incremental

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

theorem extractWithin_size (bytes : ByteArray) (start stop : Nat)
    (ordered : start <= stop) (within : stop <= bytes.size) :
    (extractWithin bytes start stop ordered within).size = stop - start := by
  simp [extractWithin, Nat.min_eq_left within]

end LeanHttp.Wire.Internal

namespace LeanHttp.Wire

open Internal

/-- Aggregate overflow is rejected before inspecting the request's syntax. -/
theorem parse_oversized (bytes : ByteArray) (limit : Nat) (large : limit < bytes.size) :
    parse bytes limit = .error tooLarge := by
  unfold parse
  rw [if_pos large]
  rfl

theorem parse_le_limit (bytes : ByteArray) (limit : Nat) (result : Option Request)
    (parsed : parse bytes limit = .ok result) : bytes.size <= limit := by
  by_cases fits : bytes.size <= limit
  · exact fits
  · rw [parse_oversized bytes limit (by omega)] at parsed
    cases parsed

/-- Waiting always leaves a positive aggregate byte budget. -/
theorem parse_needMore_lt (bytes : ByteArray) (limit : Nat)
    (parsed : parse bytes limit = .ok none) : bytes.size < limit := by
  have fits := parse_le_limit bytes limit none parsed
  unfold parse at parsed
  simp only [extractWithin] at parsed
  simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
  split at parsed
  next large => cases parsed
  next within =>
    split at parsed
    next error rejected => cases parsed
    next boundary scanned =>
      split at parsed
      next boundary =>
        split at parsed
        next header decoded =>
          split at parsed
          next error rejected => cases parsed
          next head headOk =>
            split at parsed
            next large => cases parsed
            next totalFits =>
              split at parsed
              next short => omega
              next enough =>
                split at parsed
                next trailing => cases parsed
                next exact =>
                  split at parsed
                  next body decoded => split at parsed <;> cases parsed
                  next invalid => cases parsed
        next invalid => cases parsed
      next missing =>
        split at parsed
        next exhausted => cases parsed
        next room => simp only [beq_iff_eq] at room; omega

theorem parse_empty (limit : Nat) :
    parse ByteArray.empty limit = if limit = 0 then .error tooLarge else .ok none := by
  have emptyScan : headerEnd ByteArray.empty = .ok none := by
    unfold headerEnd
    rw [scanHeader]
    simp [Pure.pure, Except.pure]
  unfold parse
  rw [if_neg (by simp)]
  simp only [emptyScan, Bind.bind, Except.bind, ByteArray.size_empty]
  by_cases zero : limit = 0
  · subst limit; rfl
  · simp [zero, Ne.symm zero, Pure.pure, Except.pure]

/-- The decoded body fits the budget remaining after the actual header boundary. -/
theorem parse_body_budget (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) :
    ∃ boundary : HeaderBoundary bytes, headerEnd bytes = .ok (some boundary) ∧
      request.body.toUTF8.size = bytes.size - boundary.endPos ∧
      request.body.toUTF8.size <= limit - boundary.endPos := by
  have fits := parse_le_limit bytes limit (some request) parsed
  obtain ⟨boundary, found, size, _⟩ := parse_body_boundary bytes limit request parsed
  exact ⟨boundary, found, by omega, by omega⟩

end LeanHttp.Wire
