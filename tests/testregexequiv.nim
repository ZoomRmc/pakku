## Equivalence tests for the std/re -> hand-rolled migration.
## The oracle is the original PCRE pattern, kept alive here on purpose:
## each check proves a new routine agrees with the regex it replaced.

import ../src/utils
import std/[re, unittest, strutils, options, tables, os]
import ../src/config

suite "stripHtmlTags vs <.*?>":
  proc oracle(s: string): string = s.replace(re"<.*?>", "")

  test "simple tag pairs":
    for s in ["<b>bold</b>", "<i>a</i>b<p>c", "plain text",
              "<b>hi</b> x <a href=\"l>weird\">y"]:
      check stripHtmlTags(s) == oracle(s)

  test "empty region between brackets still removed":
    check stripHtmlTags("<>") == ""
    check stripHtmlTags("<>>x") == ">x"

  test "newline blocks the match (default PCRE dot semantics)":
    for s in ["<a\nb>x", "a\n<a\nb>c<d>e", "<br\n/>x"]:
      check stripHtmlTags(s) == oracle(s)

  test "unterminated regions survive verbatim":
    for s in ["<abc", "<abc ", "a<", "text < tail"]:
      check stripHtmlTags(s) == oracle(s)

  test "rescanning continues after a non-match '<'":
    check stripHtmlTags("a<b\nc>x<y>d") == oracle("a<b\nc>x<y>d")

suite "replaceRuns spaces vs \\ {2,}":
  proc oracle(s: string): string = s.replace(re"\ {2,}", " ")

  test "runs of two or more collapse to one space":
    for s in ["a  b", "a     b", "a b c", " trailing  spaces   ",
              "", "   ", " ", "no-space"]:
      check replaceRuns(s, {' '}, 2, " ") == oracle(s)

  test "tabs and mixed whitespace are untouched by this pattern":
    for s in ["a\t\tb", " \t ", "a \tb", "\t\tx y"]:
      check replaceRuns(s, {' '}, 2, " ") == oracle(s)

suite "replaceRuns newlines vs \\n{2,}":
  proc oracle(s: string): string = s.replace(re"\n{2,}", "\n\n")

  test "any run of 2+ collapses to exactly two newlines":
    for s in ["a\n\n\n\n\n\nb", "a\nb", "\n", "\n\n", "\n\n\n", "",
              "x\ny\nz\n\nw"]:
      check replaceRuns(s, {'\n'}, 2, "\n\n") == oracle(s)

suite "replaceRuns whitespace vs \\s{2,} (single-line subset: space+tab)":
  # the original call site received single-line strings only, so the
  # newline branch of `\s` is unreachable there; space/tab coverage below
  # matches the byte semantics that mattered
  proc oracle(s: string): string = s.replace(re"[ \t]{2,}", " ")

  test "2+ blanks become one space; lone blanks keep their own shape":
    for s in ["k  = v", "date with  double", "tab\ttab\t", "a \t b",
              "\t\tx", "x ", "ok word"]:
      check replaceRuns(s, {' ', '\t'}, 2, " ") == oracle(s)

suite "replaceWord vs \\bpacman\\b":
  proc oracle(s: string): string = s.replace(re"\bpacman\b", "pakku")

  test "whole-word replacement boundaries":
    for s in ["pacman and pacman.conf", "_pacman stays", "pacman2 stays",
              "xpacman stays", "run pacman git pacman", "pacman.",
              "pacman", "-pacman-", "pacman pacman",
              "nothing here", ""]:
      check replaceWord(s, "pacman", "pakku") == oracle(s)

import ../src/package

suite "splitVersionConstraint mirrors alpm_dep_from_string":
  # oracle: libalpm `alpm_dep_from_string` (deps.c:458) — first '<' wins
  # over '>', '>' over '=', two-char forms when '=' directly follows;
  # name may contain spaces and stays untrimmed; version is the remainder.
  test "simple forms":
    check "name>=1.2".splitVersionConstraint ==
      ("name", some(ConstraintOperation.ge), "1.2")

  test "canonical keeps spaces inside the version":
    check "name >= 1.2-3".splitVersionConstraint ==
      ("name ", some(ConstraintOperation.ge), " 1.2-3")

  test "one-char operators":
    check "name > 3".splitVersionConstraint ==
      ("name ", some(ConstraintOperation.gt), " 3")
    check "foo = bar baz".splitVersionConstraint ==
      ("foo ", some(ConstraintOperation.eq), " bar baz")

  test "lt outranks an earlier eq (alpm checks lt first)":
    check "a=b<c".splitVersionConstraint ==
      ("a=b", some(ConstraintOperation.lt), "c")

  test "empty name or empty version allowed":
    check ">=1.2".splitVersionConstraint ==
      ("", some(ConstraintOperation.ge), "1.2")
    check "=".splitVersionConstraint == ("", some(ConstraintOperation.eq), "")

  test "no operator keeps the whole string as name, no operation":
    for s in ["plainname", "--flag", "", "."]:
      let (n, op, v) = s.splitVersionConstraint()
      check op.isNone
      check n == s
      check v == ""

