import LeanHttp.Wire.Correctness

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

theorem scanHeader_lower (bytes : ByteArray) (i : Nat) (boundary : HeaderBoundary bytes)
    (found : scanHeader bytes i = .ok (some boundary)) : i + 4 <= boundary.endPos := by
  rw [scanHeader] at found
  simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos] at found
  split at found
  next within =>
    simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at found
    split at found
    next invalid => cases found
    next noLF =>
      split at found
      next invalid => cases found
      next noCR =>
        split at found
        next invalid => cases found
        next clean =>
          split at found
          next delimiter =>
            cases Option.some.inj (Except.ok.inj found)
            simp
          next missing =>
            have later := scanHeader_lower bytes (i + 1) boundary found
            omega
  next exhausted => cases found
termination_by bytes.size - i

private theorem prefix_byte (bytes : ByteArray) (cut i : Nat) (within : i < min cut bytes.size) :
    (bytes.extract 0 cut)[i]! = bytes[i]! := by
  have small : i < (bytes.extract 0 cut).size := by simpa using within
  rw [getElem!_pos (bytes.extract 0 cut) i small, ByteArray.getElem_extract]
  simp only [Nat.zero_add]
  rw [getElem!_pos bytes i (by omega)]

private theorem scanHeader_partial_delimiter (bytes : ByteArray) (i : Nat)
    (short : bytes.size < i + 4)
    (cr : i < bytes.size → bytes[i]! = 13)
    (lf : i + 1 < bytes.size → bytes[i + 1]! = 10)
    (cr' : i + 2 < bytes.size → bytes[i + 2]! = 13) :
    scanHeader bytes i = .ok none := by
  by_cases first : i < bytes.size
  · by_cases second : i + 1 < bytes.size
    · rw [scanHeader]
      simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
      simp only [first, ↓reduceDIte, cr first, lf second]
      simp [second, show ¬i + 3 < bytes.size by omega]
      rw [scanHeader]
      simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
      simp only [second, ↓reduceDIte, lf second, show i + 1 - 1 = i by omega, cr first]
      simp
      by_cases third : i + 2 < bytes.size
      · rw [scanHeader]
        simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
        simp only [show i + 1 + 1 = i + 2 by omega, third, ↓reduceDIte, cr' third]
        simp [show ¬i + 2 + 1 < bytes.size by omega, show ¬i + 2 + 3 < bytes.size by omega]
        rw [scanHeader]
        simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
        simp [show ¬i + 2 + 1 < bytes.size by omega, Pure.pure, Except.pure]
      · rw [scanHeader]
        simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
        simp [show ¬i + 1 + 1 < bytes.size by omega, Pure.pure, Except.pure]
    · rw [scanHeader]
      simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
      simp only [first, ↓reduceDIte, cr first]
      simp [second, show ¬i + 3 < bytes.size by omega]
      rw [scanHeader]
      simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
      simp [second, Pure.pure, Except.pure]
  · rw [scanHeader]
    simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
    simp [first, Pure.pure, Except.pure]

theorem scanHeader_agrees (bytes other : ByteArray) (i : Nat) (boundary : HeaderBoundary bytes)
    (same : ∀ j, j < bytes.size → j < other.size → other[j]! = bytes[j]!)
    (found : scanHeader bytes i = .ok (some boundary)) :
    ∃ result, scanHeader other i = .ok result ∧
      match result with
      | none => other.size < boundary.endPos
      | some next => next.endPos = boundary.endPos := by
  have lower := scanHeader_lower bytes i boundary found
  have upper := boundary.upper
  by_cases withinOther : i < other.size
  · have current := same i (by omega) withinOther
    have lfSame : (other[i]! == 10 && (i == 0 || other[i - 1]! != 13)) =
        (bytes[i]! == 10 && (i == 0 || bytes[i - 1]! != 13)) := by
      rw [current]
      by_cases zero : i = 0
      · simp [zero]
      · rw [same (i - 1) (by omega) (by omega)]
    have crSame : (other[i]! == 13 && i + 1 < other.size && other[i + 1]! != 10) =
        false ∨ (other[i]! == 13 && i + 1 < other.size && other[i + 1]! != 10) =
          (bytes[i]! == 13 && i + 1 < bytes.size && bytes[i + 1]! != 10) := by
      by_cases next : i + 1 < other.size
      · right
        rw [current, same (i + 1) (by omega) next]
        simp only [next, show i + 1 < bytes.size by omega]
      · left; simp [next]
    rw [scanHeader] at found
    simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos] at found
    split at found
    next within =>
      simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at found
      split at found
      next invalid => cases found
      next noLF =>
        split at found
        next invalid => cases found
        next noCR =>
          split at found
          next invalid => cases found
          next clean =>
            have noLFOther : ¬(other[i]! == 10 && (i == 0 || other[i - 1]! != 13)) = true := by
              rwa [lfSame]
            have noCROther : ¬(other[i]! == 13 && i + 1 < other.size && other[i + 1]! != 10) = true := by
              rcases crSame with absent | equal
              · simp [absent]
              · rwa [equal]
            have cleanOther : ¬((other[i]! < 32 && other[i]! != 9 && other[i]! != 10 &&
                other[i]! != 13) || other[i]! == 127) = true := by rwa [current]
            split at found
            next delimiter =>
              have facts : bytes[i]! = 13 ∧ bytes[i + 1]! = 10 ∧ bytes[i + 2]! = 13 ∧
                  bytes[i + 3]! = 10 := by
                simpa only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq,
                  show i + 3 < bytes.size by omega, true_and, and_assoc] using delimiter
              cases Option.some.inj (Except.ok.inj found)
              by_cases enough : i + 3 < other.size
              · have first := (same i (by omega) withinOther).trans facts.1
                have second := (same (i + 1) (by omega) (by omega)).trans facts.2.1
                have third := (same (i + 2) (by omega) (by omega)).trans facts.2.2.1
                have fourth := (same (i + 3) (by omega) enough).trans facts.2.2.2
                have foundOther : (other[i]! == 13 && i + 3 < other.size && other[i + 1]! == 10 &&
                    other[i + 2]! == 13 && other[i + 3]! == 10) = true := by
                  simp only [first, second, third, fourth, enough]; decide
                rw [scanHeader]
                simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
                simp only [withinOther, ↓reduceDIte, noLFOther, noCROther, cleanOther,
                  foundOther, Bind.bind, Except.bind, Pure.pure, Except.pure]
                exact ⟨_, rfl, rfl⟩
              · refine ⟨none, ?_, by dsimp; omega⟩
                exact scanHeader_partial_delimiter other i (by omega)
                  (fun h => (same i (by omega) h).trans facts.1)
                  (fun h => (same (i + 1) (by omega) h).trans facts.2.1)
                  (fun h => (same (i + 2) (by omega) h).trans facts.2.2.1)
            next missing =>
              have missingOther : ¬(other[i]! == 13 && i + 3 < other.size && other[i + 1]! == 10 &&
                  other[i + 2]! == 13 && other[i + 3]! == 10) = true := by
                by_cases enough : i + 3 < other.size
                · rw [current, same (i + 1) (by omega) (by omega),
                    same (i + 2) (by omega) (by omega), same (i + 3) (by omega) enough]
                  simpa only [enough, show i + 3 < bytes.size by omega] using missing
                · simp [enough]
              obtain ⟨result, parsed, relation⟩ := scanHeader_agrees bytes other (i + 1) boundary same found
              refine ⟨result, ?_, relation⟩
              rw [scanHeader]
              simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
              simpa only [withinOther, ↓reduceDIte, noLFOther, noCROther, cleanOther,
                missingOther, Bool.false_eq_true, ↓reduceIte, Bind.bind, Except.bind] using parsed
    next exhausted => cases found
  · refine ⟨none, ?_, by omega⟩
    rw [scanHeader]
    simp only [nextIsNotLF_eq, delimiterTail_eq, ← Bool.and_assoc, ← getElem!_pos]
    simp [withinOther, Pure.pure, Except.pure]
