import LeanHttp.Wire.Basic

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

private def lineStep (c : Char) : List (List Char) → List (List Char)
  | [] => [[c]]
  | first :: rest =>
    if c = '\r' then
      match first with
      | '\n' :: tail => [] :: tail :: rest
      | _ => (c :: first) :: rest
    else (c :: first) :: rest

private theorem lineStep_ne_nil (c : Char) (lines : List (List Char)) :
    lineStep c lines ≠ [] := by
  cases lines with
  | nil => simp [lineStep]
  | cons first rest =>
    simp only [lineStep]
    split
    · split <;> simp
    · simp

private theorem folded_ne_nil (chars : List Char) : chars.foldr lineStep [[]] ≠ [] := by
  cases chars with
  | nil => simp
  | cons c cs => exact lineStep_ne_nil _ _

private theorem lineStep_source (c : Char) (lines : List (List Char)) (nonempty : lines ≠ []) :
    List.intercalate ['\r', '\n'] (lineStep c lines) =
      c :: List.intercalate ['\r', '\n'] lines := by
  cases lines with
  | nil => contradiction
  | cons first rest =>
    simp only [lineStep]
    split
    · rename_i cr
      split
      · subst cr
        simp [List.intercalate_cons_cons]
      · cases rest <;> simp_all [List.intercalate_cons_cons]
    · cases rest <;> simp [List.intercalate_cons_cons]

private theorem folded_source (chars : List Char) :
    List.intercalate ['\r', '\n'] (chars.foldr lineStep [[]]) = chars := by
  induction chars with
  | nil => simp
  | cons c cs ih =>
    rw [List.foldr_cons, lineStep_source _ _ (folded_ne_nil _), ih]

private theorem folded_prepend (chars first : List Char) (rest : List (List Char))
    (clean : '\r' ∉ chars) :
    chars.foldr lineStep (first :: rest) = (chars ++ first) :: rest := by
  induction chars with
  | nil => rfl
  | cons c cs ih =>
    have head : c ≠ '\r' := by intro eq; apply clean; simp [eq]
    have tail : '\r' ∉ cs := by intro mem; apply clean; simp [mem]
    simp [List.foldr_cons, ih tail, lineStep, head]

private theorem folded_intercalate (lines : List (List Char))
    (nonempty : lines ≠ []) (clean : ∀ line ∈ lines, '\r' ∉ line) :
    (List.intercalate ['\r', '\n'] lines).foldr lineStep [[]] = lines := by
  induction lines with
  | nil => contradiction
  | cons first rest ih =>
    have firstClean : '\r' ∉ first := clean _ (by simp)
    cases rest with
    | nil => simpa using folded_prepend first [] [] firstClean
    | cons next rest =>
      have restClean : ∀ line ∈ next :: rest, '\r' ∉ line := by
        intro line mem
        exact clean line (by simp [mem])
      rw [List.intercalate_cons_cons, List.foldr_append, ih (by simp) restClean]
      rw [List.foldr_append]
      change first.foldr lineStep ([] :: next :: rest) = first :: next :: rest
      rw [folded_prepend _ _ _ firstClean]
      simp only [List.append_nil]

def splitLines (text : String) : List String :=
  (text.toList.foldr lineStep [[]]).map String.ofList

theorem splitLines_ne_nil (text : String) : splitLines text ≠ [] := by
  unfold splitLines
  intro nil
  exact folded_ne_nil _ (List.map_eq_nil_iff.mp nil)

theorem splitLines_source (text : String) :
    String.intercalate "\r\n" (splitLines text) = text := by
  apply String.toList_inj.mp
  simp only [splitLines, String.toList_intercalate, List.map_map, String.toList_ofList,
    Function.comp_def]
  simpa using folded_source text.toList

theorem splitLines_intercalate (lines : List String) (nonempty : lines ≠ [])
    (clean : ∀ line ∈ lines, '\r' ∉ line.toList) :
    splitLines (String.intercalate "\r\n" lines) = lines := by
  unfold splitLines
  rw [String.toList_intercalate]
  rw [show "\r\n".toList = ['\r', '\n'] from by decide]
  have source := folded_intercalate (lines.map String.toList)
    (by simpa using nonempty) (by simpa using clean)
  rw [source]
  simp

end LeanHttp.Wire.Internal
