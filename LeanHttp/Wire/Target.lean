import LeanHttp.Wire.Field
import LeanHttp.Wire.Request

set_option autoImplicit false

namespace LeanHttp.Wire.Internal

private theorem splitOn_clean (separator : Char) (chars : List Char) :
    ∀ part ∈ chars.splitOn separator, separator ∉ part := by
  induction chars with
  | nil => simp
  | cons c cs ih =>
    rw [List.splitOn_cons_eq_if_modifyHead]
    split
    · simp only [List.mem_cons, List.not_mem_nil, forall_eq_or_imp]
      exact ⟨not_false, ih⟩
    · rename_i different
      obtain ⟨first, rest, source⟩ := List.exists_cons_of_ne_nil (List.splitOn_ne_nil separator cs)
      rw [source] at ih ⊢
      simp only [List.modifyHead_cons, List.mem_cons, forall_eq_or_imp] at ih ⊢
      refine ⟨?_, ih.2⟩
      intro mem
      rcases mem with eq | mem
      · exact different (by simpa only [beq_iff_eq] using eq.symm)
      · exact ih.1 mem

theorem splitChar_singleton (separator : Char) (text : String)
    (clean : separator ∉ text.toList) : splitChar separator text = [text] := by
  unfold splitChar
  rw [String.toList_split_char, List.splitOn_eq_singleton clean]
  simp

theorem splitChar_clean (separator : Char) (text part : String)
    (member : part ∈ splitChar separator text) : separator ∉ part.toList := by
  simp only [splitChar, String.toList_split_char, List.mem_map] at member
  obtain ⟨chars, member, rfl⟩ := member
  simpa only [String.toList_ofList] using splitOn_clean separator text.toList chars member

theorem parseStartLine_target (line : String) (result : StartLine)
    (parsed : parseStartLine line = .ok result) :
    (!(result.target.startsWith "/" || (result.target == "*" && result.method == .options)) ||
      result.target.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#')) = false := by
  unfold parseStartLine at parsed
  split at parsed
  next method target version source =>
    simp only [Bind.bind, Except.bind, Pure.pure, Except.pure] at parsed
    split at parsed
    next invalid => cases parsed
    next valid =>
      split at parsed
      next invalid => split at parsed <;> cases parsed
      next versionValid =>
        split at parsed
        next method parsedMethod =>
          split at parsed
          next invalid => cases parsed
          next targetValid =>
            cases Except.ok.inj parsed
            exact Bool.eq_false_iff.mpr targetValid
        next unsupported => cases parsed
  next malformed => cases parsed

theorem target_source (text path : String) (parts : List String) (method : Method)
    (split : splitChar '?' text = path :: parts)
    (checked : (!(text.startsWith "/" || (text == "*" && method == .options)) ||
      text.toList.any (fun c => c.toNat <= 32 || c.toNat >= 127 || c == '#')) = false) :
    ∃ target : Spec.Target, target.valid method = true ∧ target.text = text ∧
      (match target with
        | .origin p q => (p, q.getD "")
        | .asterisk => ("*", "")) = (path, String.intercalate "?" parts) := by
  rw [targetChars_error, startsWith_slash] at checked
  have facts : ((text.toList.head? == some '/') = true ∨
      text = "*" ∧ (method == .options) = true) ∧ text.toList.all Spec.targetChar = true := by
    simpa only [Bool.or_eq_false_iff, Bool.not_eq_false', Bool.or_eq_true,
      Bool.and_eq_true, beq_iff_eq] using checked
  have rejoined := splitChar_rejoin '?' text
  rw [split] at rejoined
  have clean := splitChar_clean '?' text path (by rw [split]; simp)
  rcases facts.1 with origin | ⟨asterisk, options⟩
  · cases parts with
    | nil =>
      have source : path = text := by simpa using rejoined
      refine ⟨.origin path none, ?_, source, rfl⟩
      have head : (path.toList.head? == some '/') = true := source ▸ origin
      have chars : path.toList.all Spec.targetChar = true := source ▸ facts.2
      simp only [Spec.Target.valid, head, List.contains_eq_mem, clean, chars, Option.getD_none]
      decide
    | cons first rest =>
      have source : path ++ "?" ++ String.intercalate "?" (first :: rest) = text := by
        simpa [String.intercalate_cons_cons, String.append_assoc] using rejoined
      have chars := facts.2
      rw [← source] at chars
      simp only [String.toList_append, List.all_append, Bool.and_eq_true] at chars
      have starts : (path.toList.head? == some '/') = true := by
        rw [← source, String.toList_append, String.toList_append] at origin
        cases h : path.toList with
        | nil => simp [h] at origin
        | cons c cs => simpa [h] using origin
      refine ⟨.origin path (some (String.intercalate "?" (first :: rest))), ?_, source, rfl⟩
      simp only [Spec.Target.valid, starts, List.contains_eq_mem, Option.getD_some,
        clean, chars.1.1, chars.2]
      rfl
  · subst asterisk
    have singleton : splitChar '?' "*" = ["*"] := splitChar_singleton _ _ (by decide)
    rw [singleton] at split
    cases split
    exact ⟨.asterisk, options, rfl, rfl⟩

theorem target_split_complete (target : Spec.Target) (method : Method)
    (valid : target.valid method = true) :
    ∃ path parts, splitChar '?' target.text = path :: parts ∧
      (match target with
        | .origin p q => (p, q.getD "")
        | .asterisk => ("*", "")) = (path, String.intercalate "?" parts) := by
  cases target with
  | asterisk => exact ⟨"*", [], splitChar_singleton _ _ (by decide), rfl⟩
  | origin path query =>
    have facts := valid
    simp only [Spec.Target.valid, Bool.and_eq_true] at facts
    have clean : '?' ∉ path.toList := by simpa using facts.1.1.2
    cases query with
    | none =>
      refine ⟨path, [], ?_, rfl⟩
      exact splitChar_singleton _ _ clean
    | some query =>
      refine ⟨path, splitChar '?' query, ?_, ?_⟩
      · exact splitChar_first '?' path query clean
      · exact congrArg (Prod.mk path) (splitChar_rejoin '?' query).symm

end LeanHttp.Wire.Internal
