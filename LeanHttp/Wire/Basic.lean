import LeanHttp.Spec

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

def bad (message : String) : Response :=
  .text (message ++ "\n") .badRequest

def tooLarge : Response := .text "Request too large\n" .payloadTooLarge

def unsupported (message : String) : Response :=
  .text (message ++ "\n") .notImplemented

def asciiAlphaNum (c : Char) : Bool :=
  ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9')

def tokenChar (c : Char) : Bool :=
  asciiAlphaNum c || "!#$%&'*+-.^_`|~".contains c

def trimOWS (s : String) : String :=
  let space := fun c => c == ' ' || c == '\t'
  String.ofList ((s.toList.dropWhile space).reverse.dropWhile space).reverse

private def trimList (p : Char → Bool) (chars : List Char) : List Char :=
  ((chars.dropWhile p).reverse.dropWhile p).reverse

private theorem dropWhile_idempotent (p : Char → Bool) (chars : List Char) :
    (chars.dropWhile p).dropWhile p = chars.dropWhile p := by
  induction chars with
  | nil => simp
  | cons c cs ih =>
    by_cases accepted : p c = true <;> simp [accepted, ih]

private theorem dropWhile_append_last (p : Char → Bool) (chars : List Char) (c : Char)
    (last : p c = false) :
    (chars ++ [c]).dropWhile p = chars.dropWhile p ++ [c] := by
  by_cases empty : chars.dropWhile p = []
  · simp [List.dropWhile_append, empty, last]
  · simp [List.dropWhile_append, empty]

private theorem trimList_front (p : Char → Bool) (chars : List Char) :
    (trimList p chars).dropWhile p = trimList p chars := by
  induction chars with
  | nil => simp [trimList]
  | cons c cs ih =>
    by_cases accepted : p c = true
    · simpa [trimList, accepted] using ih
    · have mismatch : p c = false := by simpa using accepted
      simp [trimList, mismatch, List.reverse_cons, dropWhile_append_last,
        List.reverse_append]

private theorem trimList_back (p : Char → Bool) (chars : List Char) :
    (trimList p chars).reverse.dropWhile p = (trimList p chars).reverse := by
  simp [trimList, dropWhile_idempotent]

private theorem trimList_idempotent (p : Char → Bool) (chars : List Char) :
    trimList p (trimList p chars) = trimList p chars := by
  rw [trimList, trimList_front, trimList_back, List.reverse_reverse]

theorem trimOWS_idempotent (text : String) : trimOWS (trimOWS text) = trimOWS text := by
  have equal := congrArg String.ofList (trimList_idempotent (fun c => c == ' ' || c == '\t') text.toList)
  simpa [trimList, trimOWS] using equal

theorem trimOWS_front (text : String) :
    (trimOWS text).toList.dropWhile Spec.ows = (trimOWS text).toList := by
  unfold Spec.ows
  simpa only [trimList, trimOWS, String.toList_ofList] using
    trimList_front (fun c => c == ' ' || c == '\t') text.toList

theorem trimOWS_back (text : String) :
    (trimOWS text).toList.reverse.dropWhile Spec.ows = (trimOWS text).toList.reverse := by
  unfold Spec.ows
  simpa only [trimList, trimOWS, String.toList_ofList] using
    trimList_back (fun c => c == ' ' || c == '\t') text.toList

theorem trimOWS_source (text : String) :
    ∃ leading trailing : String,
      leading.toList.all (fun c => c == ' ' || c == '\t') = true ∧
      trailing.toList.all (fun c => c == ' ' || c == '\t') = true ∧
      text = leading ++ trimOWS text ++ trailing := by
  let p := fun c => c == ' ' || c == '\t'
  let leading := text.toList.takeWhile p
  let rest := text.toList.dropWhile p
  let trailing := (rest.reverse.takeWhile p).reverse
  refine ⟨String.ofList leading, String.ofList trailing, ?_, ?_, ?_⟩
  · simp [leading, p]
  · simp [trailing, p]
  · apply String.toList_inj.mp
    simp only [String.toList_append, String.toList_ofList, trimOWS]
    have back := congrArg List.reverse (List.takeWhile_append_dropWhile (p := p) (l := rest.reverse))
    have front := List.takeWhile_append_dropWhile (p := p) (l := text.toList)
    simp only [List.reverse_append, List.reverse_reverse] at back
    change text.toList = leading ++ trimList p text.toList ++ trailing
    calc
      text.toList = leading ++ rest := front.symm
      _ = _ := by
        simpa only [List.append_assoc, trimList, rest, trailing] using
          congrArg (fun chars => leading ++ chars) back.symm