termination_by bytes.size - i

theorem parse_frame (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : Wire.parse bytes limit = .ok (some request)) :
    bytes.size <= limit ∧ ∃ (boundary : HeaderBoundary bytes) (header : String) (head : ParsedHead),
      headerEnd bytes = .ok (some boundary) ∧
      String.fromUTF8? (bytes.extract 0 (boundary.endPos - 4)) = some header ∧
      parseHead header (limit - boundary.endPos) = .ok head ∧
      bytes.size = boundary.endPos + head.length ∧
      bytes.extract boundary.endPos bytes.size = request.body.toUTF8 := by
  unfold Wire.parse at parsed
  simp only [extractWithin] at parsed
  simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
  split at parsed
  next large => cases parsed
  next fits =>
    refine ⟨by omega, ?_⟩
    split at parsed
    next error rejected => cases parsed
    next boundary boundaryOk =>
      split at parsed
      next boundary =>
        split at parsed
        next header headerOk =>
          split at parsed
          next error rejected => cases parsed
          next head headOk =>
            split at parsed
            next large => cases parsed
            next totalFits =>
              split at parsed
              next short => cases parsed
              next notShort =>
                split at parsed
                next trailing => cases parsed
                next notLong =>
                  split at parsed
                  next body bodyOk =>
                    split at parsed
                    next path parts splitEq =>
                      cases Option.some.inj (Except.ok.inj parsed)
                      have exactSize : bytes.size = boundary.endPos + head.length := by omega
                      refine ⟨boundary, header, head, boundaryOk, headerOk, headOk, exactSize, ?_⟩
                      simpa only [exactSize] using ((fromUTF8_eq_some _ _).mp bodyOk).symm
                    next missing => cases parsed
                  next invalid => cases parsed
        next invalid => cases parsed
      next missing => split at parsed <;> cases parsed

