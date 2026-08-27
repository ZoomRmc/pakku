import std/[options, sequtils, tables, unittest]
import ../src/package

suite "splitVersionConstraint":
  # contract mirrors libalpm's `alpm_dep_from_string` (deps.c): operator is
  # selected from the whole string with `<` preferred over `>` over `=`; the
  # two-char form wins when `=` directly follows; name and version are
  # captured verbatim (spaces included) and may be empty.

  test "simple operators":
    check "name>=1.2".splitVersionConstraint ==
      ("name", some(ConstraintOperation.ge), "1.2")
    check "name<2.0".splitVersionConstraint ==
      ("name", some(ConstraintOperation.lt), "2.0")
    check "foo = bar baz".splitVersionConstraint ==
      ("foo ", some(ConstraintOperation.eq), " bar baz")

  test "'<' outranks '>' and '=' wherever it occurs":
    check "a=b<c".splitVersionConstraint ==
      ("a=b", some(ConstraintOperation.lt), "c")

  test "two-char forms only when '=' directly follows":
    check "name >= 1.2-3".splitVersionConstraint ==
      ("name ", some(ConstraintOperation.ge), " 1.2-3")
    check "n<=0.1".splitVersionConstraint ==
      ("n", some(ConstraintOperation.le), "0.1")

  test "empty name and empty version are legal":
    check ">=1.2".splitVersionConstraint ==
      ("", some(ConstraintOperation.ge), "1.2")
    check "=".splitVersionConstraint == ("", some(ConstraintOperation.eq), "")
    check "name >=".splitVersionConstraint.operation.get ==
      ConstraintOperation.ge

  test "no constraint keeps the input as the name":
    for s in ["plainname", "--flag", "", ".", "junk:name"]:
      let (n, op, v) = s.splitVersionConstraint()
      check op.isNone
      check n == s
      check v == ""

suite "parseSrcInfoLine":
  # accepts makepkg's emitted shape: optional leading spaces/tabs, an
  # identifier key, then exactly `" = "` and a verbatim remainder.
  test "accepted shapes":
    let kv = parseSrcInfoLine("\tx_1 = V W").unsafeGet
    check kv.key == "x_1"
    check kv.value == "V W"
    check parseSrcInfoLine("pkgbase = core").unsafeGet.value == "core"
    check parseSrcInfoLine("_custom_flag = yes").unsafeGet.key == "_custom_flag"

  test "lenient like every .SRCINFO reader: spacing around '=' is trimmed":
    for s in ["k= v", "k  = v"]:
      let kv = parseSrcInfoLine(s).unsafeGet
      check kv.key == "k"
      check kv.value == "v"

  test "leading separators and missing pieces":
    check parseSrcInfoLine("= novalue").isNone
    check parseSrcInfoLine("bad-key= x").isNone

suite "parseSrcInfoKeys":
  const srcInfo = """
pkgbase = pakku
pkgname = pakku
depends = glibc
makedepends = nim
pkgname = libpakku
depends = musl
"""
  test "splits sections per pkgname":
    let parsed = srcInfo.parseSrcInfoKeys()
    check toSeq(keys(parsed.table)) == @["pakku", "libpakku"]
    check parsed.baseSeq[].filterIt(it.key == "pkgbase")[0].value == "pakku"