structure HeaderBoundary (bytes : ByteArray) where
  endPos : Nat
  lower : 4 <= endPos
  upper : endPos <= bytes.size
  delimiter : bytes.extract (endPos - 4) endPos = "\r\n\r\n".toUTF8

theorem HeaderBoundary.source {bytes : ByteArray} (boundary : HeaderBoundary bytes) :
    bytes = bytes.extract 0 (boundary.endPos - 4) ++ "\r\n\r\n".toUTF8 ++
      bytes.extract boundary.endPos bytes.size := by
  calc
    bytes = bytes.extract 0 boundary.endPos ++ bytes.extract boundary.endPos bytes.size := by
      simp
    _ = _ := by
      rw [ByteArray.extract_eq_extract_append_extract (a := bytes) (i := 0)
        (k := boundary.endPos) (boundary.endPos - 4) (Nat.zero_le _) (Nat.sub_le _ _),
        boundary.delimiter]

def scanHeader (bytes : ByteArray) (i : Nat) : Except Response (Option (HeaderBoundary bytes)) := do
  if within : i < bytes.size then
    let b := bytes[i]!
    if b == 10 && (i == 0 || bytes[i - 1]! != 13) then
      throw (bad "Bare LF in headers")
    if b == 13 && i + 1 < bytes.size && bytes[i + 1]! != 10 then
      throw (bad "Bare CR in headers")
    if (b < 32 && b != 9 && b != 10 && b != 13) || b == 127 then
      throw (bad "Control character in headers")
    if found : b == 13 && i + 3 < bytes.size && bytes[i + 1]! == 10 &&
        bytes[i + 2]! == 13 && bytes[i + 3]! == 10 then
      have facts : bytes[i]! = 13 ∧ i + 3 < bytes.size ∧ bytes[i + 1]! = 10 ∧
          bytes[i + 2]! = 13 ∧ bytes[i + 3]! = 10 := by
        simpa only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, and_assoc] using found
      have upper : i + 4 <= bytes.size := by omega
      have delimiter : bytes.extract i (i + 4) = "\r\n\r\n".toUTF8 := by
        rw [ByteArray.extract_add_four upper]
        simp only [getElem!_pos bytes i (by omega),
          getElem!_pos bytes (i + 1) (by omega),
          getElem!_pos bytes (i + 2) (by omega),
          getElem!_pos bytes (i + 3) (by omega)] at facts
        simp only [facts.1, facts.2.2.1, facts.2.2.2.1, facts.2.2.2.2]
        rfl
      return some {
        endPos := i + 4
        lower := by omega
        upper
        delimiter := by simpa using delimiter }
    scanHeader bytes (i + 1)
  else return none
termination_by bytes.size - i

/-- Scan only the header block; a CR at the end of an incomplete buffer is allowed. -/
def headerEnd (bytes : ByteArray) : Except Response (Option (HeaderBoundary bytes)) :=
  scanHeader bytes 0

def contentLength (value : String) (limit : Nat) : Except Response Nat := do
  if value.isEmpty || !value.toList.all (fun c => '0' <= c && c <= '9') then
    throw (bad "Invalid Content-Length")
  let mut n := 0
  for c in value.toList do
    n := n * 10 + (c.toNat - '0'.toNat)
    if n > limit then throw tooLarge
  return n

private def addDigit (n : Nat) (c : Char) : Nat := n * 10 + (c.toNat - '0'.toNat)

private theorem decimalFold_ge (chars : List Char) (n : Nat) :
    n <= chars.foldl addDigit n := by
  induction chars generalizing n with
  | nil => simp
  | cons c chars ih =>
    simp only [List.foldl_cons]
    have grows : n <= addDigit n c := by unfold addDigit; omega
    exact Nat.le_trans grows (ih (addDigit n c))