end LeanHttp.Wire.Internal

namespace LeanHttp.Wire

open Internal

/-- Every proper byte prefix of a successfully parsed request needs more input. -/
theorem parse_prefix (bytes : ByteArray) (limit : Nat) (request : Request) (cut : Nat)
    (parsed : parse bytes limit = .ok (some request)) (short : cut < bytes.size) :
    parse (bytes.extract 0 cut) limit = .ok none := by
  obtain ⟨fits, boundary, header, head, found, headerOk, headOk, exactSize, _⟩ :=
    parse_frame bytes limit request parsed
  have size : (bytes.extract 0 cut).size = cut := by simp; omega
  have prefixFits : ¬limit < (bytes.extract 0 cut).size := by omega
  obtain ⟨result, scanned, relation⟩ := scanHeader_agrees bytes (bytes.extract 0 cut) 0 boundary
    (fun j _ h => prefix_byte bytes cut j (by simpa using h)) found
  cases result with
  | none =>
    unfold parse
    simp only [extractWithin]
    rw [if_neg prefixFits]
    simp only [headerEnd, scanned, Bind.bind, Except.bind, size]
    simp [show cut ≠ limit by omega, Pure.pure, Except.pure]
  | some next =>
    have endEq : next.endPos = boundary.endPos := relation
    have nextUpper := next.upper
    have headerSame : (bytes.extract 0 cut).extract 0 (boundary.endPos - 4) =
        bytes.extract 0 (boundary.endPos - 4) := by
      rw [ByteArray.extract_extract]
      simp only [Nat.zero_add, Nat.min_eq_left (by omega : boundary.endPos - 4 <= cut)]
    unfold parse
    simp only [extractWithin]
    rw [if_neg prefixFits]
    simp only [headerEnd, scanned, Bind.bind, Except.bind, endEq]
    rw [headerSame, headerOk]
    simp only [headOk]
    simp only [show ¬limit < boundary.endPos + head.length by omega,
      show (bytes.extract 0 cut).size < boundary.endPos + head.length by omega,
      ↓reduceIte, ↓reduceDIte, Pure.pure, Except.pure]