suite "parseSrcInfoLine vs srcinfo pattern":
  proc oracle(s: string): Option[tuple[k, v: string]] =
    var m: array[2, string]
    if s.match(re"[\t\ ]*(\w+)\ =\ (.*)", m):
      some((m[0], m[1]))
    else:
      none(tuple[k: string, v: string])

  template expectSame(s: string) =
    block:
      let o = oracle(s)
      let n = parseSrcInfoLine(s)
      check n.isSome == o.isSome
      if o.isSome:
        check n.unsafeGet.key == o.unsafeGet[0]
        check strip(n.unsafeGet.value) == strip(o.unsafeGet[1])

  test "accepted and rejected line shapes":
    for s in ["\tx_1 = V W", "pkgbase = core", "key = ", "no-sep",
              "k= v", "k  = v", "= novalue", "bad key = x",
              "9digit-key = ok", "\t\t\tindented = yes", "trailing = "]:
      expectSame(s)

suite "parseConfigKeyval mirrors pacman parse_ini":
  # canonical spec: src/pacman/ini.c splits at the FIRST '=', then strtrim()
  # (isspace set) both halves. Keys are otherwise unrestricted; empty keys or
  # lines without '=' never match.
  proc iniSplit(s: string): Option[tuple[k, v: string]] =
    let eq = s.find('=')
    if eq < 0:
      return none(tuple[k: string, v: string])
    let key = strip(s[0 ..< eq])
    if key.len == 0:
      return none(tuple[k: string, v: string])
    some((key, strip(s[(eq + 1)..^1])))

  template expectSame(s: string) =
    block:
      let o = iniSplit(s)
      let n = parseConfigKeyval(s)
      check n.isSome == o.isSome
      if o.isSome:
        check n.unsafeGet.key == o.unsafeGet[0]
        check n.unsafeGet.value == o.unsafeGet[1]

  test "whitespace of every kind around '=' is trimmed":
    for s in ["k = v ", "IgnorePkg = foo bar", "a=b", "k\t= v",
              "key =", "a == b", "9k = v"]:
      expectSame(s)

  test "lines without a usable key/value pair stay unmatched":
    for s in [" = nokey", "= k", "onlytext", "Quiet", ""]:
      expectSame(s)

  test "internal spaces in the key survive (unknown directives land in the table)":
    expectSame("foo bar = x")

suite "matchConfigSection mirrors parse_ini section rule":
  # canonical spec: src/pacman/ini.c -- first char '[', last char ']', name
  # is the verbatim interior. Junk after ']' is NOT part of a header; such
  # lines are directive material upstream.
  template expectSection(s: string, name: string) =
    block:
      let got = matchConfigSection(s)
      check got.isSome
      check got.unsafeGet == name

  test "plain and empty sections":
    expectSection("[options]", "options")
    expectSection("[]", "")

  test "brackets inside the name stay verbatim":
    expectSection("[a][b]", "a][b")

  test "trailing junk before non-bracket end falls to directives":
    for s in ["[core] junk", "[options] # note"]:
      check matchConfigSection(s).isNone

suite "readConfigFile end-to-end on fixture":
  let confPath = getTempDir() / "pakku-test-pacman.conf"
  # writeLines emits real control characters: the fixture line ends with a
  # true TAB, which upstream `readLine().strip()` removes before parsing —
  # so the value arrives as "linux", matching production behavior of the
  # old PCRE pipeline identically.
  var f = open(confPath, fmWrite)
  f.write("[options]\n",
    "HoldPkg = gcc glibc\n",
    "IgnorePkg = linux\t\n",
    "X = y\n",
    "[weird]\n",
    "bad line here\n",
    "[kernel]\n")
  f.close()

  test "sections, accumulations and fallback lines parse identically":
    let (table, wasError) = readConfigFile(confPath)
    let sectionCount = table.len
    let options = table["options"][]
    let kernelEntries = table["kernel"][].len
    check not wasError
    check sectionCount == 3  # options, weird, kernel
    check options["HoldPkg"] == "gcc glibc"
    check options["IgnorePkg"] == "linux"
    check options["X"] == "y"
    # non-keyval line inside a section falls into `category[line] = ""`
    check table["weird"]["bad line here"] == ""
    check kernelEntries == 0