private theorem decimalLoop_eq (chars : List Char) (n limit : Nat) (within : n <= limit) :
    forIn chars n (fun c n =>
      if addDigit n c > limit then (Except.error tooLarge : Except Response (ForInStep Nat))
      else .ok (.yield (addDigit n c))) =
    if chars.foldl addDigit n > limit then .error tooLarge else .ok (chars.foldl addDigit n) := by
  induction chars generalizing n with
  | nil => simp [Nat.not_lt.mpr within, Pure.pure, Except.pure]
  | cons c chars ih =>
    simp only [List.forIn_cons, List.foldl_cons]
    split
    next large =>
      have later := decimalFold_ge chars (addDigit n c)
      have exceeds : chars.foldl addDigit (addDigit n c) > limit := by omega
      simp [exceeds, Bind.bind, Except.bind]
    next small =>
      simpa [Bind.bind, Except.bind] using ih (addDigit n c) (by omega)

private theorem throw_eq {α : Type} (error : Response) :
    (throw error : Except Response α) = .error error := rfl

/-- Syntax is checked before the numeric budget, including when a prefix exceeds it. -/
theorem contentLength_eq (value : String) (limit : Nat) :
    contentLength value limit =
      if !Spec.digits value then .error (bad "Invalid Content-Length")
      else if Spec.decimal value > limit then .error tooLarge
      else .ok (Spec.decimal value) := by
  unfold contentLength
  have guard : (value.isEmpty || !value.toList.all (fun c => '0' <= c && c <= '9')) =
      !Spec.digits value := by simp [Spec.digits, Bool.not_and]
  simp only [guard, throw_eq]
  split
  · rfl
  · simp only [bind_pure]
    have loop := decimalLoop_eq value.toList 0 limit (Nat.zero_le _)
    have valueEq : value.toList.foldl addDigit 0 = Spec.decimal value := by
      unfold Spec.decimal addDigit
      congr 1
      funext n c
      simp [Nat.mul_comm]
    rw [valueEq] at loop
    apply Eq.trans ?_ loop
    congr 1

theorem contentLength_ok_iff (value : String) (limit length : Nat) :
    contentLength value limit = .ok length ↔
      Spec.digits value = true ∧ Spec.decimal value = length ∧ length <= limit := by
  rw [contentLength_eq]
  by_cases digits : Spec.digits value = true
  · by_cases fits : Spec.decimal value <= limit
    · simp [digits, Nat.not_lt.mpr fits]
      omega
    · simp [digits, Nat.lt_of_not_ge fits]
      omega
  · simp [digits]

/-- Decoding succeeds exactly when the string encodes the supplied bytes. -/
theorem fromUTF8_eq_some (bytes : ByteArray) (text : String) :
    String.fromUTF8? bytes = some text ↔ text.toUTF8 = bytes := by
  unfold String.fromUTF8?
  split
  next valid =>
    constructor
    · intro result
      cases Option.some.inj result
      rfl
    · intro source
      congr 1
      apply String.toByteArray_inj.mp
      exact source.symm
  next invalid =>
    constructor
    · intro result
      cases result
    · intro source
      exact False.elim (invalid (source ▸ text.isValidUTF8))

def splitChar (separator : Char) (text : String) : List String :=
  (text.split separator).toList.map String.Slice.copy

theorem splitChar_ne_nil (separator : Char) (text : String) :
    splitChar separator text ≠ [] := by
  unfold splitChar
  rw [String.toList_split_char]
  intro empty
  exact List.splitOn_ne_nil separator text.toList (List.map_eq_nil_iff.mp empty)

theorem splitChar_rejoin (separator : Char) (text : String) :
    String.intercalate (String.singleton separator) (splitChar separator text) = text := by
  apply String.toList_inj.mp
  simp only [splitChar, String.toList_split_char, String.toList_intercalate,
    String.toList_singleton, List.map_map, Function.comp_def, String.toList_ofList]
  simp [List.intercalate_splitOn]

theorem splitChar_intercalate (separator : Char) (parts : List String)
    (nonempty : parts ≠ []) (absent : ∀ part ∈ parts, separator ∉ part.toList) :
    splitChar separator (String.intercalate (String.singleton separator) parts) = parts := by
  simpa only [splitChar, nonempty, ↓reduceIte] using
    String.toList_split_intercalate absent

end LeanHttp.Wire.Internal