/-- A nonempty suffix already in the buffer is rejected, with overflow taking precedence. -/
theorem parse_append (bytes extra : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) (nonempty : extra.size > 0) :
    parse (bytes ++ extra) limit =
      if (bytes ++ extra).size > limit then .error tooLarge
      else .error (bad "Trailing bytes after request") := by
  obtain ⟨fits, boundary, header, head, found, headerOk, headOk, exactSize, _⟩ :=
    parse_frame bytes limit request parsed
  have size : (bytes ++ extra).size = bytes.size + extra.size := ByteArray.size_append
  have upper := boundary.upper
  obtain ⟨result, scanned, relation⟩ := scanHeader_agrees bytes (bytes ++ extra) 0 boundary
    (by
      intro j small large
      rw [getElem!_pos (bytes ++ extra) j large, ByteArray.getElem_append_left small,
        getElem!_pos bytes j small]) found
  cases result with
  | none => simp only at relation; omega
  | some next =>
    have endEq : next.endPos = boundary.endPos := relation
    have headerSame : (bytes ++ extra).extract 0 (boundary.endPos - 4) =
        bytes.extract 0 (boundary.endPos - 4) := by
      rw [ByteArray.extract_append]
      simp [Nat.sub_eq_zero_of_le (by omega : boundary.endPos - 4 <= bytes.size)]
    unfold parse
    simp only [extractWithin]
    by_cases overflow : limit < (bytes ++ extra).size
    · simp only [overflow, ↓reduceIte]
      rfl
    · rw [if_neg overflow, if_neg overflow]
      simp only [headerEnd, scanned, Bind.bind, Except.bind, endEq]
      rw [headerSame, headerOk]
      simp only [headOk]
      simp only [show ¬limit < boundary.endPos + head.length by omega,
        show ¬(bytes ++ extra).size < boundary.endPos + head.length by omega,
        show boundary.endPos + head.length < (bytes ++ extra).size by omega,
        ↓reduceIte]
      rfl

/-- The scanner's boundary leaves exactly the decoded body's UTF-8 bytes. -/
theorem parse_body_boundary (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) :
    ∃ boundary : HeaderBoundary bytes, headerEnd bytes = .ok (some boundary) ∧
      bytes.size = boundary.endPos + request.body.toUTF8.size ∧
      bytes.extract boundary.endPos bytes.size = request.body.toUTF8 := by
  obtain ⟨_, boundary, _, _, found, _, _, _, source⟩ := parse_frame bytes limit request parsed
  refine ⟨boundary, found, ?_, source⟩
  have size := congrArg ByteArray.size source
  simp only [ByteArray.size_extract, Nat.min_self] at size
  have upper := boundary.upper
  omega

/-- Missing and explicit zero lengths remain distinct in the decoded headers. -/
theorem parse_contentLength (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) :
    let lengths := request.headers.filter (fun field => field.1 == "content-length")
    (lengths = [] ∧ request.body = "") ∨
      ∃ value, lengths = [("content-length", value)] ∧ Spec.digits value = true ∧
        Spec.decimal value = request.body.toUTF8.size := by
  obtain ⟨form, valid, _, rfl⟩ := parse_sound bytes limit request parsed
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  have framed := facts.1.1.2
  change (match lengthFields form.fields with
    | [] => form.body.isEmpty
    | [field] => Spec.digits field.value && Spec.decimal field.value == form.body.toUTF8.size
    | _ => false) = true at framed
  change (((form.fields.map (fun f => (Spec.asciiLower f.name, f.value))).filter
      (fun field => field.1 == "content-length")) = [] ∧ form.body = "") ∨ _
  rw [List.filter_map]
  change ((lengthFields form.fields).map (fun f => (Spec.asciiLower f.name, f.value)) = [] ∧
    form.body = "") ∨ _
  cases lengths : lengthFields form.fields with
  | nil =>
    rw [lengths] at framed
    exact Or.inl ⟨rfl, String.isEmpty_iff.mp framed⟩
  | cons field rest =>
    have member : field ∈ lengthFields form.fields := by rw [lengths]; simp
    have name : Spec.asciiLower field.name = "content-length" :=
      beq_iff_eq.mp (List.mem_filter.mp member).2
    cases rest with
    | nil =>
      rw [lengths] at framed
      have length : Spec.digits field.value = true ∧
          Spec.decimal field.value = form.body.toUTF8.size := by simpa using framed
      refine Or.inr ⟨field.value, ?_, length⟩
      change ((form.fields.map (fun f => (Spec.asciiLower f.name, f.value))).filter
        (fun field => field.1 == "content-length")) = _
      rw [List.filter_map]
      change (lengthFields form.fields).map (fun f => (Spec.asciiLower f.name, f.value)) = _
      rw [lengths]
      simp [name]
    | cons next rest => rw [lengths] at framed; contradiction

theorem parse_no_unsupported_fields (bytes : ByteArray) (limit : Nat) (request : Request)
    (parsed : parse bytes limit = .ok (some request)) :
    request.headers.all (fun field =>
      field.1 != "transfer-encoding" && field.1 != "expect") = true := by
  obtain ⟨form, valid, _, rfl⟩ := parse_sound bytes limit request parsed
  have facts := valid
  simp only [Spec.RequestForm.Valid, Spec.RequestForm.valid, Bool.and_eq_true] at facts
  simpa only [Spec.RequestForm.request, List.all_map, Function.comp_def] using facts.1.2

private theorem foldl_append_bytes (chunks : List ByteArray) (initial : ByteArray) :
    chunks.foldl (· ++ ·) initial = initial ++ chunks.foldl (· ++ ·) ByteArray.empty := by
  induction chunks generalizing initial with
  | nil => simp
  | cons chunk chunks ih =>
    simp only [List.foldl_cons]
    rw [ih (initial ++ chunk), ih (ByteArray.empty ++ chunk)]
    simp [ByteArray.append_assoc]

/-- Every chunk prefix waits until all request bytes are present, including empty chunks. -/
theorem parse_chunks (chunks : List ByteArray) (limit : Nat) (request : Request)
    (parsed : parse (chunks.foldl (· ++ ·) ByteArray.empty) limit = .ok (some request))
    (before after : List ByteArray) (split : chunks = before ++ after) :
    parse (before.foldl (· ++ ·) ByteArray.empty) limit =
      if (after.foldl (· ++ ·) ByteArray.empty).size = 0 then .ok (some request)
      else .ok none := by
  have joined : chunks.foldl (· ++ ·) ByteArray.empty =
      before.foldl (· ++ ·) ByteArray.empty ++ after.foldl (· ++ ·) ByteArray.empty := by
    rw [split, List.foldl_append, foldl_append_bytes]
  by_cases empty : (after.foldl (· ++ ·) ByteArray.empty).size = 0
  · have noBytes := ByteArray.size_eq_zero_iff.mp empty
    simpa only [joined, noBytes, ByteArray.append_empty, ByteArray.size_empty, ↓reduceIte] using parsed
  · rw [if_neg empty]
    have waiting := parse_prefix _ limit request (before.foldl (· ++ ·) ByteArray.empty).size
      parsed (by rw [joined, ByteArray.size_append]; omega)
    rwa [joined, ByteArray.extract_append_eq_left rfl] at waiting

end LeanHttp.Wire
